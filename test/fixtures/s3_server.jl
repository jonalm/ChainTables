# Shared by test/s3.jl and test/gateway.jl (offline suite only): the loopback S3. Included
# once, by test/runtests.jl, ahead of both.
using Sockets
using SHA: sha256
import ChainTables
using ChainTables: Credentials
const S3T = ChainTables

# ---------------------------------------------------------------------------
# A minimal S3 over HTTP/1.1 on a loopback port: path-style, one connection per
# request, every request's signature recomputed and refused with 403 when it differs.
# `respond(req)` returns `(status, headers, body)` to script a failure, or `nothing`.
# ---------------------------------------------------------------------------
mutable struct S3TestServer
    const server::Sockets.TCPServer
    const port::Int
    const bucket::String
    const region::String
    const credentials::Credentials
    const objects::Dict{String,Vector{UInt8}}
    const modified::Dict{String,Int64}
    const requests::Vector{Any}
    respond::Any
    page_size::Int
end

function S3TestServer(; bucket, credentials, region = "eu-north-1", page_size = 1000)
    server = listen(ip"127.0.0.1", 0)
    port = Int(getsockname(server)[2])
    s = S3TestServer(server, port, bucket, region, credentials, Dict{String,Vector{UInt8}}(), Dict{String,Int64}(), Any[],
                     _ -> nothing, page_size)
    @async try
        while isopen(server)
            sock = accept(server)
            @async try
                s3test_handle(s, sock)
            catch e
                @error "S3TestServer" exception = (e, catch_backtrace())
            finally
                close(sock)
            end
        end
    catch e
        isopen(server) && rethrow()
    end
    return s
end
Base.close(s::S3TestServer) = close(s.server)
s3test_endpoint(s::S3TestServer) = "http://127.0.0.1:$(s.port)"

function s3test_percent_decode(s::AbstractString)
    out = UInt8[]
    bytes = codeunits(s)
    i = 1
    while i <= length(bytes)
        if bytes[i] == UInt8('%') && i + 2 <= length(bytes)
            push!(out, parse(UInt8, String(bytes[i+1:i+2]); base = 16)); i += 3
        else
            push!(out, bytes[i]); i += 1
        end
    end
    return String(out)
end

s3test_xml_escape(s) = replace(s, "&" => "&amp;", "<" => "&lt;", ">" => "&gt;", "\"" => "&quot;")

const S3TEST_WEEKDAYS = ("Thu", "Fri", "Sat", "Sun", "Mon", "Tue", "Wed")      # 1970-01-01 was a Thursday
const S3TEST_MONTHS = ("Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec")
function s3test_http_date(t::Integer)
    days, secs = fldmod(Int64(t), 86400)
    y, m, d = S3T.civil_from_days(days)
    h, r = fldmod(secs, 3600); mi, s = fldmod(r, 60)
    return "$(S3TEST_WEEKDAYS[mod(days, 7) + 1]), $(string(d; pad = 2)) $(S3TEST_MONTHS[m]) $y " *
           "$(string(h; pad = 2)):$(string(mi; pad = 2)):$(string(s; pad = 2)) GMT"
end
function s3test_iso_date(t::Integer)
    days, secs = fldmod(Int64(t), 86400)
    y, m, d = S3T.civil_from_days(days)
    h, r = fldmod(secs, 3600); mi, s = fldmod(r, 60)
    return "$y-$(string(m; pad = 2))-$(string(d; pad = 2))T$(string(h; pad = 2)):$(string(mi; pad = 2)):$(string(s; pad = 2)).000Z"
end

s3test_error(code, message) = Vector{UInt8}("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<Error><Code>$code</Code>" *
                                            "<Message>$message</Message></Error>")

function s3test_handle(s::S3TestServer, sock)
    line = readline(sock)
    isempty(line) && return nothing
    method, target, _ = split(line, ' ')
    headers = Dict{String,String}()
    while (h = readline(sock)) != ""
        k, v = split(h, ":"; limit = 2)
        headers[lowercase(k)] = strip(v)
    end
    get(headers, "expect", "") == "100-continue" && write(sock, "HTTP/1.1 100 Continue\r\n\r\n")
    len = parse(Int, get(headers, "content-length", "0"))
    body = len > 0 ? read(sock, len) : UInt8[]
    rawpath, rawquery = occursin('?', target) ? split(target, '?'; limit = 2) : (target, "")
    query = Pair{String,String}[s3test_percent_decode(first(kv)) => s3test_percent_decode(get(kv, 2, ""))
                                 for kv in (split(p, '='; limit = 2) for p in split(rawquery, '&'; keepempty = false))]
    req = (; method = String(method), rawpath = String(rawpath), path = s3test_percent_decode(rawpath), query, headers, body)
    push!(s.requests, req)
    scripted = Base.invokelatest(s.respond, req)          # `respond` is assigned after the accept task started
    status, rheaders, rbody = scripted === nothing ? s3test_default(s, req) : scripted
    write(sock, "HTTP/1.1 $status $(status == 200 ? "OK" : "Error")\r\n")
    for (k, v) in rheaders
        write(sock, "$k: $v\r\n")
    end
    write(sock, "content-length: $(length(rbody))\r\nconnection: close\r\n\r\n")
    method == "HEAD" || write(sock, rbody)
    flush(sock)
    return nothing
