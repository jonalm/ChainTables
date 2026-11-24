# ADR-0028 — the gateway store: `Chain(…; gateway = url)`, the signed PUT to the function
# URL and its status mapping, the author from `sts:GetCallerIdentity`, the 4 MiB cap,
# `WriteRefusedError`, and a commit end to end through a loopback gateway that fills slots
# in a loopback S3 (issue #57; the contract is issue #54). Nothing here reaches AWS: the
# live test is test/live/gateway.jl (ADR-0030). The loopback S3 (`S3TestServer`, `s3test_*`)
# is test/fixtures/s3_server.jl and `gwtest_record` is test/fixtures/gateway.jl, both
# included by test/runtests.jl ahead of this file.
using Sockets
using SHA: sha256
using ChainTables: Chain, Credentials, S3ObjectStore, GatewayObjectStore, PutOutcome, TransportError,
    WriteRefusedError, WriteBuilderError, LostRaceError, fetch_object, put_object_if_absent, stat_object, list_objects
const GWT = ChainTables

# ---------------------------------------------------------------------------
# A loopback HTTP/1.1 server that hands every request to `handle(req)` and records it:
# the gateway double and the STS double below are handlers. One connection per request.
# ---------------------------------------------------------------------------
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
    get(headers, "expect", "") == "100-continue" && write(sock, "HTTP/1.1 100 Continue\r\n\r\n")
    len = parse(Int, get(headers, "content-length", "0"))
    body = len > 0 ? read(sock, len) : UInt8[]
    rawpath, rawquery = occursin('?', target) ? split(target, '?'; limit = 2) : (target, "")
    query = Pair{String, String}[
        s3test_percent_decode(first(kv)) => s3test_percent_decode(get(kv, 2, ""))
            for kv in (split(p, '='; limit = 2) for p in split(rawquery, '&'; keepempty = false))
    ]
    req = (; method = String(method), rawpath = String(rawpath), rawquery = String(rawquery), query, headers, body)
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

# The signature a request should carry for `service`, recomputed from what was received;
# a refusal is AWS's own 403 — no gateway code in the body, which the client reads as
# "forbidden".
function gwtest_check_signature(credentials::Credentials, region, service, req)
    auth = get(req.headers, "authorization", "")
    m = match(r"^AWS4-HMAC-SHA256 Credential=([^/]+)/(\d{8})/([^/]+)/([^/]+)/aws4_request, SignedHeaders=([^,]+), Signature=([0-9a-f]{64})$", auth)
    m === nothing && return (403, [], Vector{UInt8}("{\"Message\":\"Forbidden\"}"))
    id, datestamp, sregion, sservice, signed, signature = m.captures
    (id == credentials.access_key_id && sregion == region && sservice == service) ||
        return (403, [], Vector{UInt8}("{\"Message\":\"Forbidden\"}"))
    all(name -> haskey(req.headers, name), split(signed, ';')) || return (403, [], Vector{UInt8}("{\"Message\":\"Forbidden\"}"))
    headers = [name => req.headers[name] for name in split(signed, ';')]
    payload_hash = get(req.headers, "x-amz-content-sha256", "")
    payload_hash == bytes2hex(sha256(req.body)) || return (403, [], Vector{UInt8}("{\"Message\":\"Forbidden\"}"))
    amzdate = get(req.headers, "x-amz-date", "")
    if credentials.session_token !== nothing
        get(req.headers, "x-amz-security-token", "") == credentials.session_token || return (403, [], Vector{UInt8}("{\"Message\":\"Forbidden\"}"))
    end
    expected = GWT.sign_request(credentials, sregion, req.method, req.rawpath, req.query, headers, payload_hash, amzdate; service)
    expected.signature == signature || return (403, [], Vector{UInt8}("{\"Message\":\"Forbidden\"}"))
    return nothing
end

# ---------------------------------------------------------------------------
# The gateway double: the seven checks of issue #54 §5 in order, filling slots straight
# into an S3TestServer's objects — the gateway's own role holds PutObject. `caller` is
# the name the double sees in the request context; `policy` is prefix => names.
# ---------------------------------------------------------------------------
mutable struct GatewayDouble
    const s3::S3TestServer
    const credentials::Credentials
    const region::String
    caller::String
    policy::Vector{Pair{String, Vector{String}}}
    respond::Any                 # req -> (status, headers, body) to script a reply, or nothing
end
gwtest_json(status, code, message) = (
    status, ["content-type" => "application/json"],
    Vector{UInt8}("{\"code\": \"$code\", \"message\": \"$(replace(message, "\\" => "\\\\", "\"" => "\\\"", "\n" => "\\n"))\"}"),
)

gwtest_allowed(g::GatewayDouble, key) = any(g.policy) do (prefix, names)
    g.caller in names && (prefix == "*" || GWT.startswith_bytes(key, prefix * "/") || key == prefix)
end

function (g::GatewayDouble)(req)
    scripted = g.respond(req)
    scripted === nothing || return scripted
    refused = gwtest_check_signature(g.credentials, g.region, "lambda", req)
    refused === nothing || return refused
    (req.method, req.rawpath) == ("POST", "/mint") && return gwtest_mint(g, req)
    req.method == "PUT" || return gwtest_json(400, "bad_request", "method $(req.method)")
    req.rawpath == "/" || return gwtest_json(400, "bad_request", "path $(req.rawpath) is not /")
    i = findfirst(kv -> kv[1] == "key", req.query)
    i === nothing && return gwtest_json(400, "bad_request", "no key")
    key = req.query[i][2]
    gwtest_allowed(g, key) || return gwtest_json(403, "not_allowed", "$(g.caller) may not write under $(dirname(key))")
    occursin(r"^(?:[^/](?:.*[^/])?/)?[0-9]{12}$", key) || return gwtest_json(400, "not_a_slot", "$key is not a slot")
    decoded = try
        GWT.CBOR.decode(req.body)
    catch e
        e
    end
    decoded isa Dict || return gwtest_json(400, "not_cbor_map", "the body is not a CBOR map")
    user = get(get(decoded, "client", Dict()), "user", nothing)
    (user isa String && !isempty(user)) || return gwtest_json(400, "no_author", "client.user is absent")
    user == g.caller || return gwtest_json(
        403, "author_mismatch", "the record names '$user' as client.user but the caller is '$(g.caller)': " *
            "a client bug, or the credentials changed between the identity call and the commit; report it"
    )
    length(req.body) <= 4 * 1024 * 1024 || return gwtest_json(413, "too_large", "$(length(req.body)) bytes")
    haskey(g.s3.objects, key) && return gwtest_json(412, "slot_taken", "$key exists")
    g.s3.objects[key] = copy(req.body)
    g.s3.modified[key] = floor(Int64, time())
    return gwtest_json(200, "created", key)
end

# The mint route (ADR-0046), as handler.py answers it: the policy on the attachment's
# prefix, `present` when the S3 double holds the key, else a URL the S3 double honours
# (`s3.presigned`) and the headers it signs, in json.dumps's layout.
function gwtest_mint(g::GatewayDouble, req)
    q = Dict(req.query)
    (haskey(q, "key") && haskey(q, "size") && isempty(req.body)) || return gwtest_json(400, "bad_request", "key, size, no body")
    key = q["key"]
    m = match(r"^(?:(.+)/)?_attachments/[0-9a-f]{64}$", key)
    gwtest_allowed(g, m === nothing ? dirname(key) : something(m.captures[1], "")) ||
        return gwtest_json(403, "not_allowed", "$(g.caller) may not write under $(dirname(key))")
    m === nothing && return gwtest_json(400, "not_a_slot", "$key is neither a slot nor an attachment")
    occursin(r"^[0-9]+$", q["size"]) || return gwtest_json(400, "bad_request", "size")
    parse(Int, q["size"]) <= 5 * 1024^3 || return gwtest_json(413, "too_large", "over 5 GiB")
    haskey(g.s3.objects, key) && return gwtest_json(200, "present", "attachment $key is already stored; upload nothing")
    return gwtest_minted(g.s3, key, parse(Int, q["size"]))
end

