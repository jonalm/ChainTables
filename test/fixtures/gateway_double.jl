# A loopback gateway and a loopback STS, for the tests of a gateway bucket. Each request
# is recorded and handed to a handler. The gateway double fills slots straight into a
# loopback S3, whose own role holds PutObject, so it needs fixtures/s3_server.jl.
using Base64: base64encode
using SHA: sha256
using Sockets: Sockets, @ip_str, getsockname, listen
using ChainTables: CBOR, Credentials, GatewayObjectStore, SigV4

const ALICE = "alice@example.com"

const GWTEST_CREDS = Credentials("AKIATEST", "topsecret"; session_token = "session-token")

const GWTEST_ARN = "arn:aws:sts::123456789012:assumed-role/" *
    "AWSReservedSSO_chaintables-writer_0123456789abcdef/" * ALICE

const GWTEST_AUTHORIZATION = Regex(
    "^AWS4-HMAC-SHA256 Credential=([^/]+)/(\\d{8})/([^/]+)/([^/]+)/aws4_request, " *
        "SignedHeaders=([^,]+), Signature=([0-9a-f]{64})\$"
)

const GWTEST_SLOT_KEY = r"^(?:[^/](?:.*[^/])?/)?[0-9]{12}$"

const GWTEST_ATTACHMENT_KEY = r"^(?:(.+)/)?_attachments/[0-9a-f]{64}$"

const GWTEST_RECORD_CAP = 4 * 1024 * 1024

# AWS's own refusal before the gateway runs: no gateway code in the body.
const AWS_FORBIDDEN =
    (403, Pair{String, String}[], Vector{UInt8}("{\"Message\":\"Forbidden\"}"))

struct LoopbackServer{H}
    server::Sockets.TCPServer
    port::Int
    requests::Vector{S3TestRequest}
    handle::H
end

function with_loopback(f, handle)
    socket = listen(ip"127.0.0.1", 0)
    try
        port = Int(getsockname(socket)[2])
        server = LoopbackServer(socket, port, S3TestRequest[], handle)
        errormonitor(@async loopback_serve(server))
        return f(server)
    finally
        close(socket)
    end
end

loopback_url(s::LoopbackServer) = "http://127.0.0.1:$(s.port)"

function loopback_serve(s::LoopbackServer)
    while isopen(s.server)
        socket = s3test_try_accept(s.server)
        socket === nothing && return nothing
        errormonitor(@async loopback_handle_connection(s, socket))
    end
    return nothing
end

function loopback_handle_connection(s::LoopbackServer, socket)
    try
        loopback_handle(s, socket)
    finally
        close(socket)
    end
    return nothing
end

function loopback_handle(s::LoopbackServer, socket)
    request = s3test_read_request(socket)
    request === nothing && return nothing
    push!(s.requests, request)
    # A handler's `respond` may be replaced after the accept task started.
    answer = Base.invokelatest(s.handle, request)
    s3test_write_response(socket, request.method, answer...)
    return nothing
end

# The checks of the gateway in order (issue #54 §5). `caller` is the name the double
# sees in the request context; `policy` is prefix => names.
# style: field a test replaces `respond` mid-test, with a function of a new type each time
mutable struct GatewayDouble
    const s3::S3TestServer
    const credentials::Credentials
    const region::String
    caller::String
    policy::Vector{Pair{String, Vector{String}}}
    respond::Any  # request -> (status, headers, body) to script a reply, or nothing
end

function GatewayDouble(s3::S3TestServer; caller = ALICE, policy = ["p" => [ALICE]])
    return GatewayDouble(s3, s3.credentials, s3.region, caller, policy, _ -> nothing)
end

function (g::GatewayDouble)(request)
    scripted = g.respond(request)
    scripted === nothing || return scripted
    refused = gwtest_check_signature(g.credentials, g.region, "lambda", request)
    refused === nothing || return refused
    (request.method, request.rawpath) == ("POST", "/mint") && return gwtest_mint(g, request)
    request.method == "PUT" ||
        return gwtest_json(400, "bad_request", "method $(request.method)")
    request.rawpath == "/" ||
        return gwtest_json(400, "bad_request", "path $(request.rawpath) is not /")
    return gwtest_put(g, request)
end