end

# The signature the request should carry, recomputed from what was received.
function s3test_check_signature(s::S3TestServer, req)
    auth = get(req.headers, "authorization", "")
    m = match(r"^AWS4-HMAC-SHA256 Credential=([^/]+)/(\d{8})/([^/]+)/s3/aws4_request, SignedHeaders=([^,]+), Signature=([0-9a-f]{64})$", auth)
    m === nothing && return (403, [], s3test_error("AccessDenied", "malformed Authorization header $(repr(auth))"))
    id, datestamp, region, signed, signature = m.captures
    id == s.credentials.access_key_id || return (403, [], s3test_error("InvalidAccessKeyId", "unknown access key $id"))
    region == s.region || return (400, [], s3test_error("AuthorizationHeaderMalformed", "the region '$region' is wrong; expecting '$(s.region)'"))
    for name in split(signed, ';')
        haskey(req.headers, name) || return (403, [], s3test_error("AccessDenied", "signed header $name not sent"))
    end
    headers = [name => req.headers[name] for name in split(signed, ';')]
    payload_hash = get(req.headers, "x-amz-content-sha256", "")
    payload_hash == bytes2hex(sha256(req.body)) || return (400, [], s3test_error("XAmzContentSHA256Mismatch", "payload hash"))
    amzdate = get(req.headers, "x-amz-date", "")
    startswith(amzdate, datestamp) || return (403, [], s3test_error("AccessDenied", "x-amz-date $amzdate outside scope $datestamp"))
    if s.credentials.session_token !== nothing
        get(req.headers, "x-amz-security-token", "") == s.credentials.session_token ||
            return (403, [], s3test_error("InvalidToken", "session token missing or wrong"))
    end
    expected = S3T.sign_request(s.credentials, region, req.method, req.rawpath, req.query, headers, payload_hash, amzdate)
    expected.signature == signature ||
        return (403, [], s3test_error("SignatureDoesNotMatch", "expected $(expected.signature), got $signature"))
    return nothing
end

function s3test_default(s::S3TestServer, req)
    refused = s3test_check_signature(s, req)
    refused === nothing || return refused
    startswith(req.path, "/" * s.bucket) || return (404, [], s3test_error("NoSuchBucket", req.path))
    key = req.path[length(s.bucket)+2:end]
    startswith(key, "/") && (key = key[2:end])
    if req.method == "PUT"
        if get(req.headers, "if-none-match", "") == "*" && haskey(s.objects, key)
            return (412, [], s3test_error("PreconditionFailed", "At least one of the pre-conditions you specified did not hold"))
        end
        s.objects[key] = copy(req.body)
        s.modified[key] = floor(Int64, time())
        return (200, ["etag" => "\"" * bytes2hex(sha256(req.body))[1:32] * "\""], UInt8[])
    elseif req.method == "HEAD"
        haskey(s.objects, key) || return (404, [], UInt8[])
        return (200, ["last-modified" => s3test_http_date(s.modified[key])], s.objects[key])
    elseif req.method == "GET" && isempty(key)
        return s3test_list(s, req)
    elseif req.method == "GET"
        haskey(s.objects, key) || return (404, [], s3test_error("NoSuchKey", "The specified key does not exist."))
        return (200, ["last-modified" => s3test_http_date(s.modified[key])], s.objects[key])
    end
    return (405, [], s3test_error("MethodNotAllowed", req.method))
end

function s3test_list(s::S3TestServer, req)
    q = Dict(req.query)
    get(q, "list-type", "") == "2" || return (400, [], s3test_error("InvalidRequest", "list-type=2 only"))
    prefix = get(q, "prefix", "")
    after = get(q, "start-after", nothing)
    token = get(q, "continuation-token", nothing)
    keys = sort!([k for k in Base.keys(s.objects) if S3T.startswith_bytes(k, prefix)])   # S3 lists in byte order
    after === nothing || filter!(k -> cmp(k, after) > 0, keys)
    from = token === nothing ? 1 : parse(Int, token)
    page = keys[from:min(end, from + s.page_size - 1)]
    truncated = from + s.page_size <= length(keys)
    io = IOBuffer()
    write(io, "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<ListBucketResult><Name>$(s.bucket)</Name>",
          "<Prefix>$(s3test_xml_escape(prefix))</Prefix><KeyCount>$(length(page))</KeyCount>",
          "<IsTruncated>$(truncated)</IsTruncated>")
    truncated && write(io, "<NextContinuationToken>$(from + s.page_size)</NextContinuationToken>")
    for k in page
        write(io, "<Contents><Key>$(s3test_xml_escape(k))</Key><LastModified>$(s3test_iso_date(s.modified[k]))</LastModified>",
              "<ETag>\"x\"</ETag><Size>$(length(s.objects[k]))</Size><StorageClass>STANDARD</StorageClass></Contents>")
    end
    write(io, "</ListBucketResult>")
    return (200, ["content-type" => "application/xml"], take!(io))
end
