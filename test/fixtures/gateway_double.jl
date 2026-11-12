# The loopback gateway and STS for tests of a gateway bucket: `LoopbackServer` hands each
# request to a handler and records it; `GatewayDouble` answers the slot route and the mint
# route as the deployed gateway does, filling an `S3TestServer` (fixtures/s3_server.jl,
# included first); `gwtest_sts` answers `GetCallerIdentity`.
using Sockets
using SHA: sha256
using ChainTables: ChainTables, Credentials

const GWTEST_CREDS = Credentials("AKIATEST", "topsecret"; session_token = "session-token")
const GWTEST_ARN =
    "arn:aws:sts::123456789012:assumed-role/" *
    "AWSReservedSSO_chaintables-writer_0123456789abcdef/alice@example.com"
const GWTEST_AUTHORIZATION = Regex(
    "^AWS4-HMAC-SHA256 Credential=([^/]+)/(\\d{8})/([^/]+)/([^/]+)/aws4_request, " *
        "SignedHeaders=([^,]+), Signature=([0-9a-f]{64})\$"
)
const GWTEST_FORBIDDEN = (403, [], Vector{UInt8}("{\"Message\":\"Forbidden\"}"))
const GWTEST_SLOT_KEY = r"^(?:[^/](?:.*[^/])?/)?[0-9]{12}$"
const GWTEST_ATTACHMENT_KEY = r"^(?:(.+)/)?_attachments/[0-9a-f]{64}$"
const GWTEST_EXPIRES = "2026-11-06T12:00:00Z"

"""
    LoopbackServer(handle)

An HTTP/1.1 server on a loopback port that hands every request to `handle(req)`, which
returns `(status, headers, body)`, and records it in `requests`. One connection per
request.
"""
mutable struct LoopbackServer
    const server::Sockets.TCPServer
    const port::Int
    const requests::Vector{Any}
    handle::Any
end

function LoopbackServer(handle)
    server = listen(ip"127.0.0.1", 0)
    s = LoopbackServer(server, Int(getsockname(server)[2]), Any[], handle)
    @async try
        while isopen(server)
            sock = accept(server)
            @async try
                loopback_serve(s, sock)
            catch e
                @error "LoopbackServer" exception = (e, catch_backtrace())
            finally
                close(sock)
            end
        end
    catch e
        isopen(server) && rethrow()
    end
    return s
end
Base.close(s::LoopbackServer) = close(s.server)
loopback_url(s::LoopbackServer) = "http://127.0.0.1:$(s.port)"

function loopback_serve(s::LoopbackServer, sock)
    line = readline(sock)
    isempty(line) && return nothing
    method, target, _ = split(line, ' ')
    headers = Dict{String, String}()
    while (h = readline(sock)) != ""
        k, v = split(h, ":"; limit = 2)
        headers[lowercase(k)] = strip(v)
    end
    get(headers, "expect", "") == "100-continue" &&
        write(sock, "HTTP/1.1 100 Continue\r\n\r\n")
    len = parse(Int, get(headers, "content-length", "0"))
    body = len > 0 ? read(sock, len) : UInt8[]
    rawpath, rawquery = occursin('?', target) ? split(target, '?'; limit = 2) : (target, "")
    query = map(loopback_query_pair, split(rawquery, '&'; keepempty = false))
    req = (;
        method = String(method), rawpath = String(rawpath), rawquery = String(rawquery),
        query, headers, body,
    )
    push!(s.requests, req)
    status, rheaders, rbody = Base.invokelatest(s.handle, req)
    write(sock, "HTTP/1.1 $status $(status == 200 ? "OK" : "Error")\r\n")
    for (k, v) in rheaders
        write(sock, "$k: $v\r\n")
    end
    write(sock, "content-length: $(length(rbody))\r\nconnection: close\r\n\r\n", rbody)
    flush(sock)
    return nothing
end

function loopback_query_pair(part)
    kv = split(part, '='; limit = 2)
    return s3test_percent_decode(first(kv)) => s3test_percent_decode(get(kv, 2, ""))
end

