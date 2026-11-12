# A minimal S3 over HTTP/1.1 on a loopback port, so no test reaches AWS: path-style, one
# connection per request, every signature recomputed and refused with 403 when it
# differs. `respond(req)` returns `(status, headers, body)` to script a reply, or
# `nothing` for the default. Tests use it through `with_s3_server`.

using ChainTables: ChainTables, Credentials
using SHA: sha256
using Sockets: Sockets, @ip_str, accept, getsockname, listen

const S3TEST_WEEKDAYS = ("Thu", "Fri", "Sat", "Sun", "Mon", "Tue", "Wed") # 1970-01-01: Thu
const S3TEST_MONTHS =
    ("Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec")

const S3TEST_AUTHORIZATION = Regex(
    "^AWS4-HMAC-SHA256 Credential=([^/]+)/(\\d{8})/([^/]+)/s3/aws4_request, " *
        "SignedHeaders=([^,]+), Signature=([0-9a-f]{64})\$"
)

const S3TEST_PRECONDITION =
    "At least one of the pre-conditions you specified did not hold"

"""
    S3TestServer

The loopback S3's state: its objects, every request it received, the presigned PUTs a
minter granted, and the scripted `respond` and listing `page_size` a test may set.
"""
mutable struct S3TestServer
    const server::Sockets.TCPServer
    const port::Int
    const bucket::String
    const region::String
    const credentials::Credentials
    const objects::Dict{String, Vector{UInt8}}
    const modified::Dict{String, Int64}
    const requests::Vector{Any}
    # X-Amz-Signature => (; key, headers, expires): what a minter granted
    const presigned::Dict{String, Any}
    respond::Any
    page_size::Int
end

function S3TestServer(; bucket, credentials, region = "eu-north-1", page_size = 1000)
    server = listen(ip"127.0.0.1", 0)
    port = Int(getsockname(server)[2])
    s = S3TestServer(
        server, port, bucket, region, credentials, Dict{String, Vector{UInt8}}(),
        Dict{String, Int64}(), Any[], Dict{String, Any}(), Returns(nothing), page_size
    )
    errormonitor(@async serve_connections(server, sock -> s3test_handle(s, sock)))
    return s
end

Base.close(s::S3TestServer) = close(s.server)

"""
    with_s3_server(f; bucket, credentials, region = "eu-north-1", page_size = 1000)

Return `f(server)` for a fresh `S3TestServer`, closed afterwards.
"""
function with_s3_server(f; kw...)
    server = S3TestServer(; kw...)
    return try
        f(server)
    finally
        close(server)
    end
end

s3test_endpoint(s::S3TestServer) = "http://127.0.0.1:$(s.port)"

# Accept until the server closes; each connection is served in its own task, whose
# failure `errormonitor` prints rather than hides.
function serve_connections(server, handle)
    while isopen(server)
        sock = accept_or_nothing(server)
        sock === nothing && return nothing
        errormonitor(@async serve_connection(handle, sock))
    end
    return nothing
end

function accept_or_nothing(server)
    return try
        accept(server)
    catch e
        e isa Base.IOError || rethrow()
        isopen(server) && rethrow()
        nothing
    end
end

function serve_connection(handle, sock)
    return try
        handle(sock)
    finally
        close(sock)
    end
end

"""
    read_request(sock)

Return one HTTP/1.1 request from `sock` as `(; method, rawpath, path, rawquery, query,
headers, body)`, or `nothing` when the peer sent nothing.
"""
function read_request(sock)
    line = readline(sock)
    isempty(line) && return nothing
    method, target, _ = split(line, ' ')
    headers = read_headers(sock)
    get(headers, "expect", "") == "100-continue" &&
        write(sock, "HTTP/1.1 100 Continue\r\n\r\n")
    body = read(sock, parse(Int, get(headers, "content-length", "0")))
    rawpath, rawquery = occursin('?', target) ? split(target, '?'; limit = 2) : (target, "")
    query = map(query_pair, split(rawquery, '&'; keepempty = false))
    return (;
        method = String(method), rawpath = String(rawpath),
        path = s3test_percent_decode(rawpath), rawquery = String(rawquery), query, headers,
        body,
    )
end

function read_headers(sock)
    headers = Dict{String, String}()
    while (line = readline(sock)) != ""
        name, value = split(line, ":"; limit = 2)
        headers[lowercase(name)] = strip(value)
    end
    return headers
end

function query_pair(parameter)
    name_value = split(parameter, '='; limit = 2)
    return s3test_percent_decode(first(name_value)) =>
        s3test_percent_decode(get(name_value, 2, ""))
end

function write_response(sock, method, (status, headers, body))
    write(sock, "HTTP/1.1 $status $(status == 200 ? "OK" : "Error")\r\n")
    foreach(((name, value),) -> write(sock, "$name: $value\r\n"), headers)
    write(sock, "content-length: $(length(body))\r\nconnection: close\r\n\r\n")
    method == "HEAD" || write(sock, body)
    flush(sock)
    return nothing
