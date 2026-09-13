# #34 steps 6, 7 — ADR-0010, ADR-0019, ADR-0011, ADR-0012, ADR-0002: object-store port,
# PutOutcome/ObjectMeta, record cache, the commit retry loop with its read-back, galloping.
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
    cache_record!(cache, bucket, key, bytes)
    return bytes
end

"""
    cache_record!(cache, bucket, key, bytes) -> nothing

Put `bytes` in the cache as the record at `key`: written to a temporary file in the
destination directory and renamed into place. What [`fetch_record`](@ref) does with a
fetched object, and what the commit layer does with a record it has just put — a record
of our own is as immutable as a fetched one, and `repair!` and `verify` replay from the
cache (ADR-0014), so our own commits belong there too.
"""
function cache_record!(cache::RecordCache, bucket::AbstractString, key::AbstractString, bytes)
    path = record_path(cache, bucket, key)
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
    return nothing
end

# ---------------------------------------------------------------------------
# Transport failures and the retry rule (ADR-0010, ADR-0002). One request per port
# call; the commit layer owns the loop, because the read-back that decides a
# commit's outcome has to happen between attempts.
# ---------------------------------------------------------------------------

"""
    TransportError(msg; status = nothing) <: Exception

What a port verb raises when a request failed: `status` is the HTTP status when there
was a response, `nothing` for a connect failure or a timeout. Deliberately outside
ADR-0020's taxonomy: it is the transport's word, and the commit layer decides what it
means — [`retryable`](@ref) says whether the request is re-issued. A test's
`InMemoryObjectStore` `fault` throws one to simulate a failed request.
"""
struct TransportError <: Exception
    msg::String
    status::Union{Nothing,Int}
end
TransportError(msg; status = nothing) = TransportError(msg, status)
Base.showerror(io::IO, e::TransportError) =
    print(io, "TransportError: ", e.msg, e.status === nothing ? "" : " (HTTP $(e.status))")

"""
    retryable(e) -> Bool

ADR-0010's rule: a connect failure or timeout (`status === nothing`), a `5xx`, and a
`409` are retried; every other status — an auth `4xx` above all — is not, and neither is
any exception that is not a [`TransportError`](@ref). A `412` never reaches here: the
port returns it as a `PutOutcome`.
"""
retryable(e::TransportError) = e.status === nothing || 500 <= e.status < 600 || e.status == 409
retryable(e) = false

"""
    PUT_ATTEMPTS, PUT_BACKOFF_S

How many times [`put_record!`](@ref) issues its conditional put before giving up, and
the pause before each re-issue. Bounded and short: a commit that cannot land in four
attempts is a transport the user should hear about, not one to wait on.
"""
const PUT_ATTEMPTS = 4
const PUT_BACKOFF_S = (0.05, 0.1, 0.2)

"""
    put_record!(store, cache, bucket, key, bytes) -> nothing | Vector{UInt8}

The conditional put of a record with ADR-0010's retry loop and ADR-0002's read-back.
Returns `nothing` when `bytes` are at `key` — created by this call, or found there by
the read-back after a lost acknowledgement — and the **other** record's bytes when a
different object holds the slot, which is a lost race for the caller to raise. The
outcome is decided by the read-back, never by the status:

| the slot then holds | the outcome |
|---|---|
| our bytes | success — only the acknowledgement was lost |
| other bytes | the race is lost; never retried |
| nothing | the request never landed; retry, bounded |

A retryable failure ([`retryable`](@ref)) is re-issued after the read-back, up to
[`PUT_ATTEMPTS`](@ref); any other exception propagates at once. The read-back goes
through the record cache, so what is found is cached as the slot's record; so is a record
this call created.
"""
function put_record!(store::AbstractObjectStore, cache::RecordCache, bucket::AbstractString, key::AbstractString, bytes)
    ours = Ops.transaction_hash(bytes)
    failure = nothing
    for attempt in 1:PUT_ATTEMPTS
        attempt == 1 || sleep(PUT_BACKOFF_S[attempt-1])
        outcome = try
            put_object_if_absent(store, key, bytes)
        catch e
            retryable(e) || rethrow()
            failure = e
            nothing
        end
        if outcome !== nothing
            outcome.created && (cache_record!(cache, bucket, key, bytes); return nothing)
            outcome.status == 412 || error("put_object_if_absent($(typeof(store))) returned created = false with status " *
                "$(outcome.status); the port promises false only for a 412 (ADR-0019)")
        end
        found = fetch_record(cache, store, bucket, key)
        found === nothing || return Ops.transaction_hash(found) == ours ? nothing : found
    end
    failure === nothing || throw(failure)
    throw(RewrittenChainError("rewritten chain: the put to $key was refused as existing (412) and a fetch found nothing " *
        "there, $PUT_ATTEMPTS times over. Objects are appearing and vanishing from outside the protocol; nothing heals it."))
end

# ---------------------------------------------------------------------------
# Head discovery (ADR-0012): gallop, then bisect. Stat probes only; nothing is
# listed and nothing is cached — a miss must be seen again the moment the slot lands.
# ---------------------------------------------------------------------------

"""
    gallop(store, keyof, lo) -> Int64

The highest slot that exists, probing `stat_object(store, keyof(s))` at `lo + 1`,
`lo + 2`, `lo + 4`, … until a miss and then bisecting the last gap (ADR-0012). `lo` is
a slot known to exist — the local head — or `-1` for a copy with no head, and is
returned unchanged when `lo + 1` is absent. Sound because the chain has no gaps
(ADR-0002): a miss is the end of the chain. `O(log Δ)` probes warm, `O(log N)` cold.
"""
function gallop(store::AbstractObjectStore, keyof, lo::Integer)
    exists(s) = stat_object(store, keyof(s)) !== nothing
    lo = Int64(lo)
    hit, step = lo, Int64(1)
    probe = lo + step
    while exists(probe)
        hit = probe
        step *= 2
        probe = lo + step
    end
    while probe - hit > 1
        mid = (hit + probe) ÷ 2
        exists(mid) ? (hit = mid) : (probe = mid)
    end
    return hit
end
