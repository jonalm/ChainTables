# The loopback S3: path-style, one connection per request, and every request's signature
# computed again, refused with 403 when it differs. A test scripts an answer with
# `respond(request)`, which returns `(status, headers, body)`, or `nothing` for S3's own.
using Base64: base64encode
using Dates: Dates, @dateformat_str, DateTime, datetime2unix, unix2datetime
using SHA: sha256
using Sockets: Sockets, @ip_str, accept, getsockname, listen
using ChainTables: Credentials, SigV4

const S3TEST_PRECONDITION_FAILED =
    "At least one of the pre-conditions you specified did not hold"

const S3TEST_AUTHORIZATION = Regex(
    "^AWS4-HMAC-SHA256 Credential=([^/]+)/(\\d{8})/([^/]+)/s3/aws4_request, " *
        "SignedHeaders=([^,]+), Signature=([0-9a-f]{64})\$"
)

# What a minter granted, by its signature (ADR-0046).
const PresignedGrant =
    @NamedTuple{key::String, headers::Dict{String, String}, expires::Float64}

struct S3TestRequest
    method::String
    rawpath::String
    path::String
    query::Vector{Pair{String, String}}
    headers::Dict{String, String}
    body::Vector{UInt8}
end

# style: field a test replaces `respond` mid-test, with a function of a new type each time
mutable struct S3TestServer
    const server::Sockets.TCPServer
    const port::Int
    const bucket::String
    const region::String
    const credentials::Credentials
    const objects::Dict{String, Vector{UInt8}}
    const modified::Dict{String, Int64}
    const requests::Vector{S3TestRequest}
    const presigned::Dict{String, PresignedGrant}
    respond::Any
    page_size::Int
end

function with_s3_server(f; keywords...)
    server = S3TestServer(; keywords...)
    try
        return f(server)
    finally
        close(server)
    end
end

# TODO: this form leaves the server open, and only test/gateway.jl and
# test/attachments.jl still call it. Each moves to `with_s3_server` with its ticket:
# https://github.com/jonalm/julia_codestyle/issues/153
# https://github.com/jonalm/julia_codestyle/issues/130
function S3TestServer(; bucket, credentials, region = "eu-north-1", page_size = 1000)
    socket = listen(ip"127.0.0.1", 0)
    port = Int(getsockname(socket)[2])
    server = S3TestServer(
        socket, port, bucket, region, credentials, Dict{String, Vector{UInt8}}(),
        Dict{String, Int64}(), S3TestRequest[], Dict{String, PresignedGrant}(),
        _ -> nothing, page_size,
    )
    errormonitor(@async s3test_serve(server))
    return server
end

Base.close(s::S3TestServer) = close(s.server)

s3test_endpoint(s::S3TestServer) = "http://127.0.0.1:$(s.port)"

function s3test_error(code, message)
    xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<Error><Code>$code</Code>" *
        "<Message>$message</Message></Error>"
    return Vector{UInt8}(xml)
end

# `x-amz-date` as Unix seconds, for a signature computed again.
function s3test_unix_seconds(amz_date::AbstractString)
    return round(Int64, datetime2unix(DateTime(amz_date, dateformat"yyyymmddTHHMMSSZ")))
end

function s3test_http_date(t::Integer)
    return Dates.format(unix2datetime(t), "e, dd u yyyy HH:MM:SS") * " GMT"
end

function s3test_iso_date(t::Integer)
    return Dates.format(unix2datetime(t), "yyyy-mm-ddTHH:MM:SS.sss") * "Z"
end

function s3test_serve(s::S3TestServer)
    while isopen(s.server)
        socket = s3test_try_accept(s.server)
        socket === nothing && return nothing
        errormonitor(@async s3test_handle_connection(s, socket))
    end
    return nothing
end

# `nothing` once the server is closed.
function s3test_try_accept(server)
    try
        return accept(server)
    catch e
        e isa Base.IOError || rethrow()
        isopen(server) && rethrow()
        return nothing
    end
end

function s3test_handle_connection(s::S3TestServer, socket)
    try
        s3test_handle(s, socket)
    finally
        close(socket)
    end
    return nothing
end

function s3test_handle(s::S3TestServer, socket)
    line = readline(socket)
    isempty(line) && return nothing
    method, target, _ = split(line, ' ')
    headers = s3test_read_headers(socket)
    get(headers, "expect", "") == "100-continue" &&
        write(socket, "HTTP/1.1 100 Continue\r\n\r\n")
    n_bytes = parse(Int, get(headers, "content-length", "0"))
    body = n_bytes > 0 ? read(socket, n_bytes) : UInt8[]
    rawpath, rawquery = occursin('?', target) ? split(target, '?'; limit = 2) : (target, "")
    query = map(s3test_query_pair, split(rawquery, '&'; keepempty = false))
    path = s3test_percent_decode(rawpath)
    request = S3TestRequest(method, rawpath, path, query, headers, body)
    push!(s.requests, request)
    # `respond` may be replaced after the accept task started.
    scripted = Base.invokelatest(s.respond, request)
    answer = scripted === nothing ? s3test_default(s, request) : scripted
    status, response_headers, response_body = answer
    s3test_write_response(socket, method, status, response_headers, response_body)
    return nothing