function gwtest_put(g::GatewayDouble, request)
    key = gwtest_query_value(request, "key")
    key === nothing && return gwtest_json(400, "bad_request", "no key")
    gwtest_allowed(g, key) || return gwtest_not_allowed(g, key)
    occursin(GWTEST_SLOT_KEY, key) ||
        return gwtest_json(400, "not_a_slot", "$key is not a slot")
    refused = gwtest_check_record(g, request.body)
    refused === nothing || return refused
    n_bytes = length(request.body)
    n_bytes <= GWTEST_RECORD_CAP || return gwtest_json(413, "too_large", "$n_bytes bytes")
    haskey(g.s3.objects, key) && return gwtest_json(412, "slot_taken", "$key exists")
    s3test_store!(g.s3, key, request.body)
    return gwtest_json(200, "created", key)
end

function gwtest_query_value(request, name)
    i = findfirst(pair -> first(pair) == name, request.query)
    return i === nothing ? nothing : last(request.query[i])
end

function gwtest_allowed(g::GatewayDouble, key)
    return any(entry -> gwtest_grants(entry, g.caller, key), g.policy)
end

function gwtest_grants((prefix, names), caller, key)
    caller in names || return false
    return prefix == "*" || startswith(key, prefix * "/") || key == prefix
end

function gwtest_not_allowed(g::GatewayDouble, key)
    message = "$(g.caller) may not write under $(dirname(key))"
    return gwtest_json(403, "not_allowed", message)
end

function gwtest_check_record(g::GatewayDouble, body)
    decoded = gwtest_try_decode(body)
    decoded isa Dict ||
        return gwtest_json(400, "not_cbor_map", "the body is not a CBOR map")
    user = get(get(decoded, "client", Dict()), "user", nothing)
    (user isa String && !isempty(user)) ||
        return gwtest_json(400, "no_author", "client.user is absent")
    user == g.caller && return nothing
    message = "the record names '$user' as client.user but the caller is '$(g.caller)'"
    return gwtest_json(403, "author_mismatch", message)
end

function gwtest_try_decode(body)
    try
        return CBOR.decode(body)
    catch e
        e isa CBOR.DecodeError || rethrow()
        return nothing
    end
end

# The mint route (ADR-0046), as handler.py answers it: the policy on the attachment's
# prefix, `present` when the S3 double holds the key, else a URL that the S3 double
# honours.
function gwtest_mint(g::GatewayDouble, request)
    query = Dict(request.query)
    (haskey(query, "key") && haskey(query, "size") && isempty(request.body)) ||
        return gwtest_json(400, "bad_request", "key, size, no body")
    key = query["key"]
    m = match(GWTEST_ATTACHMENT_KEY, key)
    prefix = m === nothing ? dirname(key) : something(m[1], "")
    gwtest_allowed(g, prefix) || return gwtest_not_allowed(g, key)
    m === nothing &&
        return gwtest_json(400, "not_a_slot", "$key is neither a slot nor an attachment")
    occursin(r"^[0-9]+$", query["size"]) || return gwtest_json(400, "bad_request", "size")
    size = parse(Int, query["size"])
    size <= 5 * 1024^3 || return gwtest_json(413, "too_large", "over 5 GiB")
    haskey(g.s3.objects, key) &&
        return gwtest_json(200, "present", "attachment $key is already stored")
    return gwtest_minted(g.s3, key, size)
end

# A minted reply, in json.dumps's layout. `seconds` is the URL's life at the S3 double,
# `lifetime` the one the reply gives (`nothing`: no `seconds` or `capped`, as from a
# gateway older than 2026-11-10).
function gwtest_minted(
        s3::S3TestServer, key, size; seconds = 900, lifetime = seconds, capped = false,
        url = nothing, edit = identity, query = true,
    )
    signature = bytes2hex(sha256("$key $(length(s3.presigned))"))
    headers = edit(gwtest_minted_headers(key, size))
    s3.presigned[signature] = (; key, headers = Dict(headers), expires = time() + seconds)
    path = "/$(s3.bucket)/" * SigV4.uri_encode(key; keep_slash = true)
    object_url = s3test_endpoint(s3) * path
    base = something(url, object_url)
    minted_url = query ? base * gwtest_presigned_query(seconds, signature) : base
    body = gwtest_minted_body(minted_url, size, lifetime, capped, headers)
    return (200, ["content-type" => "application/json"], Vector{UInt8}(body))
end

function gwtest_minted_headers(key, size)
    return [
        "content-length" => string(size),
        "content-type" => "application/octet-stream",
        "if-none-match" => "*",
        "x-amz-checksum-sha256" => base64encode(hex2bytes(key[(end - 63):end])),
        "x-amz-tagging" => "chaintables=attachment",
    ]
end

function gwtest_presigned_query(seconds, signature)
    return "?X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Expires=$seconds" *
        "&X-Amz-SignedHeaders=host&X-Amz-Signature=$signature"
end

