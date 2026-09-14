# #34 step 9 — ADR-0010, ADR-0016, ADR-0019, ADR-0020: the S3 client behind
# `store = nothing`. A vendored SigV4 signer over stdlib `Downloads` and `SHA` — no
# dependency added — implementing the four verbs of the port (store.jl), credentials
# resolved at `Chain` construction, the endpoint rules, and the AWS-only gate: a warning
# at `open`, a refusal at `commit!` and `create_chain` unless `assume_first_writer_wins`.

import Downloads
using SHA: sha256, hmac_sha256

# ---------------------------------------------------------------------------
# Credentials and region (ADR-0019, ADR-0010)
# ---------------------------------------------------------------------------

"""
    Credentials(access_key_id, secret_access_key; session_token = nothing)

What the SigV4 signer signs with (ADR-0010). `session_token` is sent as
`x-amz-security-token` when present, so an aws-vault session, SSO and MFA all work.
Shown with the secret redacted.
"""
struct Credentials
    access_key_id::String
    secret_access_key::String
    session_token::Union{Nothing,String}
end
Credentials(access_key_id, secret_access_key; session_token = nothing) =
    Credentials(String(access_key_id), String(secret_access_key),
                session_token === nothing ? nothing : String(session_token))

Base.show(io::IO, c::Credentials) =
    print(io, "Credentials(", repr(c.access_key_id), ", <redacted>",
          c.session_token === nothing ? "" : "; session_token = <redacted>", ")")

"""
    credentials_from_env() -> Credentials

The credentials in `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` and, when set,
`AWS_SESSION_TOKEN` (ADR-0010) — what `aws-vault exec` injects. An `ArgumentError`
naming the missing variable when either key is absent or empty.
"""
function credentials_from_env()
    id = get(ENV, "AWS_ACCESS_KEY_ID", "")
    secret = get(ENV, "AWS_SECRET_ACCESS_KEY", "")
    missing_vars = [name for (name, value) in (("AWS_ACCESS_KEY_ID", id), ("AWS_SECRET_ACCESS_KEY", secret)) if isempty(value)]
    isempty(missing_vars) || throw(ArgumentError("Chain: credentials = nothing reads AWS_ACCESS_KEY_ID and " *
        "AWS_SECRET_ACCESS_KEY from the environment, and $(join(missing_vars, " and ")) is not set. Export them " *
        "(aws-vault exec <profile> -- julia …), or pass credentials = ChainTables.Credentials(id, secret) or a " *
        "callable returning one."))
    token = get(ENV, "AWS_SESSION_TOKEN", "")
    return Credentials(id, secret; session_token = isempty(token) ? nothing : token)
end

# A value with `access_key_id` and `secret_access_key` properties (and optionally
# `session_token`), such as a NamedTuple, is accepted as credentials.
Base.convert(::Type{Credentials}, x::Credentials) = x
function Base.convert(::Type{Credentials}, x)
    props = propertynames(x)
    (:access_key_id in props && :secret_access_key in props) || throw(ArgumentError("Chain: credentials must be a " *
        "ChainTables.Credentials, or a value with access_key_id and secret_access_key properties; got a $(typeof(x))"))
    return Credentials(getproperty(x, :access_key_id), getproperty(x, :secret_access_key);
                       session_token = :session_token in props ? getproperty(x, :session_token) : nothing)
end

"""
    resolve_credentials(credentials) -> Credentials | callable

What `Chain` does with its `credentials` keyword when the store is the S3 client
(ADR-0019): `nothing` reads the `AWS_*` environment now and errors if absent; a
[`Credentials`](@ref) (or anything with `access_key_id` and `secret_access_key`
properties) is taken as is; a callable is called once now, to fail fast, and again
before every request, so a long-lived reader outlives an aws-vault session (ADR-0010).
"""
function resolve_credentials(credentials)
    credentials === nothing && return credentials_from_env()
    if credentials isa Credentials || hasproperty(credentials, :access_key_id)
        return convert(Credentials, credentials)
    end
    isempty(methods(credentials)) && throw(ArgumentError("Chain: credentials is a $(typeof(credentials)), which is " *
        "neither a ChainTables.Credentials, a value with access_key_id and secret_access_key properties, nor a " *
        "callable returning one"))
    convert(Credentials, credentials())          # fail fast: a callable that cannot produce credentials errors here
    return credentials
