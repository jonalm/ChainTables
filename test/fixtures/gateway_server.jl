# Loopback doubles of a gateway and of STS, so no test reaches AWS. The gateway double
# runs the checks of issue #54 §5 in order and fills slots straight into an
# `S3TestServer`'s objects, as the gateway's own role would. Include after s3_server.jl.

const GWTEST_FORBIDDEN =
    (403, Pair{String, String}[], Vector{UInt8}("{\"Message\":\"Forbidden\"}"))

const GWTEST_AUTHORIZATION = Regex(
    "^AWS4-HMAC-SHA256 Credential=([^/]+)/(\\d{8})/([^/]+)/([^/]+)/aws4_request, " *
        "SignedHeaders=([^,]+), Signature=([0-9a-f]{64})\$"
)

const GWTEST_SLOT_KEY = r"^(?:[^/](?:.*[^/])?/)?[0-9]{12}$"

"""
    LoopbackServer

An HTTP/1.1 server on a loopback port that hands every request to `handle(req)`, which
returns `(status, headers, body)`, and records the request.
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
    errormonitor(@async serve_connections(server, sock -> loopback_serve(s, sock)))
    return s
end

Base.close(s::LoopbackServer) = close(s.server)

loopback_url(s::LoopbackServer) = "http://127.0.0.1:$(s.port)"

"""
    with_loopback_server(f, handle)

Return `f(server)` for a fresh `LoopbackServer` over `handle`, closed afterwards.
"""
function with_loopback_server(f, handle)
    server = LoopbackServer(handle)
    return try
        f(server)
    finally
        close(server)
    end
end

function loopback_serve(s::LoopbackServer, sock)
    req = read_request(sock)
    req === nothing && return nothing
    push!(s.requests, req)
    write_response(sock, "", Base.invokelatest(s.handle, req))
    return nothing
end

# A refusal is AWS's own 403, with no gateway code in the body, which the client reads as
# "forbidden".
function gwtest_check_signature(credentials::Credentials, region, service, req)
    m = match(GWTEST_AUTHORIZATION, get(req.headers, "authorization", ""))
    m === nothing && return GWTEST_FORBIDDEN
    id, _, sregion, sservice, signed, signature = m.captures
    (id == credentials.access_key_id && sregion == region && sservice == service) ||
        return GWTEST_FORBIDDEN
    names = split(signed, ';')
    all(name -> haskey(req.headers, name), names) || return GWTEST_FORBIDDEN
    payload_hash = get(req.headers, "x-amz-content-sha256", "")
    payload_hash == bytes2hex(sha256(req.body)) || return GWTEST_FORBIDDEN
    token = credentials.session_token
    (token === nothing || get(req.headers, "x-amz-security-token", "") == token) ||
        return GWTEST_FORBIDDEN
    headers = [name => req.headers[name] for name in names]
    amzdate = get(req.headers, "x-amz-date", "")
    expected = ChainTables.sign_request(
        credentials, sregion, req.method, req.rawpath, req.query, headers, payload_hash,
        amzdate; service
    )
    expected.signature == signature || return GWTEST_FORBIDDEN
    return nothing
end

"""
    GatewayDouble

The gateway double's state: the S3 double it fills, the credentials it checks, the
`caller` it sees in the request context, its `policy` (prefix => names) and a scripted
`respond(req)`, which returns a reply or `nothing`.
"""
mutable struct GatewayDouble
    const s3::S3TestServer
    const credentials::Credentials
    const region::String
    caller::String
    policy::Vector{Pair{String, Vector{String}}}
    respond::Any
end

function GatewayDouble(s3, credentials, caller, policy)
    return GatewayDouble(s3, credentials, "eu-north-1", caller, policy, Returns(nothing))
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
    return prefix == "*" || key == prefix || ChainTables.startswith_bytes(key, prefix * "/")
end

function (g::GatewayDouble)(req)
    scripted = g.respond(req)
    scripted === nothing || return scripted
    refused = gwtest_check_signature(g.credentials, g.region, "lambda", req)
    refused === nothing || return refused
    (req.method, req.rawpath) == ("POST", "/mint") && return gwtest_mint(g, req)
    req.method == "PUT" || return gwtest_json(400, "bad_request", "method $(req.method)")
    req.rawpath == "/" || return gwtest_json(400, "bad_request", "path is not /")
    key = get(Dict(req.query), "key", nothing)
    key === nothing && return gwtest_json(400, "bad_request", "no key")
    gwtest_allowed(g, key) || return gwtest_not_allowed(g, key)
    occursin(GWTEST_SLOT_KEY, key) ||
        return gwtest_json(400, "not_a_slot", "$key is not a slot")
    return gwtest_fill(g, key, req.body)
end

function gwtest_not_allowed(g::GatewayDouble, key)
    said = "$(g.caller) may not write under $(dirname(key))"
    return gwtest_json(403, "not_allowed", said)
end

function gwtest_fill(g::GatewayDouble, key, body)
    user = gwtest_author(body)
    user isa Symbol && return gwtest_json(400, String(user), "the record has no author")
    user == g.caller || return gwtest_json(
        403, "author_mismatch",
        "the record names '$user' as client.user but the caller is '$(g.caller)'"
    )
    length(body) <= 4 * 1024 * 1024 ||
        return gwtest_json(413, "too_large", "$(length(body)) bytes")
    haskey(g.s3.objects, key) && return gwtest_json(412, "slot_taken", "$key exists")
    s3test_store!(g.s3, key, body)
    return gwtest_json(200, "created", key)
end

# The record's `client.user`, or the code the gateway refuses it with.
function gwtest_author(body)
    decoded = try
        ChainTables.CBOR.decode(body)
    catch e
        e isa ChainTables.CBOR.DecodeError || rethrow()
        nothing
    end
    decoded isa Dict || return :not_cbor_map
    user = get(get(decoded, "client", Dict()), "user", nothing)
    (user isa String && !isempty(user)) || return :no_author
    return user
end

# The mint route (ADR-0046), as handler.py answers it: the policy on the attachment's
# prefix, `present` when the S3 double holds the key, else a URL the S3 double honours.
function gwtest_mint(g::GatewayDouble, req)
    q = Dict(req.query)
    (haskey(q, "key") && haskey(q, "size") && isempty(req.body)) ||
        return gwtest_json(400, "bad_request", "key, size, no body")
    key = q["key"]
    m = match(r"^(?:(.+)/)?_attachments/[0-9a-f]{64}$", key)
    prefix = m === nothing ? dirname(key) : something(m.captures[1], "")
    gwtest_allowed(g, prefix) || return gwtest_not_allowed(g, key)
    m === nothing && return gwtest_json(400, "not_a_slot", "$key is not an attachment")
    occursin(r"^[0-9]+$", q["size"]) || return gwtest_json(400, "bad_request", "size")
    size = parse(Int, q["size"])
    size <= 5 * 1024^3 || return gwtest_json(413, "too_large", "over 5 GiB")
    haskey(g.s3.objects, key) && return gwtest_json(200, "present", "already stored")
    return gwtest_minted(g.s3, key, size)
end

"""
    gwtest_minted(s3, key, size; seconds = 900, lifetime = seconds, capped = false,
                  url = nothing, edit = identity, query = true)