function gwtest_minted_body(url, size, lifetime, capped, headers)
    object = join(("\"$name\": \"$value\"" for (name, value) in headers), ", ")
    life = lifetime === nothing ? "" : "\"seconds\": $lifetime, \"capped\": $capped, "
    return "{\"code\": \"minted\", \"message\": \"PUT the attachment's $size bytes\", " *
        "\"url\": \"$url\", \"expires\": \"2026-11-06T12:00:00Z\", " * life *
        "\"headers\": {$object}}"
end

function gwtest_json(status, code, message)
    body = "{\"code\": \"$code\", \"message\": \"$(gwtest_json_string(message))\"}"
    return (status, ["content-type" => "application/json"], Vector{UInt8}(body))
end

gwtest_json_string(text) = replace(text, "\\" => "\\\\", "\"" => "\\\"", "\n" => "\\n")

# `GetCallerIdentity` for `arn`, signed for service sts.
struct StsDouble
    credentials::Credentials
    region::String
    arn::String
end

function (sts::StsDouble)(request)
    refused = gwtest_check_signature(sts.credentials, sts.region, "sts", request)
    refused === nothing || return refused
    _is_identity_call = request.method == "POST" && request.rawpath == "/" &&
        occursin("Action=GetCallerIdentity", String(copy(request.body)))
    _is_identity_call || return (400, Pair{String, String}[], s3test_error("Invalid", ""))
    xml = gwtest_identity_xml(sts.arn)
    return (200, ["content-type" => "text/xml"], Vector{UInt8}(xml))
end

function gwtest_identity_xml(arn)
    return "<GetCallerIdentityResponse><GetCallerIdentityResult><Arn>$arn</Arn>" *
        "<UserId>AROAEXAMPLE:$(last(split(arn, '/')))</UserId>" *
        "<Account>123456789012</Account></GetCallerIdentityResult>" *
        "</GetCallerIdentityResponse>"
end

# The signature the request should carry for `service`, computed from what was
# received. A refusal is AWS's own `403`.
function gwtest_check_signature(credentials::Credentials, region, service, request)
    m = match(GWTEST_AUTHORIZATION, get(request.headers, "authorization", ""))
    m === nothing && return AWS_FORBIDDEN
    id, _, signed_region, signed_service, signed, signature = m.captures
    _is_scope = id == credentials.access_key_id && signed_region == region &&
        signed_service == service
    _is_scope || return AWS_FORBIDDEN
    names = split(signed, ';')
    gwtest_is_sent_as_signed(credentials, request, names) || return AWS_FORBIDDEN
    expected = gwtest_signature(credentials, request, names, region, service)
    return expected == signature ? nothing : AWS_FORBIDDEN
end

function gwtest_is_sent_as_signed(credentials::Credentials, request, names)
    headers = request.headers
    all(name -> haskey(headers, name), names) || return false
    get(headers, "x-amz-content-sha256", "") == bytes2hex(sha256(request.body)) ||
        return false
    token = credentials.session_token
    return token === nothing || get(headers, "x-amz-security-token", "") == token
end

function gwtest_signature(credentials::Credentials, request, names, region, service)
    headers = [name => request.headers[name] for name in names]
    at = s3test_unix_seconds(request.headers["x-amz-date"])
    payload_hash = request.headers["x-amz-content-sha256"]
    signed = SigV4.sign_request(
        credentials; request.method, path = request.rawpath, request.query, headers,
        payload_hash, at, region, service,
    )
    return signed.signature
end

# A gateway bucket on loopback: an S3 double, the gateway double that fills it, and an
# STS double that answers `arn`.
function with_gateway(f; bucket = "bkt", policy = ["p" => [ALICE]], arn = GWTEST_ARN)
    return with_s3_server(; bucket, credentials = GWTEST_CREDS) do s3
        with_doubles_of(f, s3, GatewayDouble(s3; policy), arn)
    end
end

function with_doubles_of(f, s3::S3TestServer, double::GatewayDouble, arn)
    return with_loopback(double) do gateway
        with_loopback(StsDouble(GWTEST_CREDS, s3.region, arn)) do sts
            f((; s3, double, gateway, sts))
        end
    end
end

# The store of the loopback gateway bucket, reading `s3`.
function gateway_store(world; s3 = world.s3, credentials = GWTEST_CREDS, timeout = 30)
    return GatewayObjectStore(
        s3.bucket, loopback_url(world.gateway); s3.region, credentials,
        endpoint = s3test_endpoint(s3), path_style = true, timeout,
        sts_endpoint = loopback_url(world.sts),
    )
end
