# With a 63-character bucket (S3's longest) under the longest cache namespace, the cache
# path below `cache_dir` is at most 12 + 1 + 63 + 1 + 100 + 1 + 20 = 198 characters,
# which leaves 61 of MAX_PORTABLE_PATH for `cache_dir` (ADR-0034). The gateway has the
# same rules (`prefix_problem` in gateway/handler.py, ADR-0035): change both together.
const MAX_PREFIX_LENGTH = 100

const ATTACHMENTS_SEGMENT = "_attachments"

const CACHE_DIRECTORY_RULE = "it is a record-cache directory, and must be portable to " *
    "every filesystem"

# A long docstring: the keywords are the whole configuration of a client.
# No accessors: callers read `bucket`, `prefix` and `store` as fields (ADR-0019).
"""
    Chain(bucket, prefix; store = nothing, gateway = nothing, region = nothing,
          credentials = nothing, endpoint = nothing, path_style = false,
          assume_first_writer_wins = false, read_ahead = 8, cache_dir, record_host = true,
          record_user = true)

Where a chain lives and how this client talks to it. Constructing one performs no I/O.

`bucket` and `prefix` are location, never identity: the chain id is in every record. A
bucket name has no dot. A prefix has no `/` at either end, is at most 100 characters,
and has no segment `_attachments`. The bucket name and each segment of the prefix are
directories of the record cache: `a-z`, `0-9`, `.`, `_`, `-`, and no Windows device
name. Throws `ArgumentError` otherwise.

- `store`: the object store. `nothing` is the S3 client, built from `region`,
  `credentials`, `endpoint` and `path_style`.
- `gateway`: the function URL of a gateway bucket. Commits then go through the gateway,
  and the author of a record is the caller's name from AWS. Not with `store`.
- `region`: else `AWS_REGION`, else `AWS_DEFAULT_REGION`; never guessed.
- `credentials`: a `Credentials`, a callable that returns one, or `nothing` for the
  `AWS_*` environment.
- `assume_first_writer_wins`: lets `commit!` write to a store that is not AWS S3.
- `read_ahead`: how many records `sync!` fetches ahead of apply, at least 1.
- `cache_dir`: the record cache. `CHAINTABLES_CACHE_DIR`, else a directory in the depot.
- `record_host`, `record_user`: whether a record names its host and its author.

Examples: test/test_chain_examples.jl
"""
struct Chain{S <: AbstractObjectStore, C}
    bucket::String
    prefix::String
    store::S
    cache::RecordCache
    read_ahead::Int
    assume_first_writer_wins::Bool
    record_host::Bool
    record_user::Bool
    # TODO: only the tests of `s3`, `gateway` and `bucket` read these four. Delete them,
    # or give them a reader, with those files:
    # https://github.com/jonalm/julia_codestyle/issues/129
    region::Union{Nothing, String}
    credentials::C
    endpoint::Union{Nothing, String}
    path_style::Bool
end

function Chain(
        bucket::AbstractString, prefix::AbstractString;
        store = nothing, gateway = nothing, region = nothing, credentials = nothing,
        endpoint = nothing, path_style = false, assume_first_writer_wins = false,
        read_ahead = 8, cache_dir = default_cache_dir(), record_host = true,
        record_user = true,
    )
    check_bucket_name(bucket)
    check_prefix(prefix)
    read_ahead >= 1 || throw(
        ArgumentError(
            "Chain: read_ahead is $read_ahead; at least 1 record is fetched ahead"
        )
    )
    check_store_keywords(store, gateway, record_user)
    s3_keywords = s3_client_keywords(store, (; region, credentials, endpoint, path_style))
    chain_store = store_for(store, gateway, bucket, s3_keywords)
    cache = RecordCache(String(cache_dir))
    # Every slot's path is as long as this one (ADR-0034).
    record_path(cache, chain_store, bucket, slot_key(prefix, 0))
    return Chain{typeof(chain_store), typeof(s3_keywords.credentials)}(
        bucket, prefix, chain_store, cache, read_ahead, assume_first_writer_wins,
        record_host, record_user, s3_keywords...,
    )
end

function Base.show(io::IO, chain::Chain)
    print(io, "Chain(")
    show(io, chain.bucket)
    print(io, ", ")
    show(io, chain.prefix)
    print(io, "; store = ", nameof(typeof(chain.store)), ")")
    return nothing
end

# `Bucket` holds a bucket name to the same rules (ADR-0029).
function check_bucket_name(bucket::AbstractString)
    isempty(bucket) && throw(ArgumentError("Chain: the bucket name is empty"))
    '.' in bucket && throw(
        ArgumentError(
            "Chain: bucket name $(repr(bucket)) contains a dot, which breaks " *
                "certificate matching under the virtual-hosted URL ChainTables " *
                "builds; use a bucket without one"
        )
    )
    problem = portable_segment_problem(bucket)
    problem === nothing || throw(
        ArgumentError("Chain: bucket name $(repr(bucket)) $problem; $CACHE_DIRECTORY_RULE")
    )
    return nothing