# The signature a request should carry for `service`, recomputed from what was received;
# a refusal is AWS's own 403, with no gateway code in the body, which the client reads as
# "forbidden".
function gwtest_check_signature(credentials::Credentials, region, service, req)
    m = match(GWTEST_AUTHORIZATION, get(req.headers, "authorization", ""))
    m === nothing && return GWTEST_FORBIDDEN
    id, datestamp, sregion, sservice, signed, signature = m.captures
    (id == credentials.access_key_id && sregion == region && sservice == service) ||
        return GWTEST_FORBIDDEN
    names = split(signed, ';')
    all(name -> haskey(req.headers, name), names) || return GWTEST_FORBIDDEN
    headers = [name => req.headers[name] for name in names]
    payload_hash = get(req.headers, "x-amz-content-sha256", "")
    payload_hash == bytes2hex(sha256(req.body)) || return GWTEST_FORBIDDEN
    amzdate = get(req.headers, "x-amz-date", "")
    token = credentials.session_token
    token === nothing || get(req.headers, "x-amz-security-token", "") == token ||
        return GWTEST_FORBIDDEN
    expected = ChainTables.sign_request(
        credentials, sregion, req.method, req.rawpath, req.query, headers, payload_hash,
        amzdate; service
    )
    expected.signature == signature || return GWTEST_FORBIDDEN
    return nothing
end

"""
    GatewayDouble(s3, credentials, region, caller, policy, respond)

The gateway as a `LoopbackServer` handler: the slot route's checks in order, filling slots
straight into the `S3TestServer` `s3`, and the mint route. `caller` is the name the double
sees in the request context; `policy` is prefix => names; `respond(req)` returns
`(status, headers, body)` to script a reply, or `nothing`.
"""
mutable struct GatewayDouble
    const s3::S3TestServer
    const credentials::Credentials
    const region::String
    caller::String
    policy::Vector{Pair{String, Vector{String}}}
    respond::Any
end

function gwtest_json(status, code, message)
    escaped = replace(message, "\\" => "\\\\", "\"" => "\\\"", "\n" => "\\n")
    body = "{\"code\": \"$code\", \"message\": \"$escaped\"}"
    return (status, ["content-type" => "application/json"], Vector{UInt8}(body))
end

function gwtest_allowed(g::GatewayDouble, key)
    return any(
        ((prefix, names),) -> g.caller in names && gwtest_under(key, prefix), g.policy
    )
end

function gwtest_under(key, prefix)
    return prefix == "*" || ChainTables.startswith_bytes(key, prefix * "/") || key == prefix
end

gwtest_not_allowed(g, key) =
    gwtest_json(403, "not_allowed", "$(g.caller) may not write under $(dirname(key))")

function (g::GatewayDouble)(req)
    scripted = g.respond(req)
    scripted === nothing || return scripted
    refused = gwtest_check_signature(g.credentials, g.region, "lambda", req)
    refused === nothing || return refused
    (req.method, req.rawpath) == ("POST", "/mint") && return gwtest_mint(g, req)
    req.method == "PUT" || return gwtest_json(400, "bad_request", "method $(req.method)")
    req.rawpath == "/" ||
        return gwtest_json(400, "bad_request", "path $(req.rawpath) is not /")
    i = findfirst(kv -> kv[1] == "key", req.query)
    i === nothing && return gwtest_json(400, "bad_request", "no key")
    key = req.query[i][2]
    gwtest_allowed(g, key) || return gwtest_not_allowed(g, key)
    occursin(GWTEST_SLOT_KEY, key) ||
        return gwtest_json(400, "not_a_slot", "$key is not a slot")
    return gwtest_fill_slot(g, key, req.body)
end

function gwtest_fill_slot(g::GatewayDouble, key, body)
    decoded = try
        ChainTables.CBOR.decode(body)
    catch e
        e
    end
    decoded isa Dict ||
        return gwtest_json(400, "not_cbor_map", "the body is not a CBOR map")
    user = get(get(decoded, "client", Dict()), "user", nothing)
    (user isa String && !isempty(user)) ||
        return gwtest_json(400, "no_author", "client.user is absent")
    mismatch = "the record names '$user' as client.user but the caller is " *
        "'$(g.caller)': a client bug, or the credentials changed between the identity " *
        "call and the commit; report it"
    user == g.caller || return gwtest_json(403, "author_mismatch", mismatch)
    length(body) <= 4 * 1024 * 1024 ||
        return gwtest_json(413, "too_large", "$(length(body)) bytes")
    haskey(g.s3.objects, key) && return gwtest_json(412, "slot_taken", "$key exists")
    g.s3.objects[key] = copy(body)
    g.s3.modified[key] = floor(Int64, time())
    return gwtest_json(200, "created", key)
end

