# The keywords need their bullets: their names do not say what each promises.
"""
    Chain(bucket, prefix; store = nothing, gateway = nothing, region = nothing,
          credentials = nothing, endpoint = nothing, path_style = false,
          assume_first_writer_wins = false, read_ahead = 8,
          cache_dir = default_cache_dir(), record_host = true, record_user = true)
    Chain(bucket::Bucket, prefix; kw...)

Where a chain lives and how this client reaches it. Constructing one performs no I/O.

`bucket` and `prefix` are location, never identity. A bucket name with a dot is refused,
and each `/`-separated segment of the prefix must be portable to every filesystem.

- `store`: the `AbstractObjectStore` to use. `nothing` builds an `S3ObjectStore` from
  `region`, `credentials`, `endpoint` and `path_style`; with `gateway`, the function URL
  of a gateway bucket's gateway, a `GatewayObjectStore`.
- `assume_first_writer_wins`: promise that a store which is not AWS S3 never overwrites
  a key, so commits to it are allowed.
- `read_ahead`: how many records `sync!` fetches ahead of applying, at least 1.
- `record_host`, `record_user`: whether a record names this host and its author.

Examples: test/test_chain_examples.jl
"""
struct Chain{S <: AbstractObjectStore}
    bucket::String
    prefix::String
    region::Union{Nothing, String}
    # style: field nothing, a Credentials, or a callable that returns one
    credentials::Any
    endpoint::Union{Nothing, String}
    path_style::Bool
    assume_first_writer_wins::Bool
    read_ahead::Int
    cache::RecordCache
    store::S
    record_host::Bool
    record_user::Bool
end

# The gateway mirrors these rules (`prefix_problem` in gateway/handler.py, ADR-0035):
# change both together. With a 63-character bucket under the longest namespace, a cache
# path below `cache_dir` is at most 198 characters, leaving 61 for `cache_dir` (ADR-0034).
const MAX_PREFIX_LENGTH = 100

# A chain under this segment would be a "directory" of another chain's attachments.
const ATTACHMENTS_SEGMENT = "_attachments"

const GATEWAY_NEEDS_AUTHOR =
    "record_user = false with a gateway: the gateway refuses a record with no author"

function Chain(
        bucket::AbstractString, prefix::AbstractString; store = nothing, gateway = nothing,
        region = nothing, credentials = nothing, endpoint = nothing, path_style = false,
        assume_first_writer_wins = false, read_ahead = 8, cache_dir = default_cache_dir(),
        record_host = true, record_user = true
    )
    check_bucket_name(bucket)
    check_prefix(prefix)
    read_ahead >= 1 || throw(ArgumentError("read_ahead must be ≥ 1, got $read_ahead"))
    check_store_keywords(store, gateway, record_user)
    if store === nothing
        region = resolve_region(region)
        credentials = resolve_credentials(credentials)
        store = s3_client(bucket, gateway; region, credentials, endpoint, path_style)
    end
    store isa AbstractObjectStore ||
        throw(ArgumentError("store is a $(typeof(store)), not an AbstractObjectStore"))
    cache = RecordCache(; dir = cache_dir)
    # Every slot's cache path is as long as slot 0's, so checking it checks them all.
    record_path(cache, store, bucket, slot_key(prefix, 0))
    return Chain{typeof(store)}(
        bucket, prefix, region, credentials, endpoint,
        path_style, assume_first_writer_wins, read_ahead, cache, store, record_host,
        record_user
    )
end

"""
    check_bucket_name(bucket)

Throw `ArgumentError` unless `bucket` is a usable bucket name: not empty, no dot (it
breaks certificate matching under virtual-hosted URLs), and portable as a directory.
"""
function check_bucket_name(bucket::AbstractString)
    isempty(bucket) && throw(ArgumentError("the bucket name is empty"))
    '.' in bucket && throw(ArgumentError("bucket name $(repr(bucket)) contains a dot"))
    problem = portable_segment_problem(bucket)
    problem === nothing ||
        throw(ArgumentError("bucket name $(repr(bucket)) $problem"))
    return nothing
end

function check_prefix(prefix::AbstractString)
    (startswith(prefix, "/") || endswith(prefix, "/")) &&
        throw(ArgumentError("prefix $(repr(prefix)) begins or ends with '/'"))
    isempty(prefix) && return nothing
    n = length(prefix)
    n <= MAX_PREFIX_LENGTH || throw(ArgumentError(prefix_too_long(prefix, n)))
    foreach(s -> check_prefix_segment(prefix, s), split(prefix, '/'))
    return nothing
end

function prefix_too_long(prefix, n)
    return "prefix $(repr(prefix)) is $n characters, over $MAX_PREFIX_LENGTH"
end

