# ADR-0028 — the gateway store: `Chain(…; gateway = url)` routes `put_object_if_absent`
# through a Lambda function URL that checks the caller and the author before filling a
# slot; the other three verbs go to S3 directly. The author is fetched from
# `sts:GetCallerIdentity` at the first write, the record cap is 4 MiB, and a refusal is
# `WriteRefusedError`, never retried. The wire contract is issue #54 §5 and the top of
# `gateway/handler.py`.

# ---------------------------------------------------------------------------
# The store (ADR-0028, ADR-0019): built by `Chain`, held for dispatch and tests
# ---------------------------------------------------------------------------

"""
    GATEWAY_RECORD_BYTES

The record cap on a gateway store, 4 MiB (ADR-0028): a function URL carries at most
6 MB each way on the base64-encoded event, so 4 MiB of record leaves 683 KiB of
headroom. Checked in the client after `encode_record` and again in the gateway.
"""
const GATEWAY_RECORD_BYTES = 4 * 1024 * 1024

"""
    GatewayObjectStore(bucket, function_url; region, credentials, endpoint = nothing, path_style = false,
                       timeout = 60, sts_endpoint = nothing) <: AbstractObjectStore

The object store of a gateway bucket (ADR-0028): `put_object_if_absent` is a SigV4-signed
`PUT` to the gateway's function URL (service `lambda`, the chain's region), and
`fetch_object`, `stat_object` and `list_objects` run against S3 through an
[`S3ObjectStore`](@ref) built from the same `bucket`, `region`, `credentials`, `endpoint`
and `path_style` — so ADR-0016's gate applies to that half exactly as for a plain bucket.
`Chain(…; gateway = function_url)` builds one; users do not normally construct it.

- `function_url` is `scheme://host[:port]` with no path; when the host has the form
  `*.lambda-url.<region>.on.aws`, that region must equal `region`.
- The author this store puts in `client.user` is the tail of the caller ARN that
  `sts:GetCallerIdentity` returns, fetched lazily at the first write through
  [`record_author`](@ref) and memoized per access key id. `sts_endpoint` overrides
  `https://sts.<region>.amazonaws.com` for a test.
- [`record_cap`](@ref) is [`GATEWAY_RECORD_BYTES`](@ref), 4 MiB.
- A refusal by the gateway raises [`WriteRefusedError`](@ref); every other status maps onto
  ADR-0010's retry loop (see [`put_object_if_absent`](@ref)).
"""
mutable struct GatewayObjectStore <: AbstractObjectStore
    const s3::S3ObjectStore
    const function_url::String
    const host::String                        # the Host header of the function URL
    const base::String                        # scheme://host of the function URL
    const sts_endpoint::String
    const timeout::Float64
    author_key::Union{Nothing,String}         # the access key id the memoized author was fetched under
    author::Union{Nothing,String}
end

function GatewayObjectStore(bucket::AbstractString, function_url::AbstractString; region::AbstractString, credentials,
                            endpoint = nothing, path_style::Bool = false, timeout::Real = 60, sts_endpoint = nothing)
    s3 = S3ObjectStore(bucket; region, credentials, endpoint, path_style, timeout)
    scheme, hostport = parse_endpoint(function_url; what = "gateway")
    m = match(r"\.lambda-url\.([a-z0-9-]+)\.on\.aws$", hostport)
    m === nothing || m.captures[1] == region || throw(ArgumentError("Chain: region $(repr(String(region))) disagrees " *
        "with the region in the function URL host $(repr(hostport)), $(repr(m.captures[1])); SigV4 signs the region, " *
        "so the two must agree — pass the region the gateway is deployed in"))
    base = scheme * "://" * hostport
    sts = sts_endpoint === nothing ? "https://sts.$region.amazonaws.com" : join(parse_endpoint(sts_endpoint; what = "sts_endpoint"), "://")
    return GatewayObjectStore(s3, base, hostport, base, sts, Float64(timeout), nothing, nothing)
end

Base.show(io::IO, s::GatewayObjectStore) = print(io, "GatewayObjectStore(", repr(s.s3.bucket), ", ", repr(s.function_url),
    "; region = ", repr(s.s3.region), s.s3.endpoint === nothing ? "" : ", endpoint = " * repr(s.s3.endpoint),
    s.s3.path_style ? ", path_style = true" : "", ")")

is_aws(store::GatewayObjectStore) = is_aws(store.s3)
s3_half(store::GatewayObjectStore) = store.s3

record_cap(::GatewayObjectStore) = GATEWAY_RECORD_BYTES

