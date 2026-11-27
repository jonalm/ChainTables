# A function URL carries at most 6 MB each way on the base64-encoded event, so 4 MiB of
# record leaves 683 KiB of headroom. The gateway checks it again (ADR-0028).
const GATEWAY_RECORD_BYTES = 4 * 1024 * 1024

const LAMBDA_URL_HOST = r"\.lambda-url\.([a-z0-9-]+)\.on\.aws\z"

# The access key id that the memoized author was fetched under, and the author.
const AuthorMemo = @NamedTuple{access_key_id::String, author::String}

"""
    GatewayObjectStore(bucket, function_url; region, credentials, endpoint = nothing,
                       path_style = false, timeout = 60, sts_endpoint = nothing)

The object store of a gateway bucket: `put_object_if_absent` is a signed `PUT` to the
gateway's function URL, and the three reads go to S3 through an `S3ObjectStore` built
from the other arguments. `Chain(…; gateway)` builds one.

- `function_url`: `scheme://host[:port]`. Its region, when the host names one, must be
  `region`.
- `sts_endpoint`: where the author is asked for; `nothing` is AWS's own STS.
"""
mutable struct GatewayObjectStore <: AbstractObjectStore
    const s3::S3ObjectStore
    const function_url::String  # scheme://host[:port]
    const host::String  # the Host header of the function URL
    const sts_endpoint::String  # scheme://host[:port]
    author_memo::Union{Nothing, AuthorMemo}
end

# `timeout` and `sts_endpoint`: only a test sets them, for a short timeout and an STS
# double.
function GatewayObjectStore(
        bucket::AbstractString, function_url::AbstractString; region::AbstractString,
        credentials, endpoint = nothing, path_style::Bool = false, timeout::Real = 60,
        sts_endpoint = nothing,
    )
    s3 = S3ObjectStore(bucket; region, credentials, endpoint, path_style, timeout)
    base, host = gateway_base(function_url, region)
    sts = sts_base(sts_endpoint, region)
    return GatewayObjectStore(s3, base, host, sts, nothing)
end

# The function URL as `scheme://host[:port]`, and its host. `Bucket` holds a gateway to
# the same rules (ADR-0029). SigV4 signs the region, so a function URL whose host names
# another region than the chain's could never be invoked; `nothing` is not known yet.
function gateway_base(function_url::AbstractString, region)
    scheme, host = parse_endpoint(function_url; what = "gateway")
    url_region = lambda_url_region(host)
    region === nothing || url_region === nothing || url_region == region || throw(
        ArgumentError(
            "Chain: region $(repr(String(region))) disagrees with the region in the " *
                "function URL host $(repr(host)), $(repr(url_region)); pass the region " *
                "that the gateway is in"
        )
    )
    return scheme * "://" * host, host
end

function lambda_url_region(host::AbstractString)
    m = match(LAMBDA_URL_HOST, host)
    return m === nothing ? nothing : String(m[1])
end

# The China partition's regions live under `amazonaws.com.cn`.
function sts_base(::Nothing, region::AbstractString)
    suffix = startswith(region, "cn-") ? ".amazonaws.com.cn" : ".amazonaws.com"
    return "https://sts." * region * suffix
end

function sts_base(endpoint::AbstractString, region::AbstractString)
    scheme, host = parse_endpoint(endpoint; what = "sts_endpoint")
    return scheme * "://" * host
end

function Base.show(io::IO, store::GatewayObjectStore)
    s3 = store.s3
    print(io, "GatewayObjectStore(")
    show(io, s3.bucket)
    print(io, ", ")
    show(io, store.function_url)
    show_keyword(io, "; ", "region", s3.region)
    s3.endpoint === nothing || show_keyword(io, ", ", "endpoint", s3.endpoint)
    s3.path_style && show_keyword(io, ", ", "path_style", true)
    print(io, ")")
    return nothing
end