end

# Refusing a bad prefix here, before any I/O, keeps `create_chain` from writing a slot 0
# that no client could cache. The prefix is opaque otherwise (ADR-0031).
function check_prefix(prefix::AbstractString)
    (startswith(prefix, "/") || endswith(prefix, "/")) && throw(
        ArgumentError(
            "Chain: prefix $(repr(prefix)) begins or ends with '/'; a slot key is " *
                "<prefix>/<12 digits>, so give the prefix without them"
        )
    )
    isempty(prefix) && return nothing
    length(prefix) <= MAX_PREFIX_LENGTH || throw(
        ArgumentError(
            "Chain: prefix $(repr(prefix)) is $(length(prefix)) characters, over " *
                "$MAX_PREFIX_LENGTH; the record cache's paths must fit Windows' " *
                "$MAX_PORTABLE_PATH under any reasonable cache_dir"
        )
    )
    foreach(segment -> check_prefix_segment(segment, prefix), split(prefix, '/'))
    return nothing
end

function check_prefix_segment(segment, prefix)
    problem = portable_segment_problem(segment)
    problem === nothing || throw(
        ArgumentError(
            "Chain: prefix $(repr(prefix)) has the segment $(repr(segment)), which " *
                "$problem; each '/'-separated segment of a slot key is a " *
                "record-cache directory, and must be portable to every filesystem"
        )
    )
    # A chain under it would be a "directory" of another chain's attachment keys.
    segment == ATTACHMENTS_SEGMENT && throw(
        ArgumentError(
            "Chain: prefix $(repr(prefix)) has the segment $(repr(segment)), which " *
                "is reserved for a chain's attachments; a chain may not live under one"
        )
    )
    return nothing
end

function check_store_keywords(store, gateway, record_user)
    store === nothing || gateway === nothing || throw(
        ArgumentError(
            "Chain: gateway and store were both given; a chain has one store, and " *
                "the gateway keyword builds it from the bucket, region and credentials"
        )
    )
    store isa Union{Nothing, AbstractObjectStore} || throw(
        ArgumentError("Chain: store is a $(typeof(store)), not an AbstractObjectStore")
    )
    _is_gateway = gateway !== nothing || store isa GatewayObjectStore
    _is_gateway && !record_user && throw(
        ArgumentError(
            "Chain: record_user = false with a gateway: the gateway refuses a record " *
                "with no author, so this chain could never commit; leave " *
                "record_user = true"
        )
    )
    return nothing
end

# The S3 client's keywords. A store that the caller supplies does not read them, so
# they are kept as given. Without one, the region and the credentials are resolved now:
# a missing one fails here, not at the first request.
s3_client_keywords(::AbstractObjectStore, given) = given

function s3_client_keywords(::Nothing, given)
    region = resolve_region(given.region)
    credentials = resolve_credentials(given.credentials)
    return (; given..., region, credentials)
end

store_for(store::AbstractObjectStore, ::Nothing, bucket, s3_keywords) = store
store_for(::Nothing, ::Nothing, bucket, s3_keywords) = S3ObjectStore(bucket; s3_keywords...)

function store_for(::Nothing, gateway, bucket, s3_keywords)
    return GatewayObjectStore(bucket, gateway; s3_keywords...)
end

# The one place where a slot becomes a key: `<prefix>/<12 digits>`, flat (ADR-0011).
function slot_key(prefix::AbstractString, slot::Integer)
    name = head_filename(slot)
    return isempty(prefix) ? name : prefix * "/" * name
end

slot_key(chain::Chain, slot::Integer) = slot_key(chain.prefix, slot)

# The bucket and prefix as one text, for a message.
function location(chain::Chain)
    return isempty(chain.prefix) ? chain.bucket : "$(chain.bucket)/$(chain.prefix)"
end

chain_of(local_copy::LocalCopy{<:Chain}, call) = local_copy.chain

function chain_of(local_copy::LocalCopy, call)
    throw(
        ArgumentError(
            "$call: the local copy at $(local_copy.path) was opened over a " *
                "$(typeof(local_copy.chain)), not a ChainTables.Chain"
        )
    )
end

# `sync!`, `write_builder` and `commit!` do not move a pinned copy (ADR-0015).
function check_live(local_copy::LocalCopy, call)
    is_pinned(local_copy) && throw(
        PinnedCopyError(;
            local_copy.path, slot = head_slot(local_copy.head),
            detail = "the call was `$call`",
        )
    )
    return nothing
end

head_slot(::Nothing) = nothing
head_slot(head_file::Head) = head_file.slot