# The three read verbs are the S3 half's (ADR-0028: reads stay direct).
fetch_object(store::GatewayObjectStore, key::AbstractString) = fetch_object(store.s3, key)
stat_object(store::GatewayObjectStore, key::AbstractString) = stat_object(store.s3, key)
list_objects(store::GatewayObjectStore, prefix::AbstractString; start_after::Union{Nothing,AbstractString} = nothing) =
    list_objects(store.s3, prefix; start_after)

# ---------------------------------------------------------------------------
# The author (ADR-0028): the tail of the caller ARN, the rule the gateway applies to the
# request context, applied here to `sts:GetCallerIdentity`. Fetched at the first write
# and memoized per access key id, so refreshed credentials for another identity fetch again.
# ---------------------------------------------------------------------------

# `assumed-role/<role>/<session>` or `user/[path/]<name>`; anything else — the account
# root, a bare role, a service principal — the gateway refuses as not_allowed, so it is
# refused here without the round trip.
const PRINCIPAL_ARN = r"^arn:[^:]+:(?:iam|sts)::[0-9]{12}:(?:assumed-role/[^/]+/(?<session>[^/]+)|user/(?:[^/]+/)*(?<user>[^/]+))$"

"""
    author_from_arn(arn) -> String

The author rule (ADR-0028): the text after the last `/` of a caller ARN that names an
IAM user (`user/[path/]<name>`) or an assumed role (`assumed-role/<role>/<session>`); for
an Identity Center session the session name is the user name. Any other principal raises
`WriteRefusedError` with `reason = "not_allowed"`, the gateway's own verdict on it.
"""
function author_from_arn(arn::AbstractString)
    m = match(PRINCIPAL_ARN, arn)
    m === nothing && throw(WriteRefusedError("write refused: the caller $arn is neither an IAM user nor an " *
        "assumed role, and a gateway fills slots for those alone (ADR-0028). Log in as a user — aws sso login for an " *
        "Identity Center user — and commit again."; reason = "not_allowed"))
    return String(something(m[:session], m[:user]))
end

# The `<Arn>` of a GetCallerIdentity response; anything else is a transport failure.
function author_from_sts_response(body)
    text = String(copy(body))
    m = match(r"<Arn>([^<]*)</Arn>", text)
    m === nothing && throw(TransportError("sts:GetCallerIdentity returned no Arn: $(first(text, 200))"; status = 200))
    return author_from_arn(xml_unescape(m.captures[1]))
end

"""
    record_author(store::GatewayObjectStore) -> String

The caller's name from `sts:GetCallerIdentity` — [`author_from_arn`](@ref) of its `Arn` —
signed for service `sts` with the store's credentials, at `store.sts_endpoint`. Memoized
per access key id: a second call under the same key makes no request, and credentials
for another key fetch again. The environment is never consulted (ADR-0028).
"""
function record_author(store::GatewayObjectStore)
    credentials = current_credentials(store.s3)
    store.author_key == credentials.access_key_id && store.author !== nothing && return store.author
    body = Vector{UInt8}("Action=GetCallerIdentity&Version=2011-06-15")
    host = split(store.sts_endpoint, "://"; limit = 2)[2]
    headers = signed_headers(credentials, store.s3.region, "sts", host, "POST", "/";
                             body, headers = ["content-type" => "application/x-www-form-urlencoded; charset=utf-8"])
    url = store.sts_endpoint * "/"
    response = http_request(url, "POST", headers, body, store.timeout)
    response.status == 200 || throw(failure("POST", url, response))
    author = author_from_sts_response(response.body)
    store.author_key, store.author = credentials.access_key_id, author
    return author
end

# ---------------------------------------------------------------------------
# The put (issue #54 §5, §6): `PUT /?key=<key>` signed for service lambda, the record as
# the body; every reply is JSON `{code, message}`, mapped onto the port and the retry loop.
# ---------------------------------------------------------------------------

