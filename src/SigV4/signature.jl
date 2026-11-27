const UNRESERVED = Set{UInt8}(
    codeunits("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~")
)

"""
    sign_request(credentials; method, path, query, headers, payload_hash, at, region,
                 service)

Sign one request, and return its `canonical_request`, `string_to_sign`, `signature` and
`authorization`, the value of its `Authorization` header.

`credentials` has the fields `access_key_id` and `secret_access_key`. `path` is the
URI, encoded once by `uri_encode`. `query` and `headers` are name-value pairs, and every
header given is signed. `payload_hash` is the hex SHA-256 of the body. `at` is the time
of the request in Unix seconds, and its `x-amz-date` header must be `amz_date(at)`.

Examples: test/test_sigv4_signature_examples.jl
"""
function sign_request(
        credentials; method, path, query, headers, payload_hash, at, region, service
    )
    signed = sorted_headers(headers)
    names = join(first.(signed), ';')
    lines = (method, path, canonical_query(query), canonical_headers(signed), names)
    canonical_request = join((lines..., payload_hash), '\n')
    date = amz_date(at)
    scope = "$(first(date, 8))/$region/$service/aws4_request"
    request_hash = bytes2hex(sha256(canonical_request))
    string_to_sign = join(("AWS4-HMAC-SHA256", date, scope, request_hash), '\n')
    key = signing_key(credentials.secret_access_key, scope)
    signature = bytes2hex(hmac_sha256(key, string_to_sign))
    authorization = "AWS4-HMAC-SHA256 Credential=$(credentials.access_key_id)/$scope, " *
        "SignedHeaders=$names, Signature=$signature"
    return (; canonical_request, string_to_sign, signature, authorization)
end

"""
    uri_encode(text; keep_slash = false)

Return `text` with every byte outside the unreserved set percent-encoded, in uppercase
hex.

- `keep_slash`: keep `/`, as in the path of an object key. A query value encodes it.

Examples: test/test_sigv4_signature_examples.jl
"""
function uri_encode(text::AbstractString; keep_slash::Bool = false)
    return join(encoded_byte(byte, keep_slash) for byte in codeunits(text))
end

"""
    amz_date(unix_seconds)

Return `unix_seconds` as the `x-amz-date` header writes it, `yyyymmddTHHMMSSZ` in UTC.

Examples: test/test_sigv4_signature_examples.jl
"""
function amz_date(unix_seconds::Integer)
    days, seconds = fldmod(Int64(unix_seconds), 86400)
    year, month, day = civil_from_days(days)
    hour, rest = fldmod(seconds, 3600)
    minute, second = fldmod(rest, 60)
    date = string(year; pad = 4) * join(string.((month, day); pad = 2))
    return date * "T" * join(string.((hour, minute, second); pad = 2)) * "Z"
end

"""
    canonical_query(query)

Return the query string that a signature covers: each name and value encoded by
`uri_encode`, the pairs sorted, joined by `&`.

Examples: test/test_sigv4_signature_examples.jl
"""
function canonical_query(query)
    pairs = [uri_encode(String(k)) * "=" * uri_encode(String(v)) for (k, v) in query]
    return join(sort!(pairs), '&')
end

function sorted_headers(headers)
    pairs = [lowercase(String(name)) => String(strip(value)) for (name, value) in headers]
    return sort(pairs; by = first)
end

canonical_headers(sorted) = join(k * ":" * v * "\n" for (k, v) in sorted)

# The key is the secret, signed in turn with each part of the scope, in order.
function signing_key(secret_access_key::AbstractString, scope::AbstractString)
    parts = String.(split(scope, '/'))
    return foldl(hmac_sha256, parts; init = Vector{UInt8}("AWS4" * secret_access_key))
end

function encoded_byte(byte::UInt8, keep_slash::Bool)
    (byte in UNRESERVED || (keep_slash && byte == UInt8('/'))) && return string(Char(byte))
    return "%" * uppercase(string(byte; base = 16, pad = 2))
end

# Howard Hinnant's `civil_from_days`, with the names of his paper: the year, month and
# day of a count of days since 1970-01-01, with no calendar library.
function civil_from_days(days::Integer)
    z = days + 719468
    era = fld(z, 146097)
    doe = z - era * 146097
    yoe = (doe - doe ÷ 1460 + doe ÷ 36524 - doe ÷ 146096) ÷ 365
    doy = doe - (365 * yoe + yoe ÷ 4 - yoe ÷ 100)
    mp = (5 * doy + 2) ÷ 153
    day = doy - (153 * mp + 2) ÷ 5 + 1
    month = mp < 10 ? mp + 3 : mp - 9
    year = yoe + era * 400 + (month <= 2)
    return (year, month, day)
end