end

function s3test_read_headers(socket)
    headers = Dict{String, String}()
    while (line = readline(socket)) != ""
        name, value = split(line, ":"; limit = 2)
        headers[lowercase(name)] = strip(value)
    end
    return headers
end

function s3test_query_pair(text::AbstractString)
    name, value = occursin('=', text) ? split(text, '='; limit = 2) : (text, "")
    return s3test_percent_decode(name) => s3test_percent_decode(value)
end

function s3test_write_response(socket, method, status, headers, body)
    write(socket, "HTTP/1.1 $status $(status == 200 ? "OK" : "Error")\r\n")
    foreach(((name, value),) -> write(socket, "$name: $value\r\n"), headers)
    write(socket, "content-length: $(length(body))\r\nconnection: close\r\n\r\n")
    method == "HEAD" || write(socket, body)
    flush(socket)
    return nothing
end

function s3test_percent_decode(text::AbstractString)
    out = UInt8[]
    bytes = codeunits(text)
    i = 1
    while i <= length(bytes)
        if bytes[i] == UInt8('%') && i + 2 <= length(bytes)
            push!(out, parse(UInt8, String(bytes[(i + 1):(i + 2)]); base = 16))
            i += 3
        else
            push!(out, bytes[i])
            i += 1
        end
    end
    return String(out)
end

function s3test_xml_escape(text)
    return replace(text, "&" => "&amp;", "<" => "&lt;", ">" => "&gt;", "\"" => "&quot;")
end

function s3test_default(s::S3TestServer, request)
    any(pair -> first(pair) == "X-Amz-Signature", request.query) &&
        return s3test_presigned(s, request)
    refused = s3test_check_signature(s, request)
    refused === nothing || return refused
    bucket_path = "/" * s.bucket
    startswith(request.path, bucket_path) ||
        return (404, [], s3test_error("NoSuchBucket", request.path))
    key = String(chopprefix(chopprefix(request.path, bucket_path), "/"))
    request.method == "PUT" && return s3test_put(s, request, key)
    request.method == "HEAD" && return s3test_head(s, key)
    request.method == "GET" && isempty(key) && return s3test_list(s, request)
    request.method == "GET" && return s3test_get(s, key)
    return (405, [], s3test_error("MethodNotAllowed", request.method))
end

function s3test_put(s::S3TestServer, request, key)
    _is_conditional = get(request.headers, "if-none-match", "") == "*"
    (_is_conditional && haskey(s.objects, key)) &&
        return (412, [], s3test_error("PreconditionFailed", S3TEST_PRECONDITION_FAILED))
    s3test_store!(s, key, request.body)
    etag = "\"" * first(bytes2hex(sha256(request.body)), 32) * "\""
    return (200, ["etag" => etag], UInt8[])
end

function s3test_head(s::S3TestServer, key)
    haskey(s.objects, key) || return (404, [], UInt8[])
    return (200, ["last-modified" => s3test_http_date(s.modified[key])], s.objects[key])
end

function s3test_get(s::S3TestServer, key)
    haskey(s.objects, key) ||
        return (404, [], s3test_error("NoSuchKey", "The specified key does not exist."))
    return (200, ["last-modified" => s3test_http_date(s.modified[key])], s.objects[key])
end

function s3test_store!(s::S3TestServer, key, body)
    s.objects[key] = copy(body)
    s.modified[key] = floor(Int64, time())
    return nothing
end

# The signature the request should carry, computed from what was received.
function s3test_check_signature(s::S3TestServer, request)
    authorization = get(request.headers, "authorization", "")
    m = match(S3TEST_AUTHORIZATION, authorization)
    m === nothing &&
        return (403, [], s3test_error("AccessDenied", "malformed Authorization header"))
    id, datestamp, region, signed, signature = m.captures
    id == s.credentials.access_key_id ||
        return (403, [], s3test_error("InvalidAccessKeyId", "unknown access key $id"))
    region == s.region || return (
        400, [],
        s3test_error(
            "AuthorizationHeaderMalformed",
            "the region '$region' is wrong; expecting '$(s.region)'"
        ),
    )
    names = split(signed, ';')
    refused = s3test_check_signed_headers(s, request, names, datestamp)
    refused === nothing || return refused
    expected = s3test_expected_signature(s, request, names, region)
    expected == signature && return nothing
    detail = "expected $expected, got $signature"
    return (403, [], s3test_error("SignatureDoesNotMatch", detail))
end