end

current_credentials(store) = store.credentials isa Credentials ? store.credentials : convert(Credentials, store.credentials())

"""
    resolve_region(region) -> String

The region the S3 client signs for (ADR-0019): `region` when given, else `AWS_REGION`,
else `AWS_DEFAULT_REGION` — never guessed, because a wrong region is a signature error
instead of a useful message. An `ArgumentError` when none is set.
"""
function resolve_region(region)
    region === nothing || return String(region)
    for name in ("AWS_REGION", "AWS_DEFAULT_REGION")
        value = get(ENV, name, "")
        isempty(value) || return value
    end
    throw(ArgumentError("Chain: region is required by the S3 client — SigV4 signs it — and neither the region keyword " *
        "nor AWS_REGION nor AWS_DEFAULT_REGION is set. Pass region = \"eu-north-1\" (the bucket's region)."))
end

# ---------------------------------------------------------------------------
# The store: URL rules and the AWS test (ADR-0010, ADR-0016)
# ---------------------------------------------------------------------------

"""
    S3ObjectStore(bucket; region, credentials, endpoint = nothing, path_style = false, timeout = 60) <: AbstractObjectStore

The S3 client (ADR-0010): the four verbs of the port over a vendored SigV4 signer and
stdlib `Downloads`, one request per call and no retry inside — libcurl retries nothing
on its own, so ADR-0010's "the transport never retries" is obtained, not configured.
`region` and `credentials` are already resolved (see [`resolve_region`](@ref) and
[`resolve_credentials`](@ref)). `Chain` builds one when `store = nothing`.

- `endpoint = nothing` is AWS: `https://<bucket>.s3.<region>.amazonaws.com` (virtual-hosted),
  or `https://s3.<region>.amazonaws.com/<bucket>` with `path_style = true`.
- `endpoint = "scheme://host[:port]"` is any other host: `<bucket>.<host>` virtual-hosted,
  `<host>/<bucket>` path-style. Supported only when the host ends in `.amazonaws.com` or
  `.amazonaws.com.cn` (ADR-0016; see [`is_aws`](@ref)); anything else warns at `open`
  and refuses at `commit!` unless the chain's `assume_first_writer_wins` is set.
- `timeout`: seconds for one request to complete; a request that does not raises
  `TransportError` with no status, which the commit layer retries (ADR-0010).

A bucket name containing a dot is refused: it breaks certificate matching under the
virtual-hosted URL (ADR-0010).
"""
struct S3ObjectStore <: AbstractObjectStore
    bucket::String
    region::String
    credentials::Any
    endpoint::Union{Nothing,String}
    endpoint_host::Union{Nothing,String}      # the configured host without port; nothing for AWS's own URL
    path_style::Bool
    host::String                              # the Host header, as libcurl derives it from `base`
    base::String                              # scheme://host; `object_path` adds the bucket under path-style
    timeout::Float64
end

function S3ObjectStore(bucket::AbstractString; region::AbstractString, credentials,
                       endpoint = nothing, path_style::Bool = false, timeout::Real = 60)
    bucket = String(bucket)
    isempty(bucket) && throw(ArgumentError("S3ObjectStore: the bucket name is empty"))
    '.' in bucket && throw(ArgumentError("S3ObjectStore: bucket name $(repr(bucket)) contains a dot, which breaks " *
        "certificate matching under the virtual-hosted URL ChainTables builds (ADR-0010); use a bucket without one"))
    timeout > 0 || throw(ArgumentError("S3ObjectStore: timeout is $timeout; it must be positive seconds"))
    if endpoint === nothing
        scheme, hostport, endpoint_host = "https", "s3.$region.amazonaws.com", nothing
    else
        scheme, hostport = parse_endpoint(endpoint)
        endpoint_host = first(split(hostport, ':'))
    end
    host = path_style ? hostport : bucket * "." * hostport
    base = scheme * "://" * host
    return S3ObjectStore(bucket, String(region), credentials, endpoint === nothing ? nothing : String(endpoint),
                         endpoint_host, path_style, host, base, Float64(timeout))
