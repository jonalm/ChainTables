# The attachment cache's directory inside the cache directory, beside the namespaces
# (ADR-0046). No store may take it as its namespace.
const ATTACHMENT_CACHE_NAME = "attachments"

# `mem-` and 8 hex digits: the longest namespace of the package's own stores.
const MAX_NAMESPACE_LENGTH = 12

# Windows' MAX_PATH less the terminating NUL, in UTF-16 code units: the longest path
# that opens on every platform without opting in to long paths (ADR-0034).
const MAX_PORTABLE_PATH = 259

# A record is written to `<16 hex digits>.tmp` beside its final name, then renamed.
const CACHE_TEMP_NAME_LENGTH = 20

# Windows reserves these names, with or without an extension, in every directory.
const WINDOWS_DEVICE_NAMES = Set(
    ["con", "prn", "aux", "nul", ("com$i" for i in 0:9)..., ("lpt$i" for i in 0:9)...]
)

const PORTABLE_CHARACTERS = "only a-z, 0-9, '.', '_' and '-' are portable to every " *
    "filesystem"

"""
    RecordCache

The record cache: the directory of the records that this machine has fetched, as
`dir/namespace/bucket/key`.

It can be deleted at any time; every record is then fetched again. A cached record is
read without asking the store, but it is not the chain's word: a reader holds it
against the chain, and fetches again what fails.
"""
struct RecordCache
    dir::String
end

function default_cache_dir()
    haskey(ENV, "CHAINTABLES_CACHE_DIR") && return ENV["CHAINTABLES_CACHE_DIR"]
    return joinpath(first(DEPOT_PATH), "chaintables", "records")
end

# The file that the record at `key` is cached at. Each `/`-separated segment of the key
# is a directory (ADR-0011). The path stays inside the cache and opens on every
# platform (ADR-0034), or the call throws `ArgumentError`.
function record_path(cache::RecordCache, store::AbstractObjectStore, bucket, key)
    namespace = cache_namespace(store)
    check_namespace(namespace, store)
    segments = (namespace, bucket, split(key, '/')...)
    foreach(segment -> check_cache_segment(segment, bucket, key), segments)
    path = joinpath(cache.dir, segments...)
    check_cache_path_length(path)
    return path
end

function check_namespace(namespace, store)
    T = nameof(typeof(store))
    length(namespace) <= MAX_NAMESPACE_LENGTH || throw(
        ArgumentError(
            "the cache namespace $(repr(namespace)) of $T is over " *
                "$MAX_NAMESPACE_LENGTH characters; its cache_namespace method must " *
                "return a shorter name"
        )
    )
    namespace == ATTACHMENT_CACHE_NAME && throw(
        ArgumentError(
            "the cache namespace $(repr(namespace)) of $T is the attachment cache's " *
                "directory; its cache_namespace method must return another name"
        )
    )
    return nothing
end

function check_cache_segment(segment, bucket, key)
    problem = portable_segment_problem(segment)
    problem === nothing || throw(
        ArgumentError(
            "segment $(repr(segment)) of bucket $(repr(bucket)), key $(repr(key)) " *
                problem
        )
    )
    return nothing
end

# Returns why `segment` cannot be one segment of a record cache path on every platform,
# or `nothing` if it can (ADR-0034). The rule is narrower than any one filesystem
# needs, so a key that maps on one platform maps on all: no separator, no drive colon,
# and no pair of names that a case-insensitive filesystem folds together.
function portable_segment_problem(segment::AbstractString)
    isempty(segment) && return "is empty"
    segment in (".", "..") && return "names a directory relative to its parent"
    bad = findfirst(!is_portable_character, segment)
    bad === nothing || return "contains $(repr(segment[bad])); $PORTABLE_CHARACTERS"
    endswith(segment, '.') && return "ends with '.', which Windows strips"
    first(split(segment, '.')) in WINDOWS_DEVICE_NAMES &&
        return "is a Windows device name"
    return nothing
end

function is_portable_character(c::AbstractChar)
    return 'a' <= c <= 'z' || '0' <= c <= '9' || c in ('.', '_', '-')
end

function check_cache_path_length(path)
    n = longest_cache_path(path)
    n <= MAX_PORTABLE_PATH || throw(
        ArgumentError(
            "the record cache path $(repr(path)) is $n characters long with its " *
                "temporary file, over the $MAX_PORTABLE_PATH Windows allows; use a " *
                "shorter cache_dir or prefix"
        )
    )
    return nothing
end

# In UTF-16 code units, Windows' measure: the absolute directory, then the longer of
# the record's name and the temporary file's.
function longest_cache_path(path::AbstractString)
    directory = length(transcode(UInt16, abspath(dirname(path))))
    return directory + 1 + max(length(basename(path)), CACHE_TEMP_NAME_LENGTH)
end

# A file is written to a temporary name in its directory and renamed into place, so an
# interrupted write never leaves a truncated record (ADR-0010).
function write_cache_file(path, bytes)
    directory = dirname(path)
    mkpath(directory)
    temporary = joinpath(directory, bytes2hex(rand(UInt8, 8)) * ".tmp")
    try
        write(temporary, bytes)
        Base.rename(temporary, path)
    finally
        rm(temporary; force = true)
    end
    return nothing
end