# `seconds` is the URL's life at the S3 double, `lifetime` the one the reply gives (`nothing`: no
# `seconds` or `capped` in it, as from a gateway older than 2026-11-10).
function gwtest_minted(
        s3::S3TestServer, key, size; seconds = 900, lifetime = seconds, capped = false, url = nothing,
        edit = identity, query = true
    )
    signature = bytes2hex(rand(UInt8, 32))
    headers = edit(
        [
            "content-length" => string(size), "content-type" => "application/octet-stream", "if-none-match" => "*",
            "x-amz-checksum-sha256" => GWT.Base64.base64encode(hex2bytes(key[(end - 63):end])),
            "x-amz-tagging" => "chaintables=attachment",
        ]
    )
    s3.presigned[signature] = (; key, headers = Dict(headers), expires = time() + seconds)
    url = something(url, s3test_endpoint(s3) * "/$(s3.bucket)/" * GWT.uri_encode(key; keep_slash = true)) *
        (query ? "?X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Expires=$seconds&X-Amz-SignedHeaders=host&X-Amz-Signature=$signature" : "")
    object = join(("\"$k\": \"$v\"" for (k, v) in headers), ", ")
    body = "{\"code\": \"minted\", \"message\": \"PUT the attachment's $size bytes\", \"url\": \"$url\", " *
        "\"expires\": \"2026-11-06T12:00:00Z\", " *
        (lifetime === nothing ? "" : "\"seconds\": $lifetime, \"capped\": $capped, ") * "\"headers\": {$object}}"
    return (200, ["content-type" => "application/json"], Vector{UInt8}(body))
end

# The STS double: `GetCallerIdentity` for `arn`, signed for service sts.
function gwtest_sts(credentials::Credentials, region, arn)
    return function (req)
        refused = gwtest_check_signature(credentials, region, "sts", req)
        refused === nothing || return refused
        (req.method == "POST" && req.rawpath == "/" && occursin("Action=GetCallerIdentity", String(copy(req.body)))) ||
            return (400, [], Vector{UInt8}("<ErrorResponse><Error><Code>InvalidAction</Code></Error></ErrorResponse>"))
        body = "<GetCallerIdentityResponse xmlns=\"https://sts.amazonaws.com/doc/2011-06-15/\"><GetCallerIdentityResult>" *
            "<Arn>$arn</Arn><UserId>AROAEXAMPLE:$(last(split(arn, '/')))</UserId><Account>123456789012</Account>" *
            "</GetCallerIdentityResult><ResponseMetadata><RequestId>x</RequestId></ResponseMetadata></GetCallerIdentityResponse>"
        return (200, ["content-type" => "text/xml"], Vector{UInt8}(body))
    end
end

const GWTEST_CREDS = Credentials("AKIATEST", "topsecret"; session_token = "session-token")
const GWTEST_ARN = "arn:aws:sts::123456789012:assumed-role/AWSReservedSSO_chaintables-writer_0123456789abcdef/alice@example.com"