end

Base.show(io::IO, s::S3ObjectStore) = print(io, "S3ObjectStore(", repr(s.bucket), "; region = ", repr(s.region),
    s.endpoint === nothing ? "" : ", endpoint = " * repr(s.endpoint), s.path_style ? ", path_style = true" : "", ")")

# `scheme://host[:port]`, nothing more: a path, query or fragment on the endpoint is
# refused rather than silently dropped. A default port is stripped, since libcurl omits
# it from the Host header it sends and the signature covers that header.
function parse_endpoint(endpoint::AbstractString; what = "endpoint")
    m = match(r"^(https?)://([^/?#\s]+)/?$"i, endpoint)
    m === nothing && throw(ArgumentError("Chain: $what $(repr(endpoint)) is not of the form scheme://host[:port] " *
        "(http or https, no path); the bucket and key are added by ChainTables"))
    scheme = lowercase(m.captures[1])
    hostport = lowercase(m.captures[2])
    default = scheme == "https" ? ":443" : ":80"
    endswith(hostport, default) && (hostport = hostport[1:end-length(default)])
    return scheme, hostport
end

"""
    is_aws(store::S3ObjectStore) -> Bool

ADR-0016's "what counts as AWS": no endpoint configured, or an endpoint whose host ends
in `.amazonaws.com` or `.amazonaws.com.cn` — which admits the FIPS, dual-stack, GovCloud
and China endpoints. A suffix test on a host, not a security control.
"""
is_aws(store::S3ObjectStore) = store.endpoint_host === nothing ||
    endswith(store.endpoint_host, ".amazonaws.com") || endswith(store.endpoint_host, ".amazonaws.com.cn")

# The S3 client a store reads through: itself, or a gateway store's S3 half (gateway.jl).
s3_half(store::S3ObjectStore) = store

# ---------------------------------------------------------------------------
# The gate (ADR-0016, ADR-0019, ADR-0020): warn at open, refuse at commit. A gateway
# store is gated on its S3 half: the reads and the read-back go there (ADR-0028).
# ---------------------------------------------------------------------------

unsupported_store(chain) = chain isa Chain && chain.store isa Union{S3ObjectStore,GatewayObjectStore} && !is_aws(chain.store)

"""
    warn_unsupported_store(chain) -> nothing

`open`'s half of ADR-0016's gate: a chain whose S3 client points at a host that is not
AWS warns once per process (`maxlog = 1`, ADR-0019) that reads work and commits will
refuse. Anything other than such a chain — a supplied store, a test's stand-in — is
silent.
"""
function warn_unsupported_store(chain)
    unsupported_store(chain) || return nothing
    @warn "unsupported object store: the endpoint $(s3_half(chain.store).endpoint) is not AWS S3, the only store ChainTables v1 " *
          "claims (ADR-0016). This local copy syncs and reads normally; commit!(w) will refuse unless the chain is " *
          "constructed with assume_first_writer_wins = true." maxlog = 1
    return nothing
end