# Reads go to S3 directly (ADR-0028), so the S3 half decides what counts as AWS and where
# the record cache keeps them (ADR-0040).
is_aws(store::GatewayObjectStore) = is_aws(store.s3)
cache_namespace(store::GatewayObjectStore) = cache_namespace(store.s3)
s3_half(store::GatewayObjectStore) = store.s3

record_cap(::GatewayObjectStore) = GATEWAY_RECORD_BYTES

fetch_object(store::GatewayObjectStore, key::AbstractString) = fetch_object(store.s3, key)
stat_object(store::GatewayObjectStore, key::AbstractString) = stat_object(store.s3, key)

function list_objects(
        store::GatewayObjectStore, prefix::AbstractString;
        start_after::Union{Nothing, AbstractString} = nothing,
    )
    return list_objects(store.s3, prefix; start_after)
end

# The gateway adds `If-None-Match: *` under its own role. A refusal is never retried; a
# `409`, a `429` and a `5xx` are `TransportError`s that the commit layer retries.
function put_object_if_absent(store::GatewayObjectStore, key::AbstractString, bytes)
    body = convert(Vector{UInt8}, bytes)
    n_bytes = length(body)
    # The commit layer checks the cap first, and reports it as `WriteBuilderError`.
    n_bytes <= GATEWAY_RECORD_BYTES || throw(
        ArgumentError(
            "GatewayObjectStore: $n_bytes bytes for $key is over the gateway's 4 MiB " *
                "record cap of $GATEWAY_RECORD_BYTES bytes"
        )
    )
    put = put_through_gateway(store, key, body)
    status = put.response.status
    status == 200 && return created_in_our_bucket(store, String(key), body)
    status == 412 && return PutOutcome(false, 412)
    reply = gateway_reply(put.response.body)
    is_refusal(status, reply.code) && throw(
        WriteRefusedError(;
            key, gateway = store.function_url, caller = memoized_author(store),
            reason = something(reply.code, "forbidden"),
            detail = something(reply.message, ""),
        )
    )
    throw(TransportError(; method = "PUT", put.url, status, detail = reply_text(reply)))
end

# The key goes in the query, and the record is the body.
function put_through_gateway(store::GatewayObjectStore, key::AbstractString, body)
    query = ["key" => String(key)]
    headers = signed_headers(
        current_credentials(store.s3); store.s3.region, service = "lambda", store.host,
        method = "PUT", path = "/", query, body,
        headers = ["content-type" => "application/cbor"],
    )
    url = store.function_url * "/" * query_string(query)
    response = http_request("PUT", url; headers, body, store.s3.timeout)
    return (; url, response)
end

# A `403` with no gateway code is AWS's own, before the gateway ran: "forbidden". A
# `502 s3_refused` is S3 refusing the gateway's own put, which no retry can help.
is_refusal(status::Integer, code) = status == 403 || code == "s3_refused"

memoized_author(store::GatewayObjectStore) = memoized_author(store.author_memo)
memoized_author(::Nothing) = nothing
memoized_author(memo::AuthorMemo) = memo.author

# A gateway fills its own bucket, whatever bucket the client named, so its `200` is
# believed only once the bucket this store reads holds these bytes at the key
# (ADR-0029). Else a mispaired bucket and gateway would commit into a bucket that
# nobody reads. S3 is read-after-write consistent.
function created_in_our_bucket(store::GatewayObjectStore, key::String, body)
    held = fetch_object(store.s3, key)
    held == body && return PutOutcome(true, 200)
    throw(
        GatewayMismatchError(;
            key, store.s3.bucket, gateway = store.function_url,
            detail = "the gateway answered 200 created, and " * held_text(held, body),
        )
    )
end

held_text(::Nothing, body) = "the bucket does not hold the key"

function held_text(held::Vector{UInt8}, body)
    return "the bucket holds another record there, $(length(held)) bytes, not the " *
        "$(length(body)) sent"
end