"""
    put_object_if_absent(store::GatewayObjectStore, key, bytes) -> PutOutcome

The conditional put through the gateway (ADR-0028): a SigV4-signed `PUT` to the function
URL with the key in the query string, `Content-Type: application/cbor`, and the record
as the body — the gateway adds `If-None-Match: *` under its own role. The reply maps as:

| gateway / Lambda reply | result |
|---|---|
| `200` | `PutOutcome(true, 200)` |
| `412` (`slot_taken`) | `PutOutcome(false, 412)` — the read-back decides, as on S3 |
| `403` with a gateway `code` | [`WriteRefusedError`](@ref) with `reason = code` |
| `403` without one | [`WriteRefusedError`](@ref) with `reason = "forbidden"` |
| `409`, `429`, `5xx`, no response | `TransportError`, retried by the commit layer |
| `400`, `413` | `TransportError`, not retried, carrying the gateway's code and message |

Bytes over [`GATEWAY_RECORD_BYTES`](@ref) are refused here with an `ArgumentError` before
any request; the commit layer checks the cap first and reports it as `WriteBuilderError`.
"""
function put_object_if_absent(store::GatewayObjectStore, key::AbstractString, bytes)
    body = bytes isa Vector{UInt8} ? bytes : Vector{UInt8}(bytes)
    length(body) <= GATEWAY_RECORD_BYTES || throw(ArgumentError("GatewayObjectStore: $(length(body)) bytes for $key is over " *
        "the gateway's 4 MiB record cap ($GATEWAY_RECORD_BYTES bytes; ADR-0028); the commit layer checks this before the put"))
    query = Pair{String,String}["key" => String(key)]
    headers = signed_headers(current_credentials(store.s3), store.s3.region, "lambda", store.host, "PUT", "/";
                             query, body, headers = ["content-type" => "application/cbor"])
    url = store.base * "/" * query_string(query)
    response = http_request(url, "PUT", headers, body, store.timeout)
    status = response.status
    status == 200 && return PutOutcome(true, 200)
    status == 412 && return PutOutcome(false, 412)
    code, message = gateway_reply(response.body)
    if status == 403
        reason = something(code, "forbidden")
        throw(WriteRefusedError(refusal_message(store, String(key), reason, message); key = String(key), caller = store.author, reason))
    end
    detail = code === nothing ? "" : " " * code * (message === nothing ? "" : ": " * message)
    throw(TransportError("PUT $url: HTTP $status$detail"; status))     # 409, 429 and 5xx among them, which the commit layer retries
end

# The refusal's message (ADR-0020's three parts): what happened, the evidence, the next
# move — which differs by `reason`, because who must act differs.
function refusal_message(store::GatewayObjectStore, key, reason, message)
    caller = something(store.author, "<unresolved>")
    where = "the gateway at $(store.base) refused to fill $key"
    if reason == "forbidden"
        return "write refused: AWS refused the invocation of $(store.base) for caller $caller before the gateway ran " *
               "(HTTP 403 with no gateway code)$(message === nothing ? "" : ": " * message). The principal lacks " *
               "lambda:InvokeFunctionUrl and lambda:InvokeFunction on the function: ask the bucket's operator for the " *
               "writer permission set (ADR-0028)."
    elseif reason == "not_allowed"
        return "write refused: $where for caller $caller — not_allowed" *
               "$(message === nothing ? "" : ": " * message). The gateway policy has no entry for this name on this prefix, " *
               "or the principal is neither an IAM user nor an assumed role: ask the bucket's operator to add the name to " *
               "the gateway policy (ADR-0028)."
    elseif reason == "author_mismatch"
        return "write refused: $where for caller $caller — author_mismatch" *
               "$(message === nothing ? "" : ": " * message). client.user was resolved from sts:GetCallerIdentity and " *
               "the gateway saw another caller: a bug, or the credentials changed between the STS call and the put; " *
               "report it (ADR-0028)."
    end
    return "write refused: $where for caller $caller — $reason$(message === nothing ? "" : ": " * message). " *
           "This gateway answered with a reason this client does not know; stop and have the bucket's operator look (ADR-0028)."
end

# `{"code": "<code>", "message": "<text>"}` read without a JSON dependency (ADR-0027): the
# code is a plain identifier, the message a JSON string with its escapes undone. Either
# is `nothing` when absent — Lambda's own replies carry `Message` (capitalised), never
# `code`, and that text is read as the message so a bare 403 says why AWS refused.
function gateway_reply(body::Vector{UInt8})
    text = String(copy(body))
    code = match(r"\"code\"\s*:\s*\"([A-Za-z0-9_]*)\"", text)
    message = match(r"\"[Mm]essage\"\s*:\s*\"((?:[^\"\\]|\\.)*)\"", text)
    return (code === nothing ? nothing : String(code.captures[1]),
            message === nothing ? nothing : json_unescape(message.captures[1]))
end

function json_unescape(s::AbstractString)
    occursin('\\', s) || return String(s)
    io = IOBuffer()
    i = firstindex(s)
    while i <= lastindex(s)
        c = s[i]
        if c == '\\' && i < lastindex(s)
            i = nextind(s, i)
            e = s[i]
            if e == 'u' && i + 4 <= lastindex(s)
                write(io, Char(parse(UInt32, s[i+1:i+4]; base = 16)))
                i += 4
            else
                write(io, e == 'n' ? '\n' : e == 't' ? '\t' : e == 'r' ? '\r' : e == 'b' ? '\b' : e == 'f' ? '\f' : e)
            end
        else
            write(io, c)
        end
        i = nextind(s, i)
    end
    return String(take!(io))
end