"""
    refuse_unsupported_store(chain, call) -> nothing

The commit half of ADR-0016's gate, run by `commit!` and `create_chain` before anything
is applied or written: an S3 client at a host that is not AWS raises
`UnsupportedStoreError` — naming the endpoint, the promise ChainTables requires, the
consequence if the store breaks it, and the field that lifts the refusal — unless the
chain's `assume_first_writer_wins` is set. Never `maxlog`: a suppressed warning must not
become a suppressed refusal (ADR-0019).
"""
function refuse_unsupported_store(chain, call)
    unsupported_store(chain) && !chain.assume_first_writer_wins || return nothing
    endpoint = s3_half(chain.store).endpoint
    throw(UnsupportedStoreError("unsupported object store: $call refuses to commit to $endpoint, which is not AWS S3, " *
        "the only store ChainTables v1 claims (ADR-0016). The commit protocol requires that a PUT carrying " *
        "`If-None-Match: *` either creates the key or fails with 412 and never overwrites an existing key, and " *
        "that a GET of a key just created returns it. A store that breaks that promise tells both racing clients " *
        "they won: the second record replaces the first in a slot written once — a rewritten chain for every " *
        "client that applied the first, silent data loss for those that did not. Use AWS S3, or construct the " *
        "Chain with assume_first_writer_wins = true to make that promise on the store's behalf.";
        endpoint))
end

# ---------------------------------------------------------------------------
# SigV4 (ADR-0010): the canonical request, the string to sign, the signature.
# Pure functions of their arguments, so the AWS worked examples are test vectors.
# ---------------------------------------------------------------------------

const UNRESERVED = Set{UInt8}(codeunits("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~"))

"""
    uri_encode(s; keep_slash = false) -> String

RFC 3986 percent-encoding of every byte of `s` outside the unreserved set, uppercase hex,
with `/` kept when `keep_slash` (an object key's path) and encoded otherwise (a query
parameter). S3's canonical URI is the key encoded once — never twice.
"""
function uri_encode(s::AbstractString; keep_slash::Bool = false)
    io = IOBuffer()
    for b in codeunits(s)
        if b in UNRESERVED || (keep_slash && b == UInt8('/'))
            write(io, b)
        else
            write(io, '%', uppercase(string(b; base = 16, pad = 2)))
        end
    end
    return String(take!(io))
end

canonical_query(query) = join(sort!([uri_encode(String(k)) * "=" * uri_encode(String(v)) for (k, v) in query]), '&')
query_string(query) = isempty(query) ? "" : "?" * canonical_query(query)

"""
    sign_request(credentials, region, method, path, query, headers, payload_hash, amzdate; service = "s3")
        -> (; canonical_request, string_to_sign, signature, authorization)

SigV4 (ADR-0010): `path` is the already-encoded canonical URI, `query` the parameters as
pairs, `headers` **every** header to sign as lowercase-name pairs — `host` and the
`x-amz-*` headers are required by AWS, and everything sent is signed because that is
what the reference implementations do — `payload_hash` the hex SHA-256 of the body,
`amzdate` the request time as `yyyymmddTHHMMSSZ`, and `service` the scope's service:
`s3` for the bucket, `lambda` for a gateway's function URL and `sts` for
`GetCallerIdentity` (ADR-0028). The `authorization` field is the `Authorization`
header's value.
"""
function sign_request(credentials::Credentials, region::AbstractString, method::AbstractString, path::AbstractString,
                      query, headers, payload_hash::AbstractString, amzdate::AbstractString; service::AbstractString = "s3")
    sorted = sort([lowercase(String(k)) => strip(String(v)) for (k, v) in headers]; by = first)
    signed_headers = join(first.(sorted), ';')
    canonical_headers = join((k * ":" * v * "\n" for (k, v) in sorted))
    canonical_request = join((method, path, canonical_query(query), canonical_headers, signed_headers, payload_hash), '\n')
    datestamp = amzdate[1:8]
    scope = "$datestamp/$region/$service/aws4_request"
    string_to_sign = join(("AWS4-HMAC-SHA256", amzdate, scope, bytes2hex(sha256(canonical_request))), '\n')
    k = hmac_sha256(Vector{UInt8}("AWS4" * credentials.secret_access_key), datestamp)
    k = hmac_sha256(k, String(region))
    k = hmac_sha256(k, String(service))
    k = hmac_sha256(k, "aws4_request")
    signature = bytes2hex(hmac_sha256(k, string_to_sign))
    authorization = "AWS4-HMAC-SHA256 Credential=$(credentials.access_key_id)/$scope, SignedHeaders=$signed_headers, " *
                    "Signature=$signature"
    return (; canonical_request, string_to_sign, signature, authorization)