function check_store_keywords(store, gateway, record_user)
    gateway === nothing || store === nothing ||
        throw(ArgumentError("give gateway or store, not both: a chain has one store"))
    _is_gateway = gateway !== nothing || store isa GatewayObjectStore
    _is_gateway && (record_user || throw(ArgumentError(GATEWAY_NEEDS_AUTHOR)))
    return nothing
end

function check_prefix_segment(prefix, segment)
    where = "prefix $(repr(prefix)) has the segment $(repr(segment))"
    problem = portable_segment_problem(segment)
    problem === nothing || throw(ArgumentError("$where, which $problem"))
    segment == ATTACHMENTS_SEGMENT &&
        throw(ArgumentError("$where, which is reserved for a chain's attachments"))
    return nothing
end

s3_client(bucket, ::Nothing; kw...) = S3ObjectStore(bucket; kw...)
s3_client(bucket, gateway; kw...) = GatewayObjectStore(bucket, gateway; kw...)

# The credentials must not reach a log, so they are not shown.
function Base.show(io::IO, c::Chain)
    print(io, "Chain(")
    show(io, c.bucket)
    print(io, ", ")
    show(io, c.prefix)
    print(io, "; store = ", nameof(typeof(c.store)), ")")
    return nothing
end

"""
    slot_key(chain, slot)

Return the key of `slot` under the chain's prefix: `<prefix>/<12-digit slot>`, or the bare
12 digits under an empty prefix. The one place the slot-to-key mapping lives.
"""
slot_key(chain::Chain, slot::Integer) = slot_key(chain.prefix, slot)

function slot_key(prefix::AbstractString, slot::Integer)
    return isempty(prefix) ? head_filename(slot) : prefix * "/" * head_filename(slot)
end

cached_record(chain::Chain, slot::Integer) = cached_record(chain, slot_key(chain, slot))

function location(chain::Chain)
    return isempty(chain.prefix) ? chain.bucket : "$(chain.bucket)/$(chain.prefix)"
end

function slot_exists(chain::Chain, slot)
    return stat_object(chain.store, slot_key(chain, slot)) !== nothing
end

# The chain id slot 0 in the record cache names, or `nothing` when slot 0 is not cached
# or does not decode: what `open` checks a bound copy against (localcopy.jl).
function expected_chain_id(chain::Chain)
    bytes = cached_record(chain, 0)
    bytes === nothing && return nothing
    record = try_decode_record(bytes, 0)
    return record === nothing ? nothing : chain_id_string(record.chain_id)
end

"""
    try_decode_record(bytes, slot)

Return the record `bytes` decode to as `slot`, or `nothing` when they are malformed.
"""
function try_decode_record(bytes, slot)
    try
        return Ops.decode_record(bytes; slot)
    catch e
        e isa MalformedRecordError || rethrow()
        return nothing
    end
end

"""
    gallop(chain, lo)

Return the highest slot that exists, probing with `stat_object` at `lo + 1`, `lo + 2`,
`lo + 4`, … until a miss, then bisecting the last gap. `lo` is a slot known to exist, or
`-1`. Sound because the chain has no gaps: a miss is the end of the chain.
"""
function gallop(chain::Chain, lo::Integer)
    lo = Int64(lo)
    hit, step = lo, Int64(1)
    probe = lo + step
    while slot_exists(chain, probe)
        hit = probe
        step *= 2
        probe = lo + step
    end
    while probe - hit > 1
        mid = (hit + probe) ÷ 2
        hit, probe = slot_exists(chain, mid) ? (mid, probe) : (hit, mid)
    end
    return hit
end

"""
    chain_of(copy, call)

Return the `Chain` the local copy was opened over. Throws `ArgumentError` naming `call`
when it was opened over anything else.
"""
function chain_of(copy::LocalCopy, call)
    copy.chain isa Chain && return copy.chain
    T = typeof(copy.chain)
    throw(ArgumentError("$call: the local copy at $(copy.path) was opened over a $T"))
end

function refuse_pinned(copy::LocalCopy, call)
    is_pinned(copy) || return nothing
    slot = copy.head === nothing ? nothing : copy.head.slot
    throw(PinnedCopyError(; path = copy.path, slot, call))
end

"""
    with_cleanup_on_failure(f, cleanup)

Return `f()`; when it throws, call `cleanup()` before the exception propagates.
"""
function with_cleanup_on_failure(f, cleanup)
    _is_done = false
    try
        result = f()
        _is_done = true
        return result
    finally
        _is_done || cleanup()
    end
end

"""
    with_rollback(f, copy)

Return `f()`; when it throws, drop the copy's model and staged files (`discard!`), so the
copy stays at its head.
"""
with_rollback(f, copy::LocalCopy) = with_cleanup_on_failure(f, () -> discard!(copy))
