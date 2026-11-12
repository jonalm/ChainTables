# SigV4 (ADR-0010): pure functions of their arguments, so AWS's worked examples are their
# test vectors.

const UNRESERVED = Set{UInt8}(
    codeunits("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~")
)

"""
    sign_request(credentials, region, method, path, query, headers, payload_hash, amzdate;
                 service = "s3")

Return `(; canonical_request, string_to_sign, signature, authorization)` of one SigV4
request; `authorization` is the `Authorization` header's value.

`path` is the canonical URI, already encoded; `query` the parameters as pairs; `headers`
every header to sign, `host` and the `x-amz-*` headers among them; `payload_hash` the hex
SHA-256 of the body; `amzdate` the time as `yyyymmddTHHMMSSZ`. `service` is `s3` for the
bucket, `lambda` for a gateway's function URL and `sts` for `GetCallerIdentity`.
"""
function sign_request(
        credentials::Credentials, region::AbstractString, method::AbstractString,
        path::AbstractString, query, headers, payload_hash::AbstractString,
        amzdate::AbstractString; service::AbstractString = "s3"
    )
    sorted = sort(map(canonical_header, headers); by = first)
    names = join(map(first, sorted), ';')
    header_lines = join(map(header_line, sorted))
    canonical_request = join(
        (method, path, canonical_query(query), header_lines, names, payload_hash), '\n'
    )
    scope = "$(amzdate[1:8])/$region/$service/aws4_request"
    request_hash = bytes2hex(sha256(canonical_request))
    string_to_sign = join(("AWS4-HMAC-SHA256", amzdate, scope, request_hash), '\n')
    key = signing_key(credentials, amzdate[1:8], region, service)
    signature = bytes2hex(hmac_sha256(key, string_to_sign))
    authorization = "AWS4-HMAC-SHA256 Credential=$(credentials.access_key_id)/$scope, " *
        "SignedHeaders=$names, Signature=$signature"
    return (; canonical_request, string_to_sign, signature, authorization)
end

canonical_header((name, value)) = lowercase(String(name)) => String(strip(String(value)))

header_line((name, value)) = name * ":" * value * "\n"

function signing_key(credentials::Credentials, datestamp, region, service)
    secret = Vector{UInt8}("AWS4" * credentials.secret_access_key)
    parts = (datestamp, region, service, "aws4_request")
    return foldl((key, part) -> hmac_sha256(key, String(part)), parts; init = secret)
end

"""
    uri_encode(s; keep_slash = false)

Return `s` with every byte outside RFC 3986's unreserved set percent-encoded in
uppercase hex. `/` is kept when `keep_slash`, for an object key's path; S3's canonical
URI is the key encoded once, never twice.
"""
function uri_encode(s::AbstractString; keep_slash::Bool = false)
    return join(map(b -> encoded_byte(b, keep_slash), codeunits(s)))
end

function encoded_byte(b::UInt8, keep_slash::Bool)
    (b in UNRESERVED || (keep_slash && b == UInt8('/'))) && return string(Char(b))
    return "%" * uppercase(string(b; base = 16, pad = 2))
end

function canonical_query(query)
    return join(sort!(map(query_parameter, query)), '&')
end

function query_parameter((name, value))
    return uri_encode(String(name)) * "=" * uri_encode(String(value))
end

query_string(query) = isempty(query) ? "" : "?" * canonical_query(query)

"""
    signed_headers(credentials, region, service, host, method, path; query, body, headers,
                   at, payload_hash, content_length)

Return the full header list of one signed request to `service`.

The list is `host`, `x-amz-content-sha256`, `x-amz-date`, `x-amz-security-token` under a
session and the caller's `headers`, then `authorization` over all of them, and an
unsigned `content-length` for a `PUT` or `POST`, which libcurl owns. `path` is the
encoded canonical URI and `at` the request time in seconds since the epoch.
`payload_hash` and `content_length` default to `body`'s; a body streamed from a file
passes both instead of `body`.
"""
function signed_headers(
        credentials::Credentials, region::AbstractString, service::AbstractString,
        host::AbstractString, method::AbstractString, path::AbstractString;
        query = Pair{String, String}[], body = UInt8[], headers = Pair{String, String}[],
        at::Integer = floor(Int64, time()),
        payload_hash::AbstractString = bytes2hex(sha256(body)),
        content_length::Integer = length(body)
    )
    amzdate = amz_date(at)
    base = [
        "host" => String(host), "x-amz-content-sha256" => payload_hash,
        "x-amz-date" => amzdate,
    ]
    signed = vcat(base, session_header(credentials), map(lowercase_name, headers))
    signature = sign_request(
        credentials, region, method, path, query, signed, payload_hash, amzdate; service
    )
    authorization = ["authorization" => signature.authorization]
    return vcat(signed, authorization, length_header(method, content_length))
end

function session_header(c::Credentials)
    c.session_token === nothing && return Pair{String, String}[]
    return ["x-amz-security-token" => c.session_token]
end

lowercase_name((name, value)) = lowercase(String(name)) => String(value)

function length_header(method, content_length)
    method in ("PUT", "POST") || return Pair{String, String}[]
    return ["content-length" => string(content_length)]
end