end

# Civil dates from Unix seconds without loading Dates: Howard Hinnant's algorithms.
function civil_from_days(days::Integer)
    z = days + 719468
    era = fld(z, 146097)
    doe = z - era * 146097
    yoe = (doe - doe ÷ 1460 + doe ÷ 36524 - doe ÷ 146096) ÷ 365
    y = yoe + era * 400
    doy = doe - (365 * yoe + yoe ÷ 4 - yoe ÷ 100)
    mp = (5 * doy + 2) ÷ 153
    d = doy - (153 * mp + 2) ÷ 5 + 1
    m = mp < 10 ? mp + 3 : mp - 9
    return (m <= 2 ? y + 1 : y, m, d)
end

function days_from_civil(y::Integer, m::Integer, d::Integer)
    y -= m <= 2
    era = fld(y, 400)
    yoe = y - era * 400
    doy = (153 * (m > 2 ? m - 3 : m + 9) + 2) ÷ 5 + d - 1
    doe = yoe * 365 + yoe ÷ 4 - yoe ÷ 100 + doy
    return era * 146097 + doe - 719468
end

"""
    amz_date(unix_seconds) -> String

`unix_seconds` as SigV4's `x-amz-date`, `yyyymmddTHHMMSSZ` in UTC.
"""
function amz_date(unix_seconds::Integer)
    days, secs = fldmod(Int64(unix_seconds), 86400)
    y, m, d = civil_from_days(days)
    h, rem = fldmod(secs, 3600)
    mi, s = fldmod(rem, 60)
    return string(y; pad = 4) * string(m; pad = 2) * string(d; pad = 2) * "T" *
           string(h; pad = 2) * string(mi; pad = 2) * string(s; pad = 2) * "Z"
end

const MONTHS = Dict("Jan" => 1, "Feb" => 2, "Mar" => 3, "Apr" => 4, "May" => 5, "Jun" => 6,
                    "Jul" => 7, "Aug" => 8, "Sep" => 9, "Oct" => 10, "Nov" => 11, "Dec" => 12)

# `Last-Modified: Wed, 12 Oct 2009 17:50:00 GMT` (a HEAD's header) and
# `<LastModified>2009-10-12T17:50:30.000Z</LastModified>` (a listing's element), both
# to whole seconds since the epoch, which is all `ObjectMeta.modified` promises.
function parse_http_date(s::AbstractString)
    m = match(r"^\w{3}, (\d{1,2}) (\w{3}) (\d{4}) (\d\d):(\d\d):(\d\d) GMT$", strip(s))
    m === nothing && throw(TransportError("cannot parse the Last-Modified header $(repr(s))"))
    d, mon, y, h, mi, sec = m.captures
    haskey(MONTHS, mon) || throw(TransportError("cannot parse the Last-Modified header $(repr(s))"))
    return days_from_civil(parse(Int, y), MONTHS[mon], parse(Int, d)) * 86400 +
           parse(Int, h) * 3600 + parse(Int, mi) * 60 + parse(Int, sec)
end

function parse_iso_date(s::AbstractString)
    m = match(r"^(\d{4})-(\d\d)-(\d\d)T(\d\d):(\d\d):(\d\d)(?:\.\d+)?Z$", strip(s))
    m === nothing && throw(TransportError("cannot parse the LastModified value $(repr(s))"))
    y, mo, d, h, mi, sec = parse.(Int, m.captures)
    return days_from_civil(y, mo, d) * 86400 + h * 3600 + mi * 60 + sec
end

# ---------------------------------------------------------------------------
# One request (ADR-0010): sign, send, and hand back the status, headers and body.
# Failure to get a response at all — connect failure, timeout, TLS — is a
# `TransportError` with no status; a response is returned whatever its status, for the
# verb to interpret.
# ---------------------------------------------------------------------------