# The mint route (ADR-0046), as handler.py answers it: the policy on the attachment's
# prefix, `present` when the S3 double holds the key, else a URL the S3 double honours
# (`s3.presigned`) and the headers it signs, in json.dumps's layout.
function gwtest_mint(g::GatewayDouble, req)
    q = Dict(req.query)
    (haskey(q, "key") && haskey(q, "size") && isempty(req.body)) ||
        return gwtest_json(400, "bad_request", "key, size, no body")
    key = q["key"]
    m = match(GWTEST_ATTACHMENT_KEY, key)
    gwtest_allowed(g, m === nothing ? dirname(key) : something(m.captures[1], "")) ||
        return gwtest_not_allowed(g, key)
    m === nothing &&
        return gwtest_json(400, "not_a_slot", "$key is neither a slot nor an attachment")
    occursin(r"^[0-9]+$", q["size"]) || return gwtest_json(400, "bad_request", "size")
    size = parse(Int, q["size"])
    size <= 5 * 1024^3 || return gwtest_json(413, "too_large", "over 5 GiB")
    present = "attachment $key is already stored; upload nothing"
    haskey(g.s3.objects, key) && return gwtest_json(200, "present", present)
    return gwtest_minted(g.s3, key, size)
end

"""
    gwtest_minted(s3, key, size; seconds, lifetime, capped, url, edit, query)

The mint route's `minted` reply for `key`, granted at the S3 double. `seconds` is the
URL's life at the S3 double, `lifetime` the one the reply gives (`nothing`: no `seconds`
or `capped` in it, as from an older gateway). `edit` changes the minted headers; `query =
false` mints a URL with no query.
"""
function gwtest_minted(
        s3::S3TestServer, key, size; seconds = 900, lifetime = seconds, capped = false,
        url = nothing, edit = identity, query = true
    )
    # Unique per grant, and with no randomness.
    signature = bytes2hex(sha256("$key $(length(s3.presigned))"))
    headers = edit(
        [
            "content-length" => string(size), "content-type" => "application/octet-stream",
            "if-none-match" => "*",
            "x-amz-checksum-sha256" => ChainTables.checksum_sha256(key[(end - 63):end]),
            "x-amz-tagging" => "chaintables=attachment",
        ]
    )
    s3.presigned[signature] = (; key, headers = Dict(headers), expires = time() + seconds)
    path = "/$(s3.bucket)/" * ChainTables.uri_encode(key; keep_slash = true)
    signed = "?X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Expires=$seconds" *
        "&X-Amz-SignedHeaders=host&X-Amz-Signature=$signature"
    url = something(url, s3test_endpoint(s3) * path) * (query ? signed : "")
    object = join(("\"$k\": \"$v\"" for (k, v) in headers), ", ")
    life = lifetime === nothing ? "" : "\"seconds\": $lifetime, \"capped\": $capped, "
    body = "{\"code\": \"minted\", \"message\": \"PUT the attachment's $size bytes\", " *
        "\"url\": \"$url\", \"expires\": \"$GWTEST_EXPIRES\", $life\"headers\": {$object}}"
    return (200, ["content-type" => "application/json"], Vector{UInt8}(body))
end

"""
    gwtest_sts(credentials, region, arn)

A `LoopbackServer` handler that answers STS `GetCallerIdentity` for `arn`, signed for
service sts.
"""
function gwtest_sts(credentials::Credentials, region, arn)
    return req -> gwtest_caller_identity(credentials, region, arn, req)
end

function gwtest_caller_identity(credentials, region, arn, req)
    refused = gwtest_check_signature(credentials, region, "sts", req)
    refused === nothing || return refused
    _is_identity_call = req.method == "POST" && req.rawpath == "/" &&
        occursin("Action=GetCallerIdentity", String(copy(req.body)))
    invalid = "<ErrorResponse><Error><Code>InvalidAction</Code></Error></ErrorResponse>"
    _is_identity_call || return (400, [], Vector{UInt8}(invalid))
    name = last(split(arn, '/'))
    namespace = "https://sts.amazonaws.com/doc/2011-06-15/"
    body = "<GetCallerIdentityResponse xmlns=\"$namespace\">" *
        "<GetCallerIdentityResult><Arn>$arn</Arn><UserId>AROAEXAMPLE:$name</UserId>" *
        "<Account>123456789012</Account></GetCallerIdentityResult>" *
        "<ResponseMetadata><RequestId>x</RequestId></ResponseMetadata>" *
        "</GetCallerIdentityResponse>"
    return (200, ["content-type" => "text/xml"], Vector{UInt8}(body))
end
