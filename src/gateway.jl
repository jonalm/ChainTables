# The gateway store (ADR-0028): `put_object_if_absent` goes through a Lambda function URL
# that checks the caller and the author before it fills a slot; the other three verbs go
# to S3 directly. The wire contract is issue #54 §5 and the top of `gateway/handler.py`.

# A function URL carries at most 6 MB each way on the base64-encoded event, so 4 MiB of
# record leaves 683 KiB of headroom (ADR-0028).
const GATEWAY_RECORD_BYTES = 4 * 1024 * 1024

const NOT_IN_OUR_BUCKET =
    "the gateway answered 200 created, and the bucket does not hold the object"

const S3_REFUSED_PUT =
    "S3 refused the gateway's own put, so the gateway's deployment is wrong and a retry " *
    "cannot help"

const S3_REFUSED_MINT =
    "S3 refused one of the gateway's own calls for the attachment (its HEAD, " *
    "GetObjectRetention or PutObjectRetention), so the gateway's deployment is wrong and " *
    "a retry cannot help"

const KNOWN_REASONS = ("not_allowed", "author_mismatch")

"""
    GatewayObjectStore(bucket, function_url; region, credentials, endpoint = nothing,
                       path_style = false, timeout = 60, sts_endpoint = nothing)

The object store of a gateway bucket. `Chain(…; gateway = function_url)`
builds one; users rarely construct it.

`put_object_if_absent` is a SigV4-signed `PUT` to the function URL, service `lambda`,
and the record cap is 4 MiB. The three reads go to S3 through an `S3ObjectStore` of the
same `bucket`, `region`, `credentials`, `endpoint` and `path_style`, so the AWS-only gate
judges that half. The author this store writes is the caller's name from
`sts:GetCallerIdentity`, fetched at the first write and memoized per access key id.

- `function_url`: `scheme://host[:port]`; a `*.lambda-url.<region>.on.aws` host must name
  `region`.
- `sts_endpoint`: replaces `https://sts.<region>.amazonaws.com` (`.com.cn` for `cn-*`).

Examples: test/test_gateway_examples.jl
"""
mutable struct GatewayObjectStore <: AbstractObjectStore
    const s3::S3ObjectStore
    const function_url::String # scheme://host[:port], no path
    const host::String # the Host header of the function URL
    const sts_endpoint::String
    const timeout::Float64
    author_key::Union{Nothing, String} # the access key id `author` was fetched under
    author::Union{Nothing, String}
end

function GatewayObjectStore(
        bucket::AbstractString, function_url::AbstractString; region::AbstractString,
        credentials, endpoint = nothing, path_style::Bool = false, timeout::Real = 60,
        sts_endpoint = nothing
    )
    s3 = S3ObjectStore(bucket; region, credentials, endpoint, path_style, timeout)
    base, hostport = gateway_base(function_url, region)
    sts = sts_base(sts_endpoint, region)
    return GatewayObjectStore(s3, base, hostport, sts, timeout, nothing, nothing)
end

# The China partition's regions (`cn-*`) live under `amazonaws.com.cn`.
function sts_base(::Nothing, region::AbstractString)
    suffix = startswith(region, "cn-") ? "amazonaws.com.cn" : "amazonaws.com"
    return "https://sts.$region.$suffix"
end

sts_base(endpoint, region) = join(parse_endpoint(endpoint; what = "sts_endpoint"), "://")

"""
    gateway_base(function_url, region)

Return `(base, hostport)` of `function_url`, `base` being `scheme://host[:port]`. A
`*.lambda-url.<region>.on.aws` host must name `region`, since SigV4 signs the region;
`region = nothing` is not checked.
"""
function gateway_base(function_url::AbstractString, region)
    scheme, hostport = parse_endpoint(function_url; what = "gateway")
    m = match(r"\.lambda-url\.([a-z0-9-]+)\.on\.aws\z", hostport)
    (region === nothing || m === nothing || m.captures[1] == region) ||
        throw(ArgumentError(region_mismatch_message(region, hostport, m.captures[1])))
    return scheme * "://" * hostport, hostport
end

function region_mismatch_message(region, hostport, url_region)
    return "Chain: region $(repr(String(region))) disagrees with the region in the " *
        "function URL host $(repr(hostport)), $(repr(url_region)); SigV4 signs the " *
        "region, so the two must agree: pass the region the gateway is deployed in"
end

# The default would print the S3 half's credentials supplier.
function Base.show(io::IO, s::GatewayObjectStore)
    print(io, "GatewayObjectStore(")
    show(io, s.s3.bucket)
    print(io, ", ")
    show(io, s.function_url)
    print(io, "; region = ")
    show(io, s.s3.region)
    s.s3.endpoint === nothing || print_keyword(io, "endpoint", s.s3.endpoint)
    s.s3.path_style && print(io, ", path_style = true")
    print(io, ")")
    return nothing