@testset "gateway" begin
    # ------------------------------------------------------------------------
    # Construction (ADR-0028, ADR-0019): the keyword builds the store from the chain's own
    # bucket, region and credentials; no I/O; the refusals are ArgumentErrors.
    # ------------------------------------------------------------------------
    @testset "Chain(…; gateway = url) builds a GatewayObjectStore, no I/O" begin
        creds = Credentials("AKIATEST", "topsecret"; session_token = "tok")
        url = "https://abc123.lambda-url.eu-north-1.on.aws"
        chain = Chain("bkt", "p"; gateway = url, region = "eu-north-1", credentials = creds, cache_dir = "/c")
        @test chain isa Chain{GatewayObjectStore}
        @test sprint(show, chain) == "Chain(\"bkt\", \"p\"; store = GatewayObjectStore)"
        store = chain.store
        @test store.function_url == url && store.host == "abc123.lambda-url.eu-north-1.on.aws"
        @test store.s3 isa S3ObjectStore && store.s3.bucket == "bkt" && store.s3.region == "eu-north-1"
        @test store.s3.credentials === creds && GWT.is_aws(store) && chain.record_user
        @test store.sts_endpoint == "https://sts.eu-north-1.amazonaws.com"
        @test Chain(
            "bkt", "p"; gateway = "https://abc.lambda-url.cn-north-1.on.aws", region = "cn-north-1",
            credentials = creds
        ).store.sts_endpoint == "https://sts.cn-north-1.amazonaws.com.cn"   # the China partition
        @test sprint(show, store) == "GatewayObjectStore(\"bkt\", \"$url\"; region = \"eu-north-1\")"
        @test !occursin("topsecret", sprint(show, store))
        # the function URL's region is checked against the chain's when the host carries one
        @test_throws "region \"us-east-1\" disagrees with the region in the function URL" Chain(
            "bkt", "p";
            gateway = url, region = "us-east-1", credentials = creds
        )
        @test Chain("bkt", "p"; gateway = url * "/", region = "eu-north-1", credentials = creds).store.function_url == url
        @test Chain("bkt", "p"; gateway = "http://127.0.0.1:9999", region = "us-east-1", credentials = creds).store.host == "127.0.0.1:9999"
        # two stores, or a record with no author, cannot be asked for
        @test_throws "gateway and store were both given; a chain has one store" Chain(
            "bkt", "p"; gateway = url,
            store = GWT.Testing.InMemoryObjectStore(), region = "eu-north-1", credentials = creds
        )
        @test_throws "record_user = false with a gateway: the gateway refuses a record with no author (ADR-0028)" Chain(
            "bkt", "p";
            gateway = url, region = "eu-north-1", credentials = creds, record_user = false
        )
        # a minted URL is expected where the gateway presigns: the bucket's regional virtual host
        # whenever the store is AWS, whatever endpoint or addressing the reads use (ADR-0046)
        h = "ab"^32
        regional = "https://bkt.s3.eu-north-1.amazonaws.com/p/_attachments/$h"
        for (endpoint, path_style) in (
                (nothing, false), (nothing, true), ("https://s3.eu-north-1.amazonaws.com", true),
                ("https://s3.eu-north-1.amazonaws.com", false), ("https://s3-fips.eu-north-1.amazonaws.com", true),
                ("https://s3.dualstack.eu-north-1.amazonaws.com", false),
            )
            aws = Chain("bkt", "p"; gateway = url, region = "eu-north-1", credentials = creds, endpoint, path_style).store
            @test GWT.expected_attachment_url(aws, "p/_attachments/$h") == regional
        end
        # a store that is not AWS (a test's loopback) is expected at its own object URL
        local_store = Chain(
            "bkt", "p"; gateway = url, region = "eu-north-1", credentials = creds,
            endpoint = "http://127.0.0.1:9000", path_style = true
        ).store
        @test GWT.expected_attachment_url(local_store, "p/_attachments/$h") == "http://127.0.0.1:9000/bkt/p/_attachments/$h"
        # the URL is scheme://host[:port] and nothing more
        for bad in ("abc123.lambda-url.eu-north-1.on.aws", url * "/put", url * "?x=1", "ftp://x")
            @test_throws "gateway $(repr(bad)) is not of the form scheme://host[:port]" Chain(
                "bkt", "p";
                gateway = bad, region = "eu-north-1", credentials = creds
            )
        end
        # region and credentials resolve as for the S3 client, and the S3 half honours endpoint and path_style
        withenv(
            "AWS_ACCESS_KEY_ID" => "AKIAX", "AWS_SECRET_ACCESS_KEY" => "s3cret", "AWS_SESSION_TOKEN" => nothing,
            "AWS_REGION" => "eu-north-1"
        ) do
            chain = Chain("bkt", "p"; gateway = url, endpoint = "http://127.0.0.1:9000", path_style = true, cache_dir = "/c")
            @test chain.store.s3.credentials == Credentials("AKIAX", "s3cret") && chain.region == "eu-north-1"
            @test chain.store.s3.base == "http://127.0.0.1:9000" && chain.store.s3.path_style && !GWT.is_aws(chain.store)
            @test GWT.unsupported_store(chain)                        # ADR-0016's gate is the S3 half's
            @test_throws "create_chain(chain) refuses to commit to http://127.0.0.1:9000, which is not AWS S3" GWT.create_chain(chain)
        end
        withenv("AWS_REGION" => nothing, "AWS_DEFAULT_REGION" => nothing) do
            @test_throws "region is required by the S3 client" Chain("bkt", "p"; gateway = url, credentials = creds)
        end
        # the store type stays for dispatch and tests: buildable, with the same rules
        s = GatewayObjectStore("bkt", url; region = "eu-north-1", credentials = creds)
        @test s.s3.bucket == "bkt" && s.timeout == 60
        @test_throws "bucket name \"my.bucket\" contains a dot" GatewayObjectStore("my.bucket", url; region = "eu-north-1", credentials = creds)
        @test GWT.record_cap(s) == 4 * 1024 * 1024
        @test GWT.record_cap(s.s3) == GWT.Ops.MAX_RECORD_BYTES == 64 * 1024 * 1024
        @test GWT.record_cap(GWT.Testing.InMemoryObjectStore()) == 64 * 1024 * 1024
    end

    # ------------------------------------------------------------------------
    # The put over the wire (issue #54 §5, §6): a signed PUT to `/?key=`, service lambda,
    # and every gateway status mapped onto the port and the retry loop. The reads go to
    # the S3 half.
    # ------------------------------------------------------------------------
    @testset "put_object_if_absent: the wire and the status mapping" begin
        s3 = S3TestServer(; bucket = "bkt", credentials = GWTEST_CREDS)
        double = GatewayDouble(s3, GWTEST_CREDS, "eu-north-1", "alice@example.com", ["p" => ["alice@example.com"]], _ -> nothing)
        gw = LoopbackServer(double)
        try
            store = GatewayObjectStore(
                "bkt", loopback_url(gw); region = "eu-north-1", credentials = GWTEST_CREDS,
                endpoint = s3test_endpoint(s3), path_style = true, timeout = 30
            )
            key = "p/000000000001"
            record = gwtest_record("alice@example.com")
            @test fetch_object(store, key) === nothing && stat_object(store, key) === nothing && isempty(list_objects(store, "p/"))
            @test all(r -> r.method in ("GET", "HEAD"), s3.requests) && isempty(gw.requests)     # reads never touch the gateway
            @test put_object_if_absent(store, key, record) == PutOutcome(true, 200)
            @test s3.objects[key] == record && fetch_object(store, key) == record
            @test put_object_if_absent(store, key, gwtest_record("alice@example.com")) == PutOutcome(false, 412)   # slot_taken
            @test s3.objects[key] == record
            @test stat_object(store, key).size == length(record) && [m.key for m in list_objects(store, "p/")] == [key]
            # what went over the wire: the key in the query, encoded once, the path bare, content-type cbor, every header signed
            puts = gw.requests
            @test length(puts) == 2 && all(r -> r.method == "PUT" && r.rawpath == "/" && r.query == ["key" => key], puts)
            @test all(r -> r.headers["content-type"] == "application/cbor" && r.headers["content-length"] == string(length(record)), puts)
            @test all(r -> r.headers["x-amz-security-token"] == "session-token" && r.headers["host"] == "127.0.0.1:$(gw.port)", puts)
            @test all(r -> occursin("/eu-north-1/lambda/aws4_request, SignedHeaders=content-type;host;x-amz-content-sha256;x-amz-date;x-amz-security-token,", r.headers["authorization"]), puts)
            @test all(r -> r.headers["x-amz-content-sha256"] == bytes2hex(sha256(record)), puts)
            @test !any(r -> haskey(r.headers, "if-none-match"), puts)                 # the gateway adds the condition
            odd = "p/a b\$c/000000000002"
            @test put_object_if_absent(store, odd, record).created && haskey(s3.objects, odd)
            @test gw.requests[end].rawquery == "key=p%2Fa%20b%24c%2F000000000002"     # RFC 3986, '/' encoded, once
            # a refusal by policy, by author, and by AWS before the handler: WriteRefusedError, never retried
            double.caller = "bob@example.com"
            e = try
                put_object_if_absent(store, "p/000000000003", gwtest_record("bob@example.com")); nothing
            catch e
                e
            end
            @test e isa WriteRefusedError && e.reason == "not_allowed" && e.key == "p/000000000003" && e.caller === nothing
            @test !GWT.retryable(e)
            msg = sprint(showerror, e)
            @test startswith(msg, "WriteRefusedError: write refused: the gateway at http://127.0.0.1:$(gw.port) refused to fill p/000000000003")
            @test occursin("not_allowed: bob@example.com may not write under p", msg)
            @test occursin("ask the bucket's operator to add the name to the gateway policy", msg)
            double.caller = "alice@example.com"
            e = try
                put_object_if_absent(store, "p/000000000003", gwtest_record("mallory")); nothing
            catch e
                e
            end
            @test e isa WriteRefusedError && e.reason == "author_mismatch"
            @test occursin("author_mismatch: the record names 'mallory' as client.user but the caller is 'alice@example.com'", sprint(showerror, e))
            @test occursin("report it", sprint(showerror, e))
            wrong = GatewayObjectStore(
                "bkt", loopback_url(gw); region = "eu-north-1", credentials = Credentials("AKIATEST", "nope"; session_token = "session-token"),
                endpoint = s3test_endpoint(s3), path_style = true
            )
            e = try
                put_object_if_absent(wrong, "p/000000000003", record); nothing
            catch e
                e
            end
            @test e isa WriteRefusedError && e.reason == "forbidden"
            @test occursin("AWS refused the invocation", sprint(showerror, e)) && occursin("lambda:InvokeFunctionUrl and lambda:InvokeFunction", sprint(showerror, e))
            @test occursin("(HTTP 403 with no gateway code): Forbidden.", sprint(showerror, e))   # AWS's own `Message` is carried
            # an expired token is also AWS's bare 403: the message names that cause as well as the permission
            double.respond = req -> (403, [], Vector{UInt8}("{\"message\":\"The security token included in the request is expired\"}"))
            e = try
                put_object_if_absent(store, "p/000000000003", record); nothing
            catch e
                e
            end
            @test e isa WriteRefusedError && e.reason == "forbidden" && !GWT.retryable(e)
            @test occursin("(HTTP 403 with no gateway code): The security token included in the request is expired.", sprint(showerror, e))
            @test occursin("expired or revoked credentials (refresh them, e.g. aws sso login)", sprint(showerror, e))
            # S3 refusing the gateway's own put is the deployment's fault: refused, never retried
            double.respond = req -> gwtest_json(502, "s3_refused", "S3 answered 403 AccessDenied")
            e = try
                put_object_if_absent(store, "p/000000000003", record); nothing
            catch e
                e
            end
            @test e isa WriteRefusedError && e.reason == "s3_refused" && !GWT.retryable(e)
            @test occursin("s3_refused: S3 answered 403 AccessDenied. S3 refused the gateway's own put", sprint(showerror, e))
            @test occursin("report it to the bucket's operator", sprint(showerror, e))
            # a 403 code this client does not know: refused, never retried, and says so
            double.respond = req -> gwtest_json(403, "brand_new", "a newer gateway's reason")
            e = try
                put_object_if_absent(store, "p/000000000003", record); nothing
            catch e
                e
            end
            @test e isa WriteRefusedError && e.reason == "brand_new" && !GWT.retryable(e)
            @test occursin("brand_new: a newer gateway's reason. This gateway answered with a reason this client does not know", sprint(showerror, e))
            double.respond = _ -> nothing
            @test !haskey(s3.objects, "p/000000000003")
            # a client bug is a TransportError carrying the gateway's code and message, not retried
            for (k, bytes, code) in (
                    ("p/genesis", record, "not_a_slot"), ("p/000000000003", b"not cbor", "not_cbor_map"),
                    ("p/000000000003", gwtest_record(""), "no_author"),
                )
                e = try
                    put_object_if_absent(store, k, bytes); nothing
                catch e
                    e
                end
                @test e isa TransportError && e.status == 400 && !GWT.retryable(e)
                @test occursin("HTTP 400 $code: ", sprint(showerror, e))
            end
            # the cap: the store's own guard, before any request
            n = length(gw.requests)
            @test_throws "4194305 bytes for p/000000000003 is over the gateway's 4 MiB record cap" put_object_if_absent(store, "p/000000000003", zeros(UInt8, 4 * 1024 * 1024 + 1))
            @test length(gw.requests) == n
            double.respond = req -> gwtest_json(413, "too_large", "4194305 bytes")
            e = try
                put_object_if_absent(store, "p/000000000003", record); nothing
            catch e
                e
            end
            @test e isa TransportError && e.status == 413 && !GWT.retryable(e) && occursin("HTTP 413 too_large: 4194305 bytes", sprint(showerror, e))
            # 409, 429, 5xx and Lambda's own errors are retried by the commit layer; JSON escapes are read back
            for (status, body) in (
                    (409, gwtest_json(409, "conflict", "S3 409")[3]), (429, Vector{UInt8}("{\"Message\":\"Rate Exceeded.\"}")),
                    (502, gwtest_json(502, "s3_error", "S3 said \"InternalError\"\n")[3]), (503, UInt8[]), (504, Vector{UInt8}("{}")),
                )
                double.respond = req -> (status, [], body)
                e = try
                    put_object_if_absent(store, "p/000000000003", record); nothing
                catch e
                    e
                end
                @test e isa TransportError && e.status == status && GWT.retryable(e)
                status == 502 && @test occursin("HTTP 502 s3_error: S3 said \"InternalError\"\n", sprint(showerror, e))
                status == 503 && @test endswith(sprint(showerror, e), "HTTP 503 (HTTP 503)")
            end
            double.respond = _ -> nothing
            # nothing listening: no status, retryable
            closed = LoopbackServer(_ -> nothing)
            port = closed.port
            close(closed)
            sleep(0.1)
            dead = GatewayObjectStore(
                "bkt", "http://127.0.0.1:$port"; region = "eu-north-1", credentials = GWTEST_CREDS,
                endpoint = s3test_endpoint(s3), path_style = true, timeout = 5
            )
            e = try
                put_object_if_absent(dead, key, record); nothing
            catch e
                e
            end
            @test e isa TransportError && e.status === nothing && GWT.retryable(e)
            @test startswith(sprint(showerror, e), "TransportError: PUT http://127.0.0.1:$port/?key=p%2F000000000001: no response")
        finally
            close(gw); close(s3)
        end
    end

    # ------------------------------------------------------------------------
    # An attachment through the gateway (ADR-0046): the mint route, the URL checked, the
    # bytes streamed to S3 with exactly the signed headers, the key confirmed in our bucket.
    # ------------------------------------------------------------------------
    @testset "put_attachment: mint, check the URL, upload, confirm (ADR-0046)" begin
        s3 = S3TestServer(; bucket = "bkt", credentials = GWTEST_CREDS)
        double = GatewayDouble(s3, GWTEST_CREDS, "eu-north-1", "alice@example.com", ["p" => ["alice@example.com"]], _ -> nothing)
        gw = LoopbackServer(double)
        dir = mktempdir()
        try
            store = GatewayObjectStore(
                "bkt", loopback_url(gw); region = "eu-north-1", credentials = GWTEST_CREDS,
                endpoint = s3test_endpoint(s3), path_style = true, timeout = 30
            )
            bytes = rand(UInt8, 2 * 1024 * 1024 + 3)
            h = bytes2hex(sha256(bytes))
            key = "p/_attachments/" * h
            path = joinpath(dir, "a")
            write(path, bytes)
            put(k = key) = open(io -> GWT.put_attachment(store, k, io), path)
            @test put()
            @test s3.objects[key] == bytes
            # the mint: POST /mint with the key and size in the query, signed for lambda, no body
            mints = filter(r -> r.rawpath == "/mint", gw.requests)
            @test length(mints) == 1 && mints[1].method == "POST" && mints[1].query == ["key" => key, "size" => string(length(bytes))]
            @test isempty(mints[1].body) && occursin("/eu-north-1/lambda/aws4_request, SignedHeaders=host;x-amz-content-sha256;x-amz-date;x-amz-security-token,", mints[1].headers["authorization"])
            # the upload: to the minted URL, the signed headers exactly, no Authorization, no other x-amz-* header
            upload = only(filter(r -> r.method == "PUT", s3.requests))
            @test upload.path == "/bkt/$key" && any(kv -> first(kv) == "X-Amz-Signature", upload.query)
            @test !haskey(upload.headers, "authorization")
            @test sort(filter(startswith("x-amz-"), collect(keys(upload.headers)))) == ["x-amz-checksum-sha256", "x-amz-tagging"]
            @test upload.headers["x-amz-checksum-sha256"] == GWT.Base64.base64encode(sha256(bytes))
            # then a HEAD of the key in our bucket
            @test s3.requests[end].method == "HEAD" && s3.requests[end].path == "/bkt/$key"
            # present: the mint says so, nothing is uploaded, the key is still confirmed
            n = length(s3.requests)
            @test !put()
            @test [r.method for r in s3.requests[(n + 1):end]] == ["HEAD"]
            # a race lost to another writer: the upload is 412, and a second mint finds it present
            other = rand(UInt8, 100); ho = bytes2hex(sha256(other)); ko = "p/_attachments/" * ho
            s3.objects[ko] = other; s3.modified[ko] = floor(Int64, time())
            minted = Ref(false)
            double.respond = req -> req.rawpath == "/mint" && !minted[] ? (minted[] = true; gwtest_minted(s3, ko, 100)) : nothing
            nm = count(r -> r.rawpath == "/mint", gw.requests)
            @test !GWT.put_attachment(store, ko, IOBuffer(other))
            @test count(r -> r.rawpath == "/mint", gw.requests) == nm + 2 && s3.objects[ko] == other
            # S3 refuses the upload as present (412), and the gateway's second mint still finds it absent:
            # its HEADs go to another bucket than the one its URLs point at — a gateway mismatch
            double.respond = req -> req.rawpath == "/mint" ? gwtest_minted(s3, ko, 100) : nothing
            e = try
                GWT.put_attachment(store, ko, IOBuffer(other)); nothing
            catch e
                e
            end
            @test e isa GWT.GatewayMismatchError && e.key == ko && e.bucket == "bkt" && e.gateway == loopback_url(gw)
            @test sprint(showerror, e) == "GatewayMismatchError: gateway mismatch: S3 refused the upload of $ko to bucket " *
                "bkt as already present (412), and the gateway at $(loopback_url(gw)) then found it absent and minted " *
                "another URL: the gateway checks another bucket than the one its URLs and this chain write. Pair the " *
                "bucket with its own gateway — one ChainTables.Bucket value holds both (ADR-0029, ADR-0046)."
            double.respond = _ -> nothing
            # bytes that do not hash to the key: S3's BadDigest, nothing stored
            bad = "p/_attachments/" * "0"^64
            e = try
                put(bad); nothing
            catch e
                e
            end
            @test e isa GWT.AttachmentChangedError && e.key == bad && !haskey(s3.objects, bad)
            @test startswith(sprint(showerror, e), "AttachmentChangedError: attachment changed: the upload of $bad to $(s3test_endpoint(s3))/bkt/$bad was refused as BadDigest")
            # an expired URL, two ways (ADR-0046: S3 refuses an upload still running when its URL expires).
            # The caller waited past the URL's life before uploading: nothing is sent.
            fresh = rand(UInt8, 10); kf = "p/_attachments/" * bytes2hex(sha256(fresh))
            double.respond = req -> req.rawpath == "/mint" ? gwtest_minted(s3, kf, 10; seconds = 1) : nothing
            reply = GWT.mint(store, kf, Int64(10))
            sleep(1.2)
            n = length(s3.requests)
            e = try
                GWT.upload_minted(store, kf, IOBuffer(fresh), Int64(10), reply); nothing
            catch e
                e
            end
            @test e isa GWT.AttachmentURLExpiredError && e.key == kf && e.expires == "2026-11-06T12:00:00Z" && !GWT.retryable(e)
            @test length(s3.requests) == n
            @test sprint(showerror, e) == "AttachmentURLExpiredError: attachment URL expired: the URL the gateway at " *
                "$(loopback_url(gw)) minted for $kf lived 1 s (until 2026-11-06T12:00:00Z), and this process waited 1 s " *
                "after the mint before uploading. Nothing was sent. Put the attachment again, which mints a new URL (ADR-0046)."
            # The upload outlasted the URL: still sending at its end, the client stops there rather than
            # send the rest for S3 to refuse, and does not retry; a capped URL says so.
            s3.respond = req -> req.method == "PUT" ? (sleep(4); nothing) : nothing
            for (capped, coda) in (
                    (false, ""), (
                        true, " The gateway's AWS session shortened this URL (capped): another put " *
                            "may reach a younger gateway environment, which mints a longer one.",
                    ),
                )
                double.respond = req -> req.rawpath == "/mint" ? gwtest_minted(s3, kf, 10; seconds = 1, capped) : nothing
                t = @elapsed (
                    e = try
                        GWT.put_attachment(store, kf, IOBuffer(fresh)); nothing
                    catch e
                        e
                    end
                )
                @test e isa GWT.AttachmentURLExpiredError && e.key == kf && !GWT.retryable(e) && t < 3.5
                @test !haskey(s3.objects, kf)
                head, tail = "AttachmentURLExpiredError: attachment URL expired: the upload of $kf ran ",
                    " s, past the 1 s life of the URL the gateway minted (until 2026-11-06T12:00:00Z), and S3 refuses an " *
                    "upload still running when its URL expires. Nothing was stored. Its 10 bytes need 1 KiB/s or more. " *
                    "Put the attachment again over a faster link (ADR-0046)." * coda
                msg = sprint(showerror, e)
                @test startswith(msg, head) && endswith(msg, tail) && chopsuffix(chopprefix(msg, head), tail) in ("1", "2")
                @test !occursin("X-Amz-Signature", sprint(showerror, e)) && !occursin("clock", sprint(showerror, e))
            end
            # S3 says expired well before the URL's life is out: said as such, not blamed on the link
            s3.respond = req -> req.method == "PUT" ? (403, [], s3test_error("AccessDenied", "Request has expired")) : nothing
            double.respond = req -> req.rawpath == "/mint" ? gwtest_minted(s3, kf, 10) : nothing
            e = try
                GWT.put_attachment(store, kf, IOBuffer(fresh)); nothing
            catch e
                e
            end
            @test e isa GWT.AttachmentURLExpiredError && !haskey(s3.objects, kf)
            @test sprint(showerror, e) == "AttachmentURLExpiredError: attachment URL expired: S3 refused the upload of " *
                "$kf as expired after 0 s, though the gateway gave its URL 900 s (until 2026-11-06T12:00:00Z): the gateway's " *
                "clock is off, or S3's. Nothing was stored. Put the attachment again; if this recurs, report it to the " *
                "bucket's operator (ADR-0046)."
            s3.respond = _ -> nothing
            # a gateway older than the lifetime in its reply: refused before a byte is sent
            double.respond = req -> req.rawpath == "/mint" ? gwtest_minted(s3, kf, 10; lifetime = nothing) : nothing
            n = length(s3.requests)
            e = try
                GWT.put_attachment(store, kf, IOBuffer(fresh)); nothing
            catch e
                e
            end
            @test e isa GWT.GatewayMismatchError && e.key == kf && length(s3.requests) == n
            @test sprint(showerror, e) == "GatewayMismatchError: gateway mismatch: the gateway at $(loopback_url(gw)) " *
                "minted a URL for $kf without its lifetime (\"seconds\", \"capped\"), which it gives since S3 was found " *
                "to refuse an upload still running when its URL expires. Nothing was sent. Ask the bucket's operator " *
                "to redeploy it (gateway/deploy.sh) (ADR-0046)."
            # a URL anywhere but the attachment's place in our bucket: refused before a byte is sent
            n = length(s3.requests)
            for url in ("$(s3test_endpoint(s3))/other/$kf", "$(s3test_endpoint(s3))/bkt/p/_attachments/" * "1"^64, "https://evil.example/bkt/$kf")
                double.respond = req -> req.rawpath == "/mint" ? gwtest_minted(s3, kf, 10; url) : nothing
                e = try
                    GWT.put_attachment(store, kf, IOBuffer(fresh)); nothing
                catch e
                    e
                end
                @test e isa GWT.GatewayMismatchError && e.key == kf && e.bucket == "bkt"
                @test occursin("minted a URL for $kf at $url, not at $(s3test_endpoint(s3))/bkt/$kf", sprint(showerror, e))
                @test occursin("Nothing was sent.", sprint(showerror, e))
            end
            @test length(s3.requests) == n
            # a URL with no query, or an empty one, carries no signature: refused before a byte is sent
            for (url, query) in ((nothing, false), ("$(s3test_endpoint(s3))/bkt/$kf?", false))
                double.respond = req -> req.rawpath == "/mint" ? gwtest_minted(s3, kf, 10; url, query) : nothing
                e = try
                    GWT.put_attachment(store, kf, IOBuffer(fresh)); nothing
                catch e
                    e
                end
                @test e isa GWT.GatewayMismatchError && e.key == kf && e.bucket == "bkt" && e.gateway == loopback_url(gw)
                @test sprint(showerror, e) == "GatewayMismatchError: gateway mismatch: the gateway at $(loopback_url(gw)) " *
                    "minted a URL for $kf with no query, so no signature. Nothing was sent. This gateway's mint is broken: " *
                    "ask the bucket's operator to redeploy it (gateway/deploy.sh) (ADR-0046)."
            end
            @test length(s3.requests) == n
            # the headers that make S3 check the hash, refuse an overwrite and bound the body must
            # be minted as the key and size require: else nothing is sent (ADR-0046)
            checksum = GWT.Base64.base64encode(sha256(fresh))
            without(name) = hs -> filter(kv -> first(kv) != name, hs)
            setting(name, value) = hs -> [first(kv) == name ? name => value : kv for kv in hs]
            for (edit, problem) in (
                    (without("x-amz-checksum-sha256"), "no x-amz-checksum-sha256 header, where $(repr(checksum))"),
                    (
                        setting("x-amz-checksum-sha256", GWT.Base64.base64encode(zeros(UInt8, 32))),
                        "x-amz-checksum-sha256 $(repr(GWT.Base64.base64encode(zeros(UInt8, 32)))), where $(repr(checksum))",
                    ),
                    (without("if-none-match"), "no if-none-match header, where \"*\""),
                    (setting("if-none-match", "abc"), "if-none-match \"abc\", where \"*\""),
                    (without("content-length"), "no content-length header, where \"10\""),
                    (setting("content-length", "11"), "content-length \"11\", where \"10\""),
                )
                double.respond = req -> req.rawpath == "/mint" ? gwtest_minted(s3, kf, 10; edit) : nothing
                e = try
                    GWT.put_attachment(store, kf, IOBuffer(fresh)); nothing
                catch e
                    e
                end
                @test e isa GWT.GatewayMismatchError && e.key == kf && e.bucket == "bkt"
                @test occursin(
                    "gateway mismatch: the gateway at $(loopback_url(gw)) minted the upload of $kf with $problem. " *
                        "Nothing was sent.", sprint(showerror, e)
                )
            end
            # each exactly once: a duplicate is refused even when it agrees
            for (twice, values) in (
                    (hs -> [hs; "content-length" => "11"], "(\"10\", \"11\")"),
                    (hs -> [hs; "content-length" => "10"], "(\"10\", \"10\")"),
                )
                double.respond = req -> req.rawpath == "/mint" ? gwtest_minted(s3, kf, 10; edit = twice) : nothing
                e = try
                    GWT.put_attachment(store, kf, IOBuffer(fresh)); nothing
                catch e
                    e
                end
                @test e isa GWT.GatewayMismatchError && e.key == kf && e.bucket == "bkt" && e.gateway == loopback_url(gw)
                @test sprint(showerror, e) == "GatewayMismatchError: gateway mismatch: the gateway at $(loopback_url(gw)) " *
                    "minted the upload of $kf with content-length twice $values, where once, \"10\". Nothing was sent. A " *
                    "header minted more than once leaves it to S3 which one counts, so it might not bound the upload to the " *
                    "attachment's size: this gateway is not the one ADR-0046 specifies; ask the bucket's operator to " *
                    "redeploy it (gateway/deploy.sh)."
            end
            @test length(s3.requests) == n
            # a gateway that stored it elsewhere: our bucket lacks the key after the gateway's word
            double.respond = req -> req.rawpath == "/mint" ? gwtest_json(200, "present", "already stored") : nothing
            e = try
                GWT.put_attachment(store, kf, IOBuffer(fresh)); nothing
            catch e
                e
            end
            @test e isa GWT.GatewayMismatchError && occursin("has stored the attachment $kf, and bucket bkt does not hold it", sprint(showerror, e))
            # any other upload failure is S3's, with the URL's signature left out
            double.respond = req -> req.rawpath == "/mint" ? gwtest_minted(s3, kf, 10) : nothing
            s3.respond = req -> req.method == "PUT" ? (500, [], s3test_error("InternalError", "Please try again.")) : nothing
            e = try
                GWT.put_attachment(store, kf, IOBuffer(fresh)); nothing
            catch e
                e
            end
            @test e isa TransportError && e.status == 500 && GWT.retryable(e)
            @test occursin("PUT $(s3test_endpoint(s3))/bkt/$kf: HTTP 500 InternalError", sprint(showerror, e)) && !occursin("Signature", sprint(showerror, e))
            s3.respond = _ -> nothing
            # a reply this client cannot read is refused, never guessed at
            for (body, what) in (
                    ("{\"code\": \"minted\", \"url\": \"x\", \"expires\": \"y\"}", "no \"headers\" object"),
                    ("{\"code\": \"minted\", \"expires\": \"y\", \"headers\": {\"a\": \"b\"}}", "no \"url\""),
                    ("{\"code\": \"minted\", \"url\": \"x\", \"expires\": \"y\", \"headers\": {\"a\": \"b\" \"c\": \"d\"}}", "not a flat map"),
                    ("{\"code\": \"minted\", \"url\": \"x\", \"expires\": \"y\", \"headers\": {\"A\": \"b\"}}", "not a flat map"),
                    ("{\"code\": \"minted\", \"url\": \"x\", \"expires\": \"y\", \"headers\": {}}", "an empty \"headers\" object"),
                    ("{\"code\": \"minted\", \"url\": \"x\", \"expires\": \"y\", \"seconds\": \"9\", \"capped\": false, \"headers\": {\"a\": \"b\"}}", "a \"seconds\" that is not a whole number"),
                    ("{\"code\": \"minted\", \"url\": \"x\", \"expires\": \"y\", \"seconds\": 9, \"headers\": {\"a\": \"b\"}}", "\"seconds\" without \"capped\""),
                    ("{\"code\": \"minted\", \"url\": \"x\", \"expires\": \"y\", \"seconds\": 9, \"capped\": 1, \"headers\": {\"a\": \"b\"}}", "a \"capped\" that is not true or false"),
                    ("{\"code\": \"minted\", \"url\": \"x\", \"expires\": \"y\", \"capped\": 1, \"headers\": {\"a\": \"b\"}}", "\"capped\" without \"seconds\""),
                    ("{\"code\": \"stored\"}", "with code \"stored\", neither present nor minted"),
                )
                double.respond = req -> (200, [], Vector{UInt8}(body))
                e = try
                    GWT.put_attachment(store, kf, IOBuffer(fresh)); nothing
                catch e
                    e
                end
                @test e isa TransportError && e.status == 200 && !GWT.retryable(e) && occursin(what, sprint(showerror, e))
            end
            # the mint's refusals: as for a slot, plus a gateway that predates the route
            double.respond = _ -> nothing
            double.caller = "bob@example.com"
            e = try
                GWT.put_attachment(store, kf, IOBuffer(fresh)); nothing
            catch e
                e
            end
            @test e isa WriteRefusedError && e.reason == "not_allowed" && e.key == kf
            @test occursin("refused to mint the upload of $kf for caller <unresolved> — not_allowed: bob@example.com may not write under p", sprint(showerror, e))
            double.caller = "alice@example.com"
            double.respond = req -> gwtest_json(400, "bad_request", "POST /mint is not the gateway's one route, PUT /?key=<slot key>")
            e = try
                GWT.put_attachment(store, kf, IOBuffer(fresh)); nothing
            catch e
                e
            end
            @test e isa WriteRefusedError && e.reason == "no_mint_route" && !GWT.retryable(e)
            @test occursin("the gateway at $(loopback_url(gw)) has no mint route", sprint(showerror, e))
            @test occursin("ask the bucket's operator to redeploy it (gateway/deploy.sh)", sprint(showerror, e))
            double.respond = req -> gwtest_json(502, "s3_refused", "S3 answered 403 AccessDenied to the HEAD")
            e = try
                GWT.put_attachment(store, kf, IOBuffer(fresh)); nothing
            catch e
                e
            end
            @test e.reason == "s3_refused"
            @test occursin(
                "the gateway at $(loopback_url(gw)) refused to mint the upload of $kf — s3_refused: S3 answered " *
                    "403 AccessDenied to the HEAD. S3 refused one of the gateway's own calls for the attachment — " *
                    "its HEAD, GetObjectRetention or PutObjectRetention — so the gateway's deployment is wrong and " *
                    "a retry cannot help: report it to the bucket's operator (ADR-0046).", sprint(showerror, e)
            )
            for (status, code, retry) in ((502, "s3_error", true), (413, "too_large", false), (400, "not_a_slot", false))
                double.respond = req -> gwtest_json(status, code, "the gateway's word")
                e = try
                    GWT.put_attachment(store, kf, IOBuffer(fresh)); nothing
                catch e
                    e
                end
                @test e isa TransportError && e.status == status && GWT.retryable(e) == retry
                @test occursin("HTTP $status $code: the gateway's word", sprint(showerror, e))
            end
            double.respond = _ -> nothing
            @test !haskey(s3.objects, kf)
            # the policy is checked against the attachment's prefix, not the key up to its last '/'
            nested = "p/_attachments/" * bytes2hex(sha256(b"n"))
            @test GWT.put_attachment(store, nested, IOBuffer(b"n"))
            double.policy = ["p/_attachments" => ["alice@example.com"]]
            e = try
                GWT.put_attachment(store, "p/_attachments/" * bytes2hex(sha256(b"m")), IOBuffer(b"m")); nothing
            catch e
                e
            end
            @test e isa WriteRefusedError && e.reason == "not_allowed"
            double.policy = ["p" => ["alice@example.com"]]
            # reads go to the bucket
            @test GWT.fetch_object_to(store, key, joinpath(dir, "b")) == length(bytes) && read(joinpath(dir, "b")) == bytes
        finally
            close(gw); close(s3)
            rm(dir; recursive = true)
        end
    end

    # ------------------------------------------------------------------------
    # The author (ADR-0028): the tail of the caller ARN from sts:GetCallerIdentity, fetched
    # lazily, memoized per access key id; the plain stores keep today's USER lookup.
    # ------------------------------------------------------------------------
    @testset "record_author: ENV on a plain store, the STS caller's name on a gateway store" begin
        withenv("USER" => "carol", "USERNAME" => nothing) do
            @test GWT.record_author(GWT.Testing.InMemoryObjectStore()) == "carol"
            @test GWT.record_author(S3ObjectStore("bkt"; region = "eu-north-1", credentials = GWTEST_CREDS)) == "carol"
        end
        withenv("USER" => nothing, "USERNAME" => "dave") do
            @test GWT.record_author(GWT.Testing.InMemoryObjectStore()) == "dave"
        end
        withenv("USER" => "", "USERNAME" => nothing) do
            @test GWT.record_author(GWT.Testing.InMemoryObjectStore()) === nothing
        end
        # the STS call: POST GetCallerIdentity, signed for service sts in the chain's region
        sts = LoopbackServer(gwtest_sts(GWTEST_CREDS, "eu-north-1", GWTEST_ARN))
        try
            s3 = S3ObjectStore("bkt"; region = "eu-north-1", credentials = GWTEST_CREDS)   # never called here
            store = GatewayObjectStore(
                "bkt", "https://abc.lambda-url.eu-north-1.on.aws"; region = "eu-north-1",
                credentials = GWTEST_CREDS, sts_endpoint = loopback_url(sts)
            )
            @test store.author === nothing && isempty(sts.requests)                   # nothing at construction (ADR-0019)
            withenv("USER" => "carol") do
                @test GWT.record_author(store) == "alice@example.com"                 # ENV is ignored on a gateway store
            end
            @test store.author == "alice@example.com" && store.author_key == "AKIATEST"
            req = only(sts.requests)
            @test req.method == "POST" && req.rawpath == "/" && String(copy(req.body)) == "Action=GetCallerIdentity&Version=2011-06-15"
            @test req.headers["content-type"] == "application/x-www-form-urlencoded; charset=utf-8"
            @test occursin("/eu-north-1/sts/aws4_request, SignedHeaders=content-type;host;x-amz-content-sha256;x-amz-date;x-amz-security-token,", req.headers["authorization"])
            @test req.headers["host"] == "127.0.0.1:$(sts.port)"
            # memoized: a second call makes no request; new credentials for another key id fetch again
            @test GWT.record_author(store) == "alice@example.com" && length(sts.requests) == 1
            calls = Ref(0)
            rotating = () -> (calls[] += 1; Credentials(calls[] <= 1 ? "AKIATEST" : "AKIAOTHER", "topsecret"; session_token = "session-token"))
            other = LoopbackServer(
                gwtest_sts(
                    Credentials("AKIAOTHER", "topsecret"; session_token = "session-token"), "eu-north-1",
                    "arn:aws:iam::123456789012:user/engineering/erin"
                )
            )
            try
                store2 = GatewayObjectStore(
                    "bkt", "https://abc.lambda-url.eu-north-1.on.aws"; region = "eu-north-1",
                    credentials = rotating, sts_endpoint = loopback_url(other)
                )
                # the first credentials are AKIATEST, whose signature `other` refuses: an STS failure is a TransportError
                e = try
                    GWT.record_author(store2); nothing
                catch e
                    e
                end
                @test e isa TransportError && e.status == 403 && store2.author === nothing
                @test startswith(sprint(showerror, e), "TransportError: POST http://127.0.0.1:$(other.port)/: HTTP 403")
                @test GWT.record_author(store2) == "erin"                             # an IAM user with a path: the name
                @test store2.author_key == "AKIAOTHER" && length(other.requests) == 2
                @test GWT.record_author(store2) == "erin" && length(other.requests) == 2
            finally
                close(other)
            end
            # the account root is neither a user nor an assumed role: refused here, as the gateway would
            root = LoopbackServer(gwtest_sts(GWTEST_CREDS, "eu-north-1", "arn:aws:iam::123456789012:root"))
            try
                store3 = GatewayObjectStore(
                    "bkt", "https://abc.lambda-url.eu-north-1.on.aws"; region = "eu-north-1",
                    credentials = GWTEST_CREDS, sts_endpoint = loopback_url(root)
                )
                e = try
                    GWT.record_author(store3); nothing
                catch e
                    e
                end
                @test e isa WriteRefusedError && e.reason == "not_allowed" && e.caller === nothing
                @test occursin("arn:aws:iam::123456789012:root is neither an IAM user nor an assumed role", sprint(showerror, e))
                @test store3.author === nothing
                # through create_chain, the refusal is told for the chain and slot 0, before anything is written
                mktempdir() do dir
                    chain3 = Chain("bkt", "exp/run-1"; store = store3, cache_dir = dir, assume_first_writer_wins = true)
                    e = try
                        GWT.create_chain(chain3); nothing
                    catch e
                        e
                    end
                    @test e isa WriteRefusedError && e.reason == "not_allowed" && e.slot == 0 && e.key == "exp/run-1/000000000000"
                    @test e.chain_id isa String
                    @test startswith(sprint(showerror, e), "WriteRefusedError: write refused for slot 0 of chain $(e.chain_id) at bkt/exp/run-1: ")
                end
            finally
                close(root)
            end
            # the tail rule on ARNs, as a pure function
            @test GWT.author_from_arn(GWTEST_ARN) == "alice@example.com"
            @test GWT.author_from_arn("arn:aws:iam::123456789012:user/erin") == "erin"
            @test GWT.author_from_arn("arn:aws:iam::123456789012:user/a/b/erin") == "erin"
            @test GWT.author_from_arn("arn:aws-cn:sts::123456789012:assumed-role/Role/sess") == "sess"
            for arn in ("arn:aws:iam::123456789012:root", "arn:aws:iam::123456789012:role/Role", "", "garbage")
                @test_throws WriteRefusedError GWT.author_from_arn(arn)
            end
            @test_throws "sts:GetCallerIdentity returned no Arn" GWT.author_from_sts_response(b"<x/>")
            @test_throws WriteRefusedError GWT.author_from_arn("arn:aws:iam::123456789012:user/erin\n")   # `\z`, not `\$`
        finally
            close(sts)
        end
    end

    # ------------------------------------------------------------------------
    # A commit end to end (ADR-0028, ADR-0010, ADR-0020): create_chain and commit! through
    # the gateway double into the loopback S3, the author from the STS double in every
    # record, the cap, the refusals with their evidence, and the retry loop's paths.
    # ------------------------------------------------------------------------
    @testset "create_chain and commit! through the gateway" begin
        s3 = S3TestServer(; bucket = "bkt", credentials = GWTEST_CREDS)
        double = GatewayDouble(s3, GWTEST_CREDS, "eu-north-1", "alice@example.com", ["exp" => ["alice@example.com"]], _ -> nothing)
        gw = LoopbackServer(double)
        sts = LoopbackServer(gwtest_sts(GWTEST_CREDS, "eu-north-1", GWTEST_ARN))
        mktempdir() do dir
            try
                cache_dir = joinpath(dir, "cache")
                store = GatewayObjectStore(
                    "bkt", loopback_url(gw); region = "eu-north-1", credentials = GWTEST_CREDS,
                    endpoint = s3test_endpoint(s3), path_style = true, sts_endpoint = loopback_url(sts)
                )
                # a supplied gateway store is held to the same rule as the keyword
                @test_throws "record_user = false with a gateway" Chain("bkt", "exp/run-1"; store, cache_dir, record_user = false)
                chain = Chain("bkt", "exp/run-1"; store, cache_dir, assume_first_writer_wins = true)
                @test chain isa Chain{GatewayObjectStore} && GWT.unsupported_store(chain)
                puts() = count(r -> r.method == "PUT", gw.requests)
                withenv("USER" => "carol") do
                    # create_chain: the author is fetched first, the genesis goes through the gateway, ENV is ignored
                    created = GWT.create_chain(chain)
                    @test created.slot == 0 && haskey(s3.objects, "exp/run-1/000000000000")
                    @test length(sts.requests) == 1 && puts() == 1 && !any(r -> r.method == "PUT", s3.requests)
                    genesis = GWT.Ops.decode_record(s3.objects["exp/run-1/000000000000"]; slot = 0)
                    @test genesis.client.user == "alice@example.com"
                    # commit!: the author is memoized, the record carries it, the read-back is a direct GET
                    copy = GWT.open(chain, joinpath(dir, "a"))
                    @test GWT.sync!(copy).slot == 0
                    w = GWT.write_builder(copy)
                    GWT.create_table!(w, :samples) do t
                        GWT.column!(t, :id, Int64); GWT.column!(t, :note, String); GWT.primary_key!(t, :id)
                    end
                    GWT.insert_rows!(w, :samples, [(id = 1, note = "through the gateway")])
                    done = GWT.commit!(w; comment = "gated")
                    @test done.slot == 1 && haskey(s3.objects, "exp/run-1/000000000001")
                    @test length(sts.requests) == 1 && puts() == 2
                    record = GWT.Ops.decode_record(s3.objects["exp/run-1/000000000001"]; slot = 1)
                    @test record.client.user == "alice@example.com" && record.comment == "gated"
                    put = last(filter(r -> r.method == "PUT", gw.requests))
                    @test put.query == ["key" => "exp/run-1/000000000001"] && put.body == s3.objects["exp/run-1/000000000001"]
                    # another copy reads it back through S3 alone
                    other = GWT.open(chain, joinpath(dir, "b"))
                    @test GWT.sync!(other) == (; applied = 2, slot = 1, transaction_hash = done.transaction_hash)
                    @test GWT.table(other, :samples)[1].note == "through the gateway"
                    close(other)
                    # a refusal by policy: WriteRefusedError naming the chain and the slot; nothing applied, the builder spent
                    double.caller = "bob@example.com"
                    w = GWT.write_builder(copy)
                    GWT.insert_rows!(w, :samples, [(id = 2, note = "refused")])
                    n = puts()
                    e = try
                        GWT.commit!(w); nothing
                    catch e
                        e
                    end
                    @test e isa WriteRefusedError && e.reason == "not_allowed"
                    @test (e.chain_id, e.slot, e.key, e.caller) == (created.chain_id, 2, "exp/run-1/000000000002", "alice@example.com")
                    msg = sprint(showerror, e)
                    @test startswith(
                        msg, "WriteRefusedError: write refused for slot 2 of chain $(created.chain_id) at bkt/exp/run-1: " *
                            "the gateway at http://127.0.0.1:$(gw.port) refused to fill exp/run-1/000000000002 for caller alice@example.com — not_allowed: "
                    )
                    @test occursin("ask the bucket's operator to add the name to the gateway policy", msg)
                    @test puts() == n + 1 && !haskey(s3.objects, "exp/run-1/000000000002")   # one attempt, never retried
                    @test GWT.head(copy).slot == 1 && length(GWT.table(copy, :samples)) == 1  # the copy stands at its head
                    @test_throws "this builder is spent" GWT.commit!(w)
                    # a refusal by author: the gateway sees a caller the record does not name
                    double.caller = "mallory"
                    double.policy = ["exp" => ["mallory"]]
                    w = GWT.write_builder(copy)
                    GWT.insert_rows!(w, :samples, [(id = 2, note = "mismatch")])
                    e = try
                        GWT.commit!(w); nothing
                    catch e
                        e
                    end
                    @test e isa WriteRefusedError && e.reason == "author_mismatch" && e.slot == 2 && e.caller == "alice@example.com"
                    @test occursin("author_mismatch: the record names 'alice@example.com' as client.user but the caller is 'mallory'", sprint(showerror, e))
                    double.caller = "alice@example.com"
                    double.policy = ["exp" => ["alice@example.com"]]
                    # AWS refusing the invocation before the gateway ran
                    double.respond = _ -> (403, [], Vector{UInt8}("{\"Message\":\"User: arn:aws:sts::123456789012:assumed-role/x/alice is not authorized\"}"))
                    w = GWT.write_builder(copy)
                    GWT.insert_rows!(w, :samples, [(id = 2, note = "forbidden")])
                    e = try
                        GWT.commit!(w); nothing
                    catch e
                        e
                    end
                    @test e isa WriteRefusedError && e.reason == "forbidden" && e.slot == 2
                    @test occursin("(HTTP 403 with no gateway code): User: arn:aws:sts::123456789012:assumed-role/x/alice is not authorized", sprint(showerror, e))
                    @test occursin("ask the bucket's operator for the writer permission set", sprint(showerror, e))
                    # a lost reply: the put landed, the gateway answered 502; the read-back finds our bytes and no put is repeated
                    double.respond = req -> begin
                        double.respond = _ -> nothing
                        double(req)                                       # the real put lands …
                        (502, [], gwtest_json(502, "s3_error", "reply lost")[3])   # … and the reply is lost
                    end
                    w = GWT.write_builder(copy)
                    GWT.insert_rows!(w, :samples, [(id = 2, note = "lost reply")])
                    n = puts()
                    done = GWT.commit!(w)
                    @test done.slot == 2 && puts() == n + 1 && GWT.head(copy).slot == 2
                    @test GWT.Ops.decode_record(s3.objects["exp/run-1/000000000002"]; slot = 2).client.user == "alice@example.com"
                    # a throttle: 429 is retried and the second attempt lands
                    double.respond = req -> (double.respond = _ -> nothing; (429, [], Vector{UInt8}("{\"Message\":\"Rate Exceeded.\"}")))
                    w = GWT.write_builder(copy)
                    GWT.insert_rows!(w, :samples, [(id = 3, note = "throttled once")])
                    n = puts()
                    @test GWT.commit!(w).slot == 3 && puts() == n + 2
                    # the cap: a record over 4 MiB is refused after encoding, before any put, and the copy stands
                    w = GWT.write_builder(copy)
                    GWT.insert_rows!(w, :samples, [(id = 4, note = "x"^(4 * 1024 * 1024 + 100))])
                    n = puts()
                    e = try
                        GWT.commit!(w); nothing
                    catch e
                        e
                    end
                    @test e isa WriteBuilderError
                    @test occursin(r"^WriteBuilderError: commit!\(w\): record is 4194\d{3} bytes; the cap on a GatewayObjectStore is 4194304 bytes \(4 MiB\): split the write into more than one commit$", sprint(showerror, e))
                    @test puts() == n && GWT.head(copy).slot == 3 && length(GWT.table(copy, :samples)) == 3
                    close(copy)
                    # create_chain under a prefix the policy does not allow: refused at slot 0 with the minted id
                    e = try
                        GWT.create_chain(Chain("bkt", "other/run-1"; store, cache_dir, assume_first_writer_wins = true)); nothing
                    catch e
                        e
                    end
                    @test e isa WriteRefusedError && e.reason == "not_allowed" && e.slot == 0 && e.key == "other/run-1/000000000000"
                    @test e.chain_id isa String && length(e.chain_id) == 26
                    @test startswith(sprint(showerror, e), "WriteRefusedError: write refused for slot 0 of chain $(e.chain_id) at bkt/other/run-1: ")
                    @test !haskey(s3.objects, "other/run-1/000000000000")
                    # a plain store keeps today's author: the environment, individually suppressible (ADR-0006)
                    plain = GWT.Testing.InMemoryObjectStore()
                    GWT.create_chain(Chain("bkt", "p"; store = plain, cache_dir))
                    @test GWT.Ops.decode_record(plain.objects["p/000000000000"]; slot = 0).client.user == "carol"
                    GWT.create_chain(Chain("bkt", "q"; store = plain, cache_dir, record_user = false))
                    @test GWT.Ops.decode_record(plain.objects["q/000000000000"]; slot = 0).client.user === nothing
                end
            finally
                close(gw); close(sts); close(s3)
            end
        end
    end

    # ------------------------------------------------------------------------
    # A mispaired bucket and gateway (ADR-0029, issue #63): the gateway fills the bucket of
    # its own deployment, so its 200 is believed only once the bucket this chain reads
    # holds the slot. Without that the commit would succeed into a bucket nobody reads.
    # ------------------------------------------------------------------------
    @testset "a gateway that fills another bucket: GatewayMismatchError, not a silent commit" begin
        ours = S3TestServer(; bucket = "bkt", credentials = GWTEST_CREDS)
        theirs = S3TestServer(; bucket = "other", credentials = GWTEST_CREDS)
        double = GatewayDouble(theirs, GWTEST_CREDS, "eu-north-1", "alice@example.com", ["exp" => ["alice@example.com"]], _ -> nothing)
        gw = LoopbackServer(double)
        sts = LoopbackServer(gwtest_sts(GWTEST_CREDS, "eu-north-1", GWTEST_ARN))
        mktempdir() do dir
            try
                store = GatewayObjectStore(
                    "bkt", loopback_url(gw); region = "eu-north-1", credentials = GWTEST_CREDS,
                    endpoint = s3test_endpoint(ours), path_style = true, sts_endpoint = loopback_url(sts)
                )
                key = "exp/run-1/000000000000"
                @test_throws GWT.GatewayMismatchError put_object_if_absent(store, key, gwtest_record("alice@example.com"))
                @test haskey(theirs.objects, key) && !haskey(ours.objects, key)
                chain = Chain("bkt", "exp/run-2"; store, cache_dir = joinpath(dir, "cache"), assume_first_writer_wins = true)
                e = try
                    GWT.create_chain(chain); nothing
                catch e
                    e
                end
                @test e isa GWT.GatewayMismatchError && !GWT.retryable(e)
                @test (e.slot, e.key, e.bucket, e.gateway) == (0, "exp/run-2/000000000000", "bkt", loopback_url(gw))
                @test e.chain_id isa String
                msg = sprint(showerror, e)
                @test occursin("gateway mismatch for slot 0 of chain $(e.chain_id)", msg)
                @test occursin("answered 200 created for exp/run-2/000000000000, and bucket bkt does not hold it", msg)
                @test occursin("one ChainTables.Bucket value holds both (ADR-0029)", msg)
                @test count(r -> r.method == "PUT", gw.requests) == 2                      # never retried
                # our bucket holding another record at the key is a mismatch too, not a success
                key = "exp/run-3/000000000000"
                ours.objects[key], ours.modified[key] = b"someone else's record", floor(Int64, time())
                @test_throws "and bucket bkt holds another record there (21 bytes" put_object_if_absent(
                    store, key,
                    gwtest_record("alice@example.com")
                )
            finally
                close(gw); close(sts); close(ours); close(theirs)
            end
        end
    end

    # ------------------------------------------------------------------------
    # The reply's message (issue #75): Python's json.dumps writes a character outside the BMP
    # as a surrogate pair; a malformed escape is kept, never raised over the real error.
    # ------------------------------------------------------------------------
    @testset "json_unescape: surrogate pairs joined, malformed escapes kept" begin
        @test GWT.json_unescape("a\\ud83d\\ude00b") == "a😀b"
        @test GWT.json_unescape("\\u00e9\\n\\\"") == "é\n\""
        @test GWT.json_unescape("x\\uZZZZ y") == "x\\uZZZZ y"
        @test GWT.json_unescape("lone \\ud83d end") == "lone \\ud83d end"
        @test GWT.json_unescape("\\ude00 low first") == "\\ude00 low first"
        @test GWT.json_unescape("tail\\u12") == "tail\\u12"
        @test GWT.json_unescape("\\ud83dé") == "\\ud83dé"
        @test all(isvalid, GWT.json_unescape.(["a\\ud83d\\ude00b", "lone \\ud83d end", "\\ud83dé"]))
        code, message = GWT.gateway_reply(Vector{UInt8}("{\"code\": \"not_allowed\", \"message\": \"\\ud83d\\ude00 may not \\uZZ\"}"))
        @test (code, message) == ("not_allowed", "😀 may not \\uZZ")
    end
end