end

function s3test_handle(s::S3TestServer, sock)
    req = read_request(sock)
    req === nothing && return nothing
    push!(s.requests, req)
    # `respond` is assigned after the accept task started.
    scripted = Base.invokelatest(s.respond, req)
    reply = scripted === nothing ? s3test_default(s, req) : scripted
    write_response(sock, req.method, reply)
    return nothing
end

function s3test_percent_decode(s::AbstractString)
    out = UInt8[]
    bytes = codeunits(s)
    i = 1
    while i <= length(bytes)
        is_escape = bytes[i] == UInt8('%') && i + 2 <= length(bytes)
        push!(out, is_escape ? hex_byte(bytes, i) : bytes[i])
        i += is_escape ? 3 : 1
    end
    return String(out)
end

hex_byte(bytes, i) = parse(UInt8, String(bytes[(i + 1):(i + 2)]); base = 16)

function s3test_xml_escape(s)
    return replace(s, "&" => "&amp;", "<" => "&lt;", ">" => "&gt;", "\"" => "&quot;")
end

function s3test_clock(t::Integer)
    days, secs = fldmod(Int64(t), 86400)
    y, m, d = ChainTables.civil_from_days(days)
    h, rest = fldmod(secs, 3600)
    mi, s = fldmod(rest, 60)
    return (; days, y, m, d, hms = join(map(x -> string(x; pad = 2), (h, mi, s)), ':'))
end

function s3test_http_date(t::Integer)
    c = s3test_clock(t)
    weekday = S3TEST_WEEKDAYS[mod(c.days, 7) + 1]
    return "$weekday, $(string(c.d; pad = 2)) $(S3TEST_MONTHS[c.m]) $(c.y) $(c.hms) GMT"
end

function s3test_iso_date(t::Integer)
    c = s3test_clock(t)
    return "$(c.y)-$(string(c.m; pad = 2))-$(string(c.d; pad = 2))T$(c.hms).000Z"
end

function s3test_error(code, message)
    return Vector{UInt8}(
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<Error><Code>$code</Code>" *
            "<Message>$message</Message></Error>"
    )
end

function s3test_refusal(status, code, message)
    return (status, Pair{String, String}[], s3test_error(code, message))
end

# The signature the request should carry, recomputed from what was received.
function s3test_check_signature(s::S3TestServer, req)
    m = match(S3TEST_AUTHORIZATION, get(req.headers, "authorization", ""))
    m === nothing && return s3test_refusal(403, "AccessDenied", "malformed Authorization")
    id, datestamp, region, signed, signature = m.captures
    id == s.credentials.access_key_id ||
        return s3test_refusal(403, "InvalidAccessKeyId", "unknown access key $id")
    region == s.region || return s3test_refusal(
        400, "AuthorizationHeaderMalformed",
        "the region '$region' is wrong; expecting '$(s.region)'"
    )
    names = split(signed, ';')
    all(name -> haskey(req.headers, name), names) ||
        return s3test_refusal(403, "AccessDenied", "a signed header was not sent")
    payload_hash = get(req.headers, "x-amz-content-sha256", "")
    payload_hash == bytes2hex(sha256(req.body)) ||
        return s3test_refusal(400, "XAmzContentSHA256Mismatch", "payload hash")
    amzdate = get(req.headers, "x-amz-date", "")
    startswith(amzdate, datestamp) ||
        return s3test_refusal(403, "AccessDenied", "x-amz-date outside scope")
    s3test_token_matches(s, req) ||
        return s3test_refusal(403, "InvalidToken", "session token missing or wrong")
    headers = [name => req.headers[name] for name in names]
    expected = ChainTables.sign_request(
        s.credentials, region, req.method, req.rawpath, req.query, headers, payload_hash,
        amzdate
    )
    expected.signature == signature || return s3test_refusal(
        403, "SignatureDoesNotMatch", "expected $(expected.signature), got $signature"
    )
    return nothing
end

function s3test_token_matches(s::S3TestServer, req)
    token = s.credentials.session_token
    return token === nothing || get(req.headers, "x-amz-security-token", "") == token
end

function s3test_default(s::S3TestServer, req)
    any(kv -> first(kv) == "X-Amz-Signature", req.query) && return s3test_presigned(s, req)
    refused = s3test_check_signature(s, req)
    refused === nothing || return refused
    startswith(req.path, "/" * s.bucket) ||
        return s3test_refusal(404, "NoSuchBucket", req.path)
    key = chopprefix(req.path[(length(s.bucket) + 2):end], "/")
    req.method == "PUT" && return s3test_put(s, req, key)
    req.method == "HEAD" && return s3test_head(s, key)
    req.method == "GET" && isempty(key) && return s3test_list(s, req)
    req.method == "GET" && return s3test_get(s, key)
    return s3test_refusal(405, "MethodNotAllowed", req.method)