end

is_aws(store::GatewayObjectStore) = is_aws(store.s3)

# Reads go to S3 directly (ADR-0040).
cache_namespace(store::GatewayObjectStore) = cache_namespace(store.s3)

s3_half(store::GatewayObjectStore) = store.s3

record_cap(::GatewayObjectStore) = GATEWAY_RECORD_BYTES

# The three reads are the S3 half's (ADR-0028).
fetch_object(store::GatewayObjectStore, key::AbstractString) = fetch_object(store.s3, key)

stat_object(store::GatewayObjectStore, key::AbstractString) = stat_object(store.s3, key)

function list_objects(
        store::GatewayObjectStore, prefix::AbstractString;
        start_after::Union{Nothing, AbstractString} = nothing
    )
    return list_objects(store.s3, prefix; start_after)
end

# The gateway adds `If-None-Match: *` under its own role. A 412 (`slot_taken`) is left to
# the read-back, as on S3; a 403, or a 502 `s3_refused`, is a refusal never retried;
# every other status is a `TransportError`, which the commit layer retries or not.
function put_object_if_absent(store::GatewayObjectStore, key::AbstractString, bytes)
    body = convert(Vector{UInt8}, bytes)
    length(body) <= GATEWAY_RECORD_BYTES ||
        throw(ArgumentError(over_cap_message(key, length(body))))
    query = ["key" => String(key)]
    url = store.function_url * "/" * query_string(query)
    headers = signed_headers(
        current_credentials(store.s3), store.s3.region, "lambda", store.host, "PUT", "/";
        query, body, headers = ["content-type" => "application/cbor"]
    )
    response = http_request(url, "PUT", headers, body, store.timeout)
    response.status == 200 && return created_in_our_bucket(store, String(key), body)
    response.status == 412 && return PutOutcome(false, 412)
    return gateway_failure(store, String(key), url, response)
end

function over_cap_message(key, n_bytes)
    return "GatewayObjectStore: $n_bytes bytes for $key is over the gateway's 4 MiB " *
        "record cap ($GATEWAY_RECORD_BYTES bytes; ADR-0028); the commit layer checks " *
        "this before the put"
end

# A gateway fills the bucket of its own deployment, whatever bucket the client named, so
# its `200 created` is believed only once the bucket this store reads holds these bytes
# at the key (ADR-0029); else a mispaired gateway commits, in silence, into a bucket
# nobody reads. Our bucket may hold another writer's record there, so the bytes are
# compared. S3 is read-after-write consistent.
function created_in_our_bucket(store::GatewayObjectStore, key, body)
    held = fetch_object(store.s3, key)
    held == body && return PutOutcome(true, 200)
    detail = held === nothing ? NOT_IN_OUR_BUCKET : other_object_detail(held, body)
    bucket = store.s3.bucket
    throw(GatewayMismatchError(; key, bucket, gateway = store.function_url, detail))
end

function other_object_detail(held, body)
    return "the gateway answered 200 created, and the bucket holds another object " *
        "there ($(length(held)) bytes, not the $(length(body)) sent)"
end

function gateway_failure(store::GatewayObjectStore, key, url, response)
    code, message = gateway_reply(response.body)
    if response.status == 403 || code == "s3_refused"
        reason = something(code, "forbidden")
        detail = refusal_message(store, key, reason, message)
        throw(WriteRefusedError(; key, caller = store.author, reason, detail))
    end
    throw(TransportError(reply_detail("PUT", url, code, message); response.status))
end

function reply_detail(method, url, code, message)
    code === nothing && return "$method $url"
    message === nothing && return "$method $url: $code"
    return "$method $url: $code: $message"
end

"""
    refusal_message(store, key, reason, message; mint = false)

Return the `detail` of a gateway's refusal with `reason`: which case it was, and the
gateway's `message` when it sent one. `mint`: refused on the mint route.
"""
function refusal_message(
        store::GatewayObjectStore, key, reason, message; mint::Bool = false
    )
    said = message === nothing ? "" : ": " * message
    reason == "forbidden" && return forbidden_detail(store) * said
    reason == "s3_refused" && return (mint ? S3_REFUSED_MINT : S3_REFUSED_PUT) * said
    return "the gateway at $(store.function_url) refused to " *
        refused_action(reason, mint) * said
end

function forbidden_detail(store::GatewayObjectStore)
    return "AWS refused the invocation of $(store.function_url) before the gateway ran " *
        "(HTTP 403 with no gateway code)"
end

function refused_action(reason, mint)
    action = mint ? "mint the upload" : "fill the slot"
    reason in KNOWN_REASONS && return action
    return action * ", for a reason this client does not know"
end