object_path(store::S3ObjectStore, key::AbstractString) =
    (store.path_style ? "/" * store.bucket : "") * "/" * uri_encode(key; keep_slash = true)

"""
    signed_headers(credentials, region, service, host, method, path; query, body, headers, now) -> Vector{Pair{String,String}}

The full header list of one signed request to `service` (ADR-0010, ADR-0028): `host`,
`x-amz-content-sha256`, `x-amz-date`, `x-amz-security-token` under a session, the
caller's `headers`, then `authorization` over all of them, and `content-length` —
unsigned, because libcurl owns it — for a `PUT` or `POST`. `path` is the already-encoded
canonical URI.
"""
function signed_headers(credentials::Credentials, region::AbstractString, service::AbstractString, host::AbstractString,
                        method::AbstractString, path::AbstractString;
                        query = Pair{String,String}[], body = UInt8[], headers = Pair{String,String}[],
                        now::Integer = floor(Int64, time()))
    amzdate = amz_date(now)
    payload_hash = bytes2hex(sha256(body))
    signed = Pair{String,String}["host" => String(host), "x-amz-content-sha256" => payload_hash, "x-amz-date" => amzdate]
    credentials.session_token === nothing || push!(signed, "x-amz-security-token" => credentials.session_token)
    for (k, v) in headers
        push!(signed, lowercase(String(k)) => String(v))
    end
    sig = sign_request(credentials, region, method, path, query, signed, payload_hash, amzdate; service)
    sent = copy(signed)
    push!(sent, "authorization" => sig.authorization)
    method in ("PUT", "POST") && push!(sent, "content-length" => string(length(body)))
    return sent
end

"""
    request_headers(store, method, key; query, body, headers, now) -> (; url, headers)

The URL and the full header list of one signed S3 request — [`signed_headers`](@ref) for
service `s3` at the object's path. Split from [`s3_request`](@ref) so a test can see
what is signed.
"""
function request_headers(store::S3ObjectStore, method::AbstractString, key::AbstractString;
                         query = Pair{String,String}[], body = UInt8[], headers = Pair{String,String}[],
                         now::Integer = floor(Int64, time()))
    path = object_path(store, key)
    sent = signed_headers(current_credentials(store), store.region, "s3", store.host, method, path; query, body, headers, now)
    return (; url = store.base * path * query_string(query), headers = sent)
end

"""
    http_request(url, method, headers, body, timeout) -> (; status, headers, body)

One request over stdlib `Downloads`, no retry inside (ADR-0010): the response whatever
its status, for the caller to interpret; no response at all — connect failure, timeout,
TLS — is a `TransportError` with no status. `body` is sent for a `PUT` or `POST`.
"""
function http_request(url::AbstractString, method::AbstractString, headers, body, timeout::Real)
    output = IOBuffer()
    response = Downloads.request(url; method, headers, input = method in ("PUT", "POST") ? IOBuffer(body) : nothing,
                                 output, timeout, throw = false)
    response isa Downloads.RequestError &&
        throw(TransportError("$method $url: no response — $(response.message)"))
    return (; status = response.status, headers = response.headers, body = take!(output))
end

function s3_request(store::S3ObjectStore, method::AbstractString, key::AbstractString;
                    query = Pair{String,String}[], body = UInt8[], headers = Pair{String,String}[])
    req = request_headers(store, method, key; query, body, headers)
    return http_request(req.url, method, req.headers, body, store.timeout)
end

header(response, name) = (i = findfirst(kv -> kv[1] == name, response.headers); i === nothing ? nothing : response.headers[i][2])

# The message of a failed request: the status and, when AWS sent its XML error document
# (S3's, or STS's), its `Code` and `Message`.
failure(method, store::S3ObjectStore, key, response) = failure(method, store.base * object_path(store, key), response)
function failure(method, url::AbstractString, response)
    body = String(copy(response.body))
    code = match(r"<Code>([^<]*)</Code>", body)
    message = match(r"<Message>([^<]*)</Message>", body)
    detail = code === nothing ? "" : " " * xml_unescape(code.captures[1]) *
             (message === nothing ? "" : ": " * xml_unescape(message.captures[1]))
    return TransportError("$method $url: HTTP $(response.status)$detail"; status = response.status)