end

function s3test_put(s::S3TestServer, req, key)
    (get(req.headers, "if-none-match", "") == "*" && haskey(s.objects, key)) &&
        return s3test_refusal(412, "PreconditionFailed", S3TEST_PRECONDITION)
    s3test_store!(s, key, req.body)
    etag = "\"" * bytes2hex(sha256(req.body))[1:32] * "\""
    return (200, ["etag" => etag], UInt8[])
end

function s3test_store!(s::S3TestServer, key, body)
    s.objects[key] = copy(body)
    s.modified[key] = floor(Int64, time())
    return nothing
end

function s3test_head(s::S3TestServer, key)
    haskey(s.objects, key) || return (404, Pair{String, String}[], UInt8[])
    return (200, ["last-modified" => s3test_http_date(s.modified[key])], s.objects[key])
end

function s3test_get(s::S3TestServer, key)
    haskey(s.objects, key) ||
        return s3test_refusal(404, "NoSuchKey", "The specified key does not exist.")
    return (200, ["last-modified" => s3test_http_date(s.modified[key])], s.objects[key])
end

# A presigned PUT (ADR-0046), as S3 answers one: a signature a minter granted, unexpired,
# for this key; every signed header sent with its value and no unsigned `x-amz-*` one;
# the body hashing to the signed checksum; `If-None-Match: *` refusing a present key.
function s3test_presigned(s::S3TestServer, req)
    grant = get(s.presigned, Dict(req.query)["X-Amz-Signature"], nothing)
    grant === nothing &&
        return s3test_refusal(403, "SignatureDoesNotMatch", "no such signature")
    time() > grant.expires &&
        return s3test_refusal(403, "AccessDenied", "Request has expired")
    (req.method == "PUT" && req.path == "/$(s.bucket)/$(grant.key)") ||
        return s3test_refusal(403, "SignatureDoesNotMatch", "not the signed method and key")
    all(((k, v),) -> get(req.headers, k, nothing) == v, grant.headers) ||
        return s3test_refusal(403, "SignatureDoesNotMatch", "a signed header differs")
    any(k -> startswith(k, "x-amz-") && !haskey(grant.headers, k), keys(req.headers)) &&
        return s3test_refusal(403, "AccessDenied", S3TEST_UNSIGNED)
    checksum = ChainTables.Base64.base64encode(sha256(req.body))
    checksum == grant.headers["x-amz-checksum-sha256"] ||
        return s3test_refusal(400, "BadDigest", S3TEST_BAD_DIGEST)
    haskey(s.objects, grant.key) &&
        return s3test_refusal(412, "PreconditionFailed", S3TEST_PRECONDITION)
    s3test_store!(s, grant.key, req.body)
    return (200, Pair{String, String}[], UInt8[])
end

const S3TEST_UNSIGNED = "There were headers present in the request which were not signed"

const S3TEST_BAD_DIGEST = "The SHA256 you specified did not match the calculated checksum."

function s3test_list(s::S3TestServer, req)
    q = Dict(req.query)
    get(q, "list-type", "") == "2" ||
        return s3test_refusal(400, "InvalidRequest", "list-type=2 only")
    prefix = get(q, "prefix", "")
    after = get(q, "start-after", "")
    # S3 lists in byte order.
    listed = sort!(filter(k -> s3test_listed(k, prefix, after), collect(keys(s.objects))))
    from = parse(Int, get(q, "continuation-token", "1"))
    page = listed[from:min(end, from + s.page_size - 1)]
    truncated = from + s.page_size <= length(listed)
    body = s3test_listing(s, prefix, page, truncated ? from + s.page_size : nothing)
    return (200, ["content-type" => "application/xml"], Vector{UInt8}(body))
end

function s3test_listed(key, prefix, after)
    return ChainTables.startswith_bytes(key, prefix) && cmp(key, after) > 0
end

function s3test_listing(s::S3TestServer, prefix, page, next)
    token = next === nothing ? "" : "<NextContinuationToken>$next</NextContinuationToken>"
    return "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<ListBucketResult>" *
        "<Name>$(s.bucket)</Name><Prefix>$(s3test_xml_escape(prefix))</Prefix>" *
        "<KeyCount>$(length(page))</KeyCount>" *
        "<IsTruncated>$(next !== nothing)</IsTruncated>" *
        token * join(map(k -> s3test_contents(s, k), page)) * "</ListBucketResult>"
end

function s3test_contents(s::S3TestServer, key)
    return "<Contents><Key>$(s3test_xml_escape(key))</Key>" *
        "<LastModified>$(s3test_iso_date(s.modified[key]))</LastModified>" *
        "<ETag>\"x\"</ETag><Size>$(length(s.objects[key]))</Size>" *
        "<StorageClass>STANDARD</StorageClass></Contents>"
end