Return a `minted` reply for `key` whose URL `s3` honours for `seconds`. `lifetime` is
the life the reply states (`nothing`: none, as from a gateway older than 2026-11-10);
`edit` rewrites the signed headers; `query = false` mints a URL with no signature.
"""
function gwtest_minted(
        s3::S3TestServer, key, size; seconds = 900, lifetime = seconds, capped = false,
        url = nothing, edit = identity, query = true
    )
    signature = bytes2hex(sha256(key * string(time_ns())))
    headers = edit(gwtest_minted_headers(key, size))
    s3.presigned[signature] = (; key, headers = Dict(headers), expires = time() + seconds)
    path = "/$(s3.bucket)/" * ChainTables.uri_encode(key; keep_slash = true)
    place = something(url, s3test_endpoint(s3) * path)
    signed = query ? "?X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Expires=$seconds" *
        "&X-Amz-SignedHeaders=host&X-Amz-Signature=$signature" : ""
    object = join(("\"$k\": \"$v\"" for (k, v) in headers), ", ")
    life = lifetime === nothing ? "" : "\"seconds\": $lifetime, \"capped\": $capped, "
    body = "{\"code\": \"minted\", \"message\": \"PUT the attachment's $size bytes\", " *
        "\"url\": \"$(place * signed)\", \"expires\": \"2026-11-06T12:00:00Z\", " * life *
        "\"headers\": {$object}}"
    return (200, ["content-type" => "application/json"], Vector{UInt8}(body))
end

function gwtest_minted_headers(key, size)
    checksum = ChainTables.Base64.base64encode(hex2bytes(key[(end - 63):end]))
    return [
        "content-length" => string(size), "content-type" => "application/octet-stream",
        "if-none-match" => "*", "x-amz-checksum-sha256" => checksum,
        "x-amz-tagging" => "chaintables=attachment",
    ]
end

"""
    StsDouble

`sts:GetCallerIdentity` for `arn`, answered only when signed with `credentials` for
service `sts` in `region`.
"""
struct StsDouble
    credentials::Credentials
    region::String
    arn::String
end

function (d::StsDouble)(req)
    refused = gwtest_check_signature(d.credentials, d.region, "sts", req)
    refused === nothing || return refused
    is_identity_call = req.method == "POST" && req.rawpath == "/" &&
        occursin("Action=GetCallerIdentity", String(copy(req.body)))
    is_identity_call || return (400, Pair{String, String}[], Vector{UInt8}("<Error/>"))
    body = "<GetCallerIdentityResponse><GetCallerIdentityResult><Arn>$(d.arn)</Arn>" *
        "<Account>123456789012</Account></GetCallerIdentityResult>" *
        "</GetCallerIdentityResponse>"
    return (200, ["content-type" => "text/xml"], Vector{UInt8}(body))
end

"""
    with_gateway_doubles(f, credentials, caller, policy; arn, filled_bucket = "bkt")

Return `f(doubles)` for a loopback S3 of bucket `bkt`, a gateway double that fills
`filled_bucket` (another S3 double when it differs: a mispaired gateway), an STS double
naming `arn`, and a `GatewayObjectStore` over them; all closed afterwards. `doubles` is
`(; s3, filled, double, gw, sts, store)`.
"""
function with_gateway_doubles(f, credentials, caller, policy; arn, filled_bucket = "bkt")
    s3 = S3TestServer(; bucket = "bkt", credentials)
    same = filled_bucket == "bkt"
    filled = same ? s3 : S3TestServer(; bucket = filled_bucket, credentials)
    double = GatewayDouble(filled, credentials, caller, policy)
    gw = LoopbackServer(double)
    sts = LoopbackServer(StsDouble(credentials, "eu-north-1", arn))
    store = ChainTables.GatewayObjectStore(
        "bkt", loopback_url(gw); region = "eu-north-1", credentials,
        endpoint = s3test_endpoint(s3), path_style = true, timeout = 30,
        sts_endpoint = loopback_url(sts)
    )
    return try
        f((; s3, filled, double, gw, sts, store))
    finally
        foreach(close, unique([s3, filled, gw, sts]))
    end
end