end

function xml_unescape(s::AbstractString)
    occursin('&', s) || return String(s)
    return replace(s, r"&(#x[0-9a-fA-F]+|#[0-9]+|amp|lt|gt|quot|apos);" => m -> begin
        e = m[2:end-1]
        e == "amp" ? "&" : e == "lt" ? "<" : e == "gt" ? ">" : e == "quot" ? "\"" : e == "apos" ? "'" :
        string(Char(startswith(e, "#x") ? parse(Int, e[3:end]; base = 16) : parse(Int, e[2:end])))
    end)
end

# ---------------------------------------------------------------------------
# The four verbs (ADR-0010, ADR-0019): absent is nothing, failure raises; one request
# each — a listing's pages are each one request, and none is retried.
# ---------------------------------------------------------------------------

function fetch_object(store::S3ObjectStore, key::AbstractString)
    response = s3_request(store, "GET", key)
    response.status == 200 && return response.body
    response.status == 404 && return nothing
    throw(failure("GET", store, key, response))
end

function put_object_if_absent(store::S3ObjectStore, key::AbstractString, bytes)
    body = bytes isa Vector{UInt8} ? bytes : Vector{UInt8}(bytes)
    response = s3_request(store, "PUT", key; body, headers = ["if-none-match" => "*"])   # the bare asterisk (ADR-0016 rule 3)
    response.status == 200 && return PutOutcome(true, 200)
    response.status == 412 && return PutOutcome(false, 412)
    throw(failure("PUT", store, key, response))      # a 409 among them, which the commit layer retries
end

function stat_object(store::S3ObjectStore, key::AbstractString)
    response = s3_request(store, "HEAD", key)
    response.status == 404 && return nothing
    response.status == 200 || throw(failure("HEAD", store, key, response))
    size = header(response, "content-length")
    modified = header(response, "last-modified")
    (size === nothing || modified === nothing) &&
        throw(TransportError("HEAD $(store.base)$(object_path(store, key)): the response lacks Content-Length or Last-Modified"; status = 200))
    return ObjectMeta(String(key), parse(Int64, strip(size)), parse_http_date(modified))
end

function list_objects(store::S3ObjectStore, prefix::AbstractString; start_after::Union{Nothing,AbstractString} = nothing)
    listed = ObjectMeta[]
    token = nothing
    while true
        query = Pair{String,String}["list-type" => "2", "prefix" => String(prefix)]
        start_after === nothing || push!(query, "start-after" => String(start_after))
        token === nothing || push!(query, "continuation-token" => token)
        response = s3_request(store, "GET", ""; query)
        response.status == 200 || throw(failure("GET", store, "", response))
        body = String(copy(response.body))
        for m in eachmatch(r"<Contents>(.*?)</Contents>"s, body)
            entry = m.captures[1]
            key = match(r"<Key>([^<]*)</Key>", entry)
            size = match(r"<Size>([^<]*)</Size>", entry)
            modified = match(r"<LastModified>([^<]*)</LastModified>", entry)
            (key === nothing || size === nothing || modified === nothing) &&
                throw(TransportError("GET $(store.base)/?list-type=2: a <Contents> entry lacks Key, Size or LastModified"; status = 200))
            push!(listed, ObjectMeta(xml_unescape(key.captures[1]), parse(Int64, size.captures[1]), parse_iso_date(modified.captures[1])))
        end
        truncated = match(r"<IsTruncated>([^<]*)</IsTruncated>", body)
        (truncated !== nothing && strip(truncated.captures[1]) == "true") || return listed
        next = match(r"<NextContinuationToken>([^<]*)</NextContinuationToken>", body)
        next === nothing && throw(TransportError("GET $(store.base)/?list-type=2: IsTruncated without a NextContinuationToken"; status = 200))
        token = xml_unescape(next.captures[1])
    end
end
