# #34 steps 6, 7 — ADR-0010, ADR-0019, ADR-0011, ADR-0012, ADR-0002: object-store port,
# PutOutcome/ObjectMeta, record cache; step 7 adds galloping and the commit retry loop.
#
# `ChainTables.open` is defined in localcopy.jl, so every file below is opened with
# `Base.open`.

# ---------------------------------------------------------------------------
# The port (ADR-0010; public per ADR-0019). Four verbs, one request each, no delete.
# `AbstractObjectStore` itself is declared in errors.jl so every lane can dispatch on it.
# There is deliberately no fallback method: a store that leaves a verb unimplemented
# fails with a `MethodError` at the first call, not with a wrong answer.
# ---------------------------------------------------------------------------

"""
    PutOutcome(created, status)

What a conditional put reported (ADR-0010). `created` is `true` when the key did not
exist and now holds the bytes, and `false` only for a genuine `412 Precondition Failed`
(ADR-0019): a `409` is retried inside the commit layer and never surfaces here, and
every other failure raises. `status` is the HTTP status the transport saw, carried for
messages; nothing in the protocol depends on it — the read-back of the slot decides a
commit's outcome (ADR-0002).
"""
struct PutOutcome
    created::Bool
    status::Int
end

"""
    ObjectMeta(key, size, modified)

What `stat_object` and `list_objects` report about one object: its `key`, its `size`
in bytes, and `modified` as whole seconds since the Unix epoch. Whole seconds because
that is all S3 promises, so two objects written in one second tie; nothing in the
protocol orders by it (ADR-0002, ADR-0010).
"""
struct ObjectMeta
    key::String
    size::Int64
    modified::Int64
end

"""
    fetch_object(store, key) -> Vector{UInt8} | nothing

The whole object at `key`, or `nothing` when no such key exists. **Absent is `nothing`,
failure raises**: a transport or authorisation failure is an exception, never `nothing`
(ADR-0010, ADR-0019). One request; no retry inside.
"""
function fetch_object end

"""
    put_object_if_absent(store, key, bytes) -> PutOutcome

Create `key` holding `bytes` if and only if no such key exists, the bare
`If-None-Match: *` conditional put of ADR-0002. Returns a [`PutOutcome`](@ref) whose
`created` is `false` only for a genuine `412`; a `409` and every transport failure raise,
and the commit layer owns the retry loop and the read-back that decides the outcome
(ADR-0010). The store must never overwrite an existing key under any condition
(ADR-0016 rule 1). This is the port's only write verb: there is no delete (ADR-0012).
"""
function put_object_if_absent end

"""
    stat_object(store, key) -> ObjectMeta | nothing

The [`ObjectMeta`](@ref) of `key`, or `nothing` when no such key exists; failure raises
(ADR-0010). One request — a `HEAD` — which is what head discovery gallops with (ADR-0012).
"""
function stat_object end

"""
    startswith_bytes(key, prefix) -> Bool

Whether `key` starts with `prefix` compared byte for byte, the comparison `list_objects`
promises (ADR-0010): half of a multi-byte code point is a legal prefix.
"""
function startswith_bytes(key::AbstractString, prefix::AbstractString)
    k, p = codeunits(key), codeunits(prefix)
    length(p) <= length(k) || return false
    for i in eachindex(p)
        p[i] == k[i] || return false
    end
    return true
end

"""
    list_objects(store, prefix; start_after = nothing) -> Vector{ObjectMeta}

Every object whose key starts with `prefix`, compared **by bytes**, and, when
`start_after` is given, whose key sorts strictly after it in byte order. **Order is not
promised** (ADR-0010, ADR-0012): nothing in the protocol reads a listing's order, and
the double shuffles to keep it that way. Failure raises; an empty listing is an empty
vector, not `nothing`.
"""
function list_objects end

# ---------------------------------------------------------------------------
# The record cache (ADR-0010, ADR-0012, ADR-0013, ADR-0019). Keyed by bucket and key
# under one directory; a hit is served from disk and never re-validated against the
# store, which is correct because every key ChainTables writes is written once
# (ADR-0002, ADR-0012). A miss is never memoized.
# ---------------------------------------------------------------------------

"""
    default_cache_dir() -> String

Where the record cache lives unless a chain says otherwise: `CHAINTABLES_CACHE_DIR`
when set, else `first(DEPOT_PATH)/chaintables/records` (ADR-0019, ADR-0010). Resolved
at each call, so a test can point it at a `mktempdir()` through the environment.
"""
default_cache_dir() = get(ENV, "CHAINTABLES_CACHE_DIR") do
    joinpath(first(DEPOT_PATH), "chaintables", "records")
end

"""
    RecordCache(; dir = default_cache_dir())

The record cache: the machine-wide directory of objects a client has fetched, keyed by
bucket and key (ADR-0010). Disposable — delete the directory and every record is fetched
again — and never re-validated against the store, because a key's bytes are immutable
by protocol (ADR-0002, ADR-0012). Distinct from the local copy, which is derived from
the records rather than a copy of them (ADR-0023).
"""
struct RecordCache
    dir::String
end
RecordCache(; dir = default_cache_dir()) = RecordCache(String(dir))

"""
    record_path(cache, bucket, key) -> String

The file a record is cached at: `cache.dir/bucket/key`, with each `/`-separated segment
of `key` a directory (ADR-0011: the mapping from keys to paths is local and ours). A
bucket or a segment that is empty, `.` or `..` is refused, since it would name a path
outside the cache.
"""
function record_path(cache::RecordCache, bucket::AbstractString, key::AbstractString)
    segments = split(key, '/')
    for s in (bucket, segments...)
        isempty(s) && throw(ArgumentError("record_path: empty segment in bucket $(repr(bucket)), key $(repr(key))"))
        s in (".", "..") && throw(ArgumentError("record_path: segment $(repr(s)) in bucket $(repr(bucket)), key $(repr(key)) would leave the cache"))
    end
    return joinpath(cache.dir, bucket, segments...)
end

"""
    fetch_record(cache, store, bucket, key) -> Vector{UInt8} | nothing

`fetch_object` through the record cache. A cached record is served from disk without
consulting the store; a miss fetches from `store` and, when the object exists, writes it
to a temporary file in the destination directory and renames it into place, so an
interrupted fetch never caches a truncated record (ADR-0010, ADR-0013). An absent object
returns `nothing` and caches nothing: a client polling a slot that is still empty must
see the record the moment it lands (ADR-0012). Failure raises.

The cache does not hash what it serves. Every read returns the file's bytes fresh, and
the caller rehashes them against the hash it holds — a child's `prev_hash`, or the head
file's `transaction_hash` (ADR-0006, ADR-0013) — because only the chain knows the
expected value.
"""
function fetch_record(cache::RecordCache, store::AbstractObjectStore, bucket::AbstractString, key::AbstractString)
    path = record_path(cache, bucket, key)
    isfile(path) && return read(path)
    bytes = fetch_object(store, key)
    bytes === nothing && return nothing
    dir = dirname(path)
    mkpath(dir)
    tmp = tempname(dir; cleanup = false)
    try
        Base.open(tmp, "w") do io
            write(io, bytes)
        end
        Base.Filesystem.rename(tmp, path)
    catch
        rm(tmp; force = true)
        rethrow()
    end
    return bytes
end