function s3test_check_signed_headers(s::S3TestServer, request, names, datestamp)
    headers = request.headers
    unsent = findfirst(name -> !haskey(headers, name), names)
    unsent === nothing ||
        return (403, [], s3test_error("AccessDenied", "a signed header is not sent"))
    get(headers, "x-amz-content-sha256", "") == bytes2hex(sha256(request.body)) ||
        return (400, [], s3test_error("XAmzContentSHA256Mismatch", "payload hash"))
    startswith(get(headers, "x-amz-date", ""), datestamp) ||
        return (403, [], s3test_error("AccessDenied", "x-amz-date outside the scope"))
    token = s.credentials.session_token
    (token === nothing || get(headers, "x-amz-security-token", "") == token) ||
        return (403, [], s3test_error("InvalidToken", "session token missing or wrong"))
    return nothing
end

function s3test_expected_signature(s::S3TestServer, request, names, region)
    headers = [name => request.headers[name] for name in names]
    at = s3test_unix_seconds(request.headers["x-amz-date"])
    payload_hash = request.headers["x-amz-content-sha256"]
    signed = SigV4.sign_request(
        s.credentials; request.method, path = request.rawpath, request.query, headers,
        payload_hash, at, region, service = "s3",
    )
    return signed.signature
end

# A presigned PUT (ADR-0046), as S3 answers one: the signature must be one a minter
# granted, not expired, for this key; every signed header must be sent with its value,
# and no unsigned `x-amz-*` header; the body must hash to the signed checksum; and
# `If-None-Match: *` refuses a key that is there.
function s3test_presigned(s::S3TestServer, request)
    grant = get(s.presigned, Dict(request.query)["X-Amz-Signature"], nothing)
    grant === nothing &&
        return (403, [], s3test_error("SignatureDoesNotMatch", "no such signature"))
    time() > grant.expires &&
        return (403, [], s3test_error("AccessDenied", "Request has expired"))
    (request.method == "PUT" && request.path == "/$(s.bucket)/$(grant.key)") ||
        return (403, [], s3test_error("SignatureDoesNotMatch", "not the signed key"))
    refused = s3test_check_presigned_headers(grant, request)
    refused === nothing || return refused
    haskey(s.objects, grant.key) &&
        return (412, [], s3test_error("PreconditionFailed", S3TEST_PRECONDITION_FAILED))
    s3test_store!(s, grant.key, request.body)
    return (200, [], UInt8[])
end

function s3test_check_presigned_headers(grant, request)
    sent = request.headers
    all(((name, value),) -> get(sent, name, nothing) == value, grant.headers) ||
        return (403, [], s3test_error("SignatureDoesNotMatch", "a signed header differs"))
    any(name -> startswith(name, "x-amz-") && !haskey(grant.headers, name), keys(sent)) &&
        return (403, [], s3test_error("AccessDenied", S3TEST_UNSIGNED_HEADERS))
    base64encode(sha256(request.body)) == grant.headers["x-amz-checksum-sha256"] ||
        return (400, [], s3test_error("BadDigest", S3TEST_BAD_DIGEST))
    return nothing
end

const S3TEST_UNSIGNED_HEADERS =
    "There were headers present in the request which were not signed"

const S3TEST_BAD_DIGEST =
    "The SHA256 you specified did not match the calculated checksum."

function s3test_list(s::S3TestServer, request)
    query = Dict(request.query)
    get(query, "list-type", "") == "2" ||
        return (400, [], s3test_error("InvalidRequest", "list-type=2 only"))
    prefix = get(query, "prefix", "")
    after = get(query, "start-after", "")
    # S3 lists in byte order, and a String compares by bytes.
    _is_listed = key -> startswith(key, prefix) && key > after
    listed = sort!(filter(_is_listed, collect(keys(s.objects))))
    from = parse(Int, get(query, "continuation-token", "1"))
    page = listed[from:min(end, from + s.page_size - 1)]
    next = from + s.page_size <= length(listed) ? from + s.page_size : nothing
    xml = s3test_listing_xml(s, prefix, page, next)
    return (200, ["content-type" => "application/xml"], Vector{UInt8}(xml))
end

function s3test_listing_xml(s::S3TestServer, prefix, page, next)
    entries = join(s3test_contents_xml(s, key) for key in page)
    token = next === nothing ? "" : "<NextContinuationToken>$next</NextContinuationToken>"
    return "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<ListBucketResult>" *
        "<Name>$(s.bucket)</Name><Prefix>$(s3test_xml_escape(prefix))</Prefix>" *
        "<KeyCount>$(length(page))</KeyCount>" *
        "<IsTruncated>$(next !== nothing)</IsTruncated>$token$entries</ListBucketResult>"
end

function s3test_contents_xml(s::S3TestServer, key)
    return "<Contents><Key>$(s3test_xml_escape(key))</Key>" *
        "<LastModified>$(s3test_iso_date(s.modified[key]))</LastModified>" *
        "<ETag>\"x\"</ETag><Size>$(length(s.objects[key]))</Size>" *
        "<StorageClass>STANDARD</StorageClass></Contents>"
end
