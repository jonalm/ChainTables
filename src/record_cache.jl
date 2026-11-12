"""
    RecordCache(; dir = default_cache_dir())

The record cache: the machine-wide directory of transaction records a client has fetched,
keyed by the store's `cache_namespace`, the bucket and the key. Disposable, and never the
chain's word: a reader holds what it serves against the chain.
"""
struct RecordCache
    dir::String
end

RecordCache(; dir = default_cache_dir()) = RecordCache(String(dir))

# The attachment cache's directory inside `cache_dir`, beside the namespaces (ADR-0046),
# so no store may take it as its namespace.
const ATTACHMENT_CACHE_NAME = "attachments"

# Windows' MAX_PATH less the terminating NUL, in UTF-16 code units: the longest path that
# opens on every platform without opting in to long paths (ADR-0034).
const MAX_PORTABLE_PATH = 259

# A record is written to `<16 hex digits>.tmp` beside its final name, then renamed.
const CACHE_TEMP_NAME_LENGTH = 20

# Windows reserves these names, with or without an extension, in every directory.
const WINDOWS_DEVICE_NAMES = Set(
    [
        "con", "prn", "aux", "nul", ("com$i" for i in 0:9)..., ("lpt$i" for i in 0:9)...,
    ]
)

const PORTABLE_CHARACTERS =
    "only a-z, 0-9, '.', '_' and '-' are portable to every filesystem"

"""
    default_cache_dir()

Return where the record cache lives unless a chain says otherwise:
`CHAINTABLES_CACHE_DIR` when set, else `first(DEPOT_PATH)/chaintables/records`.
"""
function default_cache_dir()
    depot_dir = () -> joinpath(first(DEPOT_PATH), "chaintables", "records")
    return get(depot_dir, ENV, "CHAINTABLES_CACHE_DIR")
end

# The bucket and the key are both text from the store; one value type for them would
# reach every store's methods, which take plain keys.
"""
    record_path(cache, store, bucket, key)
    record_path(chain, key)

Return the file the record at `key` is cached at: `cache.dir/namespace/bucket/key`, each
`/`-separated segment of `key` a directory. Throws `ArgumentError` when a segment is not
portable to every filesystem or the path is longer than Windows allows.
"""
function record_path(
        cache::RecordCache, store::AbstractObjectStore, bucket::AbstractString,
        key::AbstractString
    )
    namespace = checked_namespace(store)
    segments = split(key, '/')
    foreach(s -> check_cache_segment(s, bucket, key), (namespace, bucket, segments...))
    path = joinpath(cache.dir, namespace, bucket, segments...)
    n = longest_cache_path(path)
    n <= MAX_PORTABLE_PATH || throw(ArgumentError(path_too_long(path, n)))
    return path
end

function record_path(chain, key::AbstractString)
    return record_path(chain.cache, chain.store, chain.bucket, key)
end

function checked_namespace(store::AbstractObjectStore)
    namespace = cache_namespace(store)
    T = typeof(store)
    length(namespace) <= MAX_NAMESPACE_LENGTH ||
        throw(ArgumentError("the cache namespace $(repr(namespace)) of $T is too long"))
    namespace == ATTACHMENT_CACHE_NAME &&
        throw(ArgumentError("the cache namespace of $T names the attachment cache"))
    return namespace
end

function check_cache_segment(segment, bucket, key)
    problem = portable_segment_problem(segment)
    where = "bucket $(repr(bucket)), key $(repr(key))"
    problem === nothing ||
        throw(ArgumentError("segment $(repr(segment)) of $where $problem"))
    return nothing
end

"""
    portable_segment_problem(s)

Return why `s` cannot be one segment of a cache path on every platform, or `nothing`.

A segment is lowercase ASCII letters, digits, `.`, `_` and `-`, is not `.` or `..`, does
not end in `.`, and is not a Windows device name (`con`, `nul.txt`, …).
"""
function portable_segment_problem(s::AbstractString)
    isempty(s) && return "is empty"
    s in (".", "..") && return "names a directory relative to its parent"
    i = findfirst(!is_portable_char, s)
    i === nothing || return "contains $(repr(s[i])); $PORTABLE_CHARACTERS"
    endswith(s, '.') && return "ends with '.', which Windows strips"
    first(split(s, '.')) in WINDOWS_DEVICE_NAMES && return "is a Windows device name"
    return nothing
end

function is_portable_char(c::AbstractChar)
    return 'a' <= c <= 'z' || '0' <= c <= '9' || c in ('.', '_', '-')
end

"""
    longest_cache_path(path)

Return the length, in UTF-16 code units (Windows' measure), of the longest path the cache
writes for the record at `path`: its directory plus the longer of its name and the
temporary file's.
"""
function longest_cache_path(path::AbstractString)
    name_length = max(length(basename(path)), CACHE_TEMP_NAME_LENGTH)
    return length(transcode(UInt16, abspath(dirname(path)))) + 1 + name_length
end

function path_too_long(path, n)
    return "the record cache path $(repr(path)) is $n characters long with its " *
        "temporary file, over the $MAX_PORTABLE_PATH Windows allows; " *
        "use a shorter cache_dir or prefix"
end

"""
    cached_record(chain, key)

Return the record cache's bytes for `key`, or `nothing` when it holds none. No request
reaches the store.
"""
function cached_record(chain, key::AbstractString)
    path = record_path(chain, key)
    return isfile(path) ? read(path) : nothing
end

"""
    fetch_record(chain, key)

Return `(bytes, cached)`: the record cache's bytes for `key` with `cached = true`, else
the store's with `cached = false`, cached on the way. `bytes` is `nothing` when the store
holds no object; nothing is cached then, so a slot is seen the moment it lands.
"""
function fetch_record(chain, key::AbstractString)
    bytes = cached_record(chain, key)
    bytes === nothing || return bytes, true
    bytes = fetch_object(chain.store, key)
    bytes === nothing || cache_record!(chain, key, bytes)
    return bytes, false
end

"""
    heal_record!(chain, key, bytes)

Cache `bytes`, which the store returned for `key`, replacing a cached file that differs.
A reader calls it only once the store's bytes pass the chain's check.
"""
function heal_record!(chain, key::AbstractString, bytes)
    cached_record(chain, key) == bytes && return nothing
    cache_record!(chain, key, bytes)
    return nothing
end

"""
    cache_record!(chain, key, bytes)

Write `bytes` to the cache as the record at `key`: to a temporary file beside it, renamed
into place, so an interrupted write never leaves a truncated record.
"""
function cache_record!(chain, key::AbstractString, bytes)
    path = record_path(chain, key)
    mkpath(dirname(path))
    tmp = joinpath(dirname(path), bytes2hex(rand(UInt8, 8)) * ".tmp")
    try
        write(tmp, bytes)
        Base.Filesystem.rename(tmp, path)
    finally
        rm(tmp; force = true)
    end
    return nothing
end
