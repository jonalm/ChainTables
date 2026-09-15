# ADR-0028 — the gateway store: `Chain(…; gateway = url)`, the signed PUT to the function
# URL and its status mapping, the author from `sts:GetCallerIdentity`, the 4 MiB cap,
# `WriteRefusedError`, and a commit end to end through a loopback gateway that fills slots
# in a loopback S3 (issue #57; the contract is issue #54).
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
    policy::Vector{Pair{String,Vector{String}}}
    respond::Any                 # req -> (status, headers, body) to script a reply, or nothing
end
gwtest_json(status, code, message) = (status, ["content-type" => "application/json"],
    Vector{UInt8}("{\"code\": \"$code\", \"message\": \"$(replace(message, "\\" => "\\\\", "\"" => "\\\"", "\n" => "\\n"))\"}"))

gwtest_allowed(g::GatewayDouble, key) = any(g.policy) do (prefix, names)
    g.caller in names && (prefix == "*" || GWT.startswith_bytes(key, prefix * "/") || key == prefix)
end

function (g::GatewayDouble)(req)
    scripted = g.respond(req)
    scripted === nothing || return scripted
    refused = gwtest_check_signature(g.credentials, g.region, "lambda", req)
    refused === nothing || return refused
    req.method == "PUT" || return gwtest_json(400, "bad_request", "method $(req.method)")
    req.rawpath == "/" || return gwtest_json(400, "bad_request", "path $(req.rawpath) is not /")
    i = findfirst(kv -> kv[1] == "key", req.query)
    i === nothing && return gwtest_json(400, "bad_request", "no key")
    key = req.query[i][2]
    gwtest_allowed(g, key) || return gwtest_json(403, "not_allowed", "$(g.caller) may not write under $(dirname(key))")
    occursin(r"^(?:[^/](?:.*[^/])?/)?[0-9]{12}$", key) || return gwtest_json(400, "not_a_slot", "$key is not a slot")
    decoded = try GWT.CBOR.decode(req.body) catch e; e end
    decoded isa Dict || return gwtest_json(400, "not_cbor_map", "the body is not a CBOR map")
    user = get(get(decoded, "client", Dict()), "user", nothing)
    (user isa String && !isempty(user)) || return gwtest_json(400, "no_author", "client.user is absent")
    user == g.caller || return gwtest_json(403, "author_mismatch", "the record names '$user' as client.user but the caller is '$(g.caller)': " *
                                                                 "a client bug, or the credentials changed between the identity call and the commit; report it")
    length(req.body) <= 4 * 1024 * 1024 || return gwtest_json(413, "too_large", "$(length(req.body)) bytes")
    haskey(g.s3.objects, key) && return gwtest_json(412, "slot_taken", "$key exists")
    g.s3.objects[key] = copy(req.body)
    g.s3.modified[key] = floor(Int64, time())
    return gwtest_json(200, "created", key)
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

# A CBOR map that passes the gateway's checks: a record-shaped map naming `user`.
gwtest_record(user) = GWT.CBOR.encode(Dict{String,Any}("format_version" => 1, "client" => Dict{String,Any}("user" => user), "ops" => Any[]))

# ---------------------------------------------------------------------------
# For the live test: a store wrapper that runs a hook ahead of each put, so a competing
# commit can land between a commit's preflight and its put — the race test/chain.jl
# injects through the double's fault hook. The credentials of the `aws sso login` session
# come from `ChainTables.sso_credentials` (issue #62), tested without AWS in test/s3.jl.
# ---------------------------------------------------------------------------

mutable struct RacingGateway <: GWT.AbstractObjectStore
    const inner::GatewayObjectStore
    before_put::Any               # key -> nothing, run ahead of every put
end
GWT.is_aws(s::RacingGateway) = GWT.is_aws(s.inner)
GWT.record_cap(s::RacingGateway) = GWT.record_cap(s.inner)
GWT.record_author(s::RacingGateway) = GWT.record_author(s.inner)
GWT.fetch_object(s::RacingGateway, key::AbstractString) = fetch_object(s.inner, key)
GWT.stat_object(s::RacingGateway, key::AbstractString) = stat_object(s.inner, key)
GWT.list_objects(s::RacingGateway, prefix::AbstractString; start_after = nothing) = list_objects(s.inner, prefix; start_after)
function GWT.put_object_if_absent(s::RacingGateway, key::AbstractString, bytes)
    s.before_put(key)
    return put_object_if_absent(s.inner, key, bytes)
end

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
        @test store.function_url == url && store.base == url && store.host == "abc123.lambda-url.eu-north-1.on.aws"
        @test store.s3 isa S3ObjectStore && store.s3.bucket == "bkt" && store.s3.region == "eu-north-1"
        @test store.s3.credentials === creds && GWT.is_aws(store) && chain.record_user
        @test store.sts_endpoint == "https://sts.eu-north-1.amazonaws.com"
        @test sprint(show, store) == "GatewayObjectStore(\"bkt\", \"$url\"; region = \"eu-north-1\")"
        @test !occursin("topsecret", sprint(show, store))
        # the function URL's region is checked against the chain's when the host carries one
        @test_throws "region \"us-east-1\" disagrees with the region in the function URL" Chain("bkt", "p";
            gateway = url, region = "us-east-1", credentials = creds)
        @test Chain("bkt", "p"; gateway = url * "/", region = "eu-north-1", credentials = creds).store.function_url == url
        @test Chain("bkt", "p"; gateway = "http://127.0.0.1:9999", region = "us-east-1", credentials = creds).store.host == "127.0.0.1:9999"
        # two stores, or a record with no author, cannot be asked for
        @test_throws "gateway and store were both given; a chain has one store" Chain("bkt", "p"; gateway = url,
            store = GWT.Testing.InMemoryObjectStore(), region = "eu-north-1", credentials = creds)
        @test_throws "record_user = false with a gateway: the gateway refuses a record with no author (ADR-0028)" Chain("bkt", "p";
            gateway = url, region = "eu-north-1", credentials = creds, record_user = false)
        # the URL is scheme://host[:port] and nothing more
        for bad in ("abc123.lambda-url.eu-north-1.on.aws", url * "/put", url * "?x=1", "ftp://x")
            @test_throws "gateway $(repr(bad)) is not of the form scheme://host[:port]" Chain("bkt", "p";
                gateway = bad, region = "eu-north-1", credentials = creds)
        end
        # region and credentials resolve as for the S3 client, and the S3 half honours endpoint and path_style
        withenv("AWS_ACCESS_KEY_ID" => "AKIAX", "AWS_SECRET_ACCESS_KEY" => "s3cret", "AWS_SESSION_TOKEN" => nothing,
                "AWS_REGION" => "eu-north-1") do
            chain = Chain("bkt", "p"; gateway = url, endpoint = "http://127.0.0.1:9000", path_style = true, cache_dir = "/c")
            @test chain.store.s3.credentials == Credentials("AKIAX", "s3cret") && chain.region == "eu-north-1"
            @test chain.store.s3.base == "http://127.0.0.1:9000" && chain.store.s3.path_style && !GWT.is_aws(chain.store)
            @test GWT.unsupported_store(chain)                        # ADR-0016's gate is the S3 half's
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
            store = GatewayObjectStore("bkt", loopback_url(gw); region = "eu-north-1", credentials = GWTEST_CREDS,
                                       endpoint = s3test_endpoint(s3), path_style = true, timeout = 30)
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
            e = try put_object_if_absent(store, "p/000000000003", gwtest_record("bob@example.com")); nothing catch e; e end
            @test e isa WriteRefusedError && e.reason == "not_allowed" && e.key == "p/000000000003" && e.caller === nothing
            @test !GWT.retryable(e)
            msg = sprint(showerror, e)
            @test startswith(msg, "WriteRefusedError: write refused: the gateway at http://127.0.0.1:$(gw.port) refused to fill p/000000000003")
            @test occursin("not_allowed: bob@example.com may not write under p", msg)
            @test occursin("ask the bucket's operator to add the name to the gateway policy", msg)
            double.caller = "alice@example.com"
            e = try put_object_if_absent(store, "p/000000000003", gwtest_record("mallory")); nothing catch e; e end
            @test e isa WriteRefusedError && e.reason == "author_mismatch"
            @test occursin("author_mismatch: the record names 'mallory' as client.user but the caller is 'alice@example.com'", sprint(showerror, e))
            @test occursin("report it", sprint(showerror, e))
            wrong = GatewayObjectStore("bkt", loopback_url(gw); region = "eu-north-1", credentials = Credentials("AKIATEST", "nope"; session_token = "session-token"),
                                       endpoint = s3test_endpoint(s3), path_style = true)
            e = try put_object_if_absent(wrong, "p/000000000003", record); nothing catch e; e end
            @test e isa WriteRefusedError && e.reason == "forbidden"
            @test occursin("AWS refused the invocation", sprint(showerror, e)) && occursin("lambda:InvokeFunctionUrl and lambda:InvokeFunction", sprint(showerror, e))
            @test occursin("(HTTP 403 with no gateway code): Forbidden.", sprint(showerror, e))   # AWS's own `Message` is carried
            @test !haskey(s3.objects, "p/000000000003")
            # a client bug is a TransportError carrying the gateway's code and message, not retried
            for (k, bytes, code) in (("p/genesis", record, "not_a_slot"), ("p/000000000003", b"not cbor", "not_cbor_map"),
                                     ("p/000000000003", gwtest_record(""), "no_author"))
                e = try put_object_if_absent(store, k, bytes); nothing catch e; e end
                @test e isa TransportError && e.status == 400 && !GWT.retryable(e)
                @test occursin("HTTP 400 $code: ", sprint(showerror, e))
            end
            # the cap: the store's own guard, before any request
            n = length(gw.requests)
            @test_throws "4194305 bytes for p/000000000003 is over the gateway's 4 MiB record cap" put_object_if_absent(store, "p/000000000003", zeros(UInt8, 4 * 1024 * 1024 + 1))
            @test length(gw.requests) == n
            double.respond = req -> gwtest_json(413, "too_large", "4194305 bytes")
            e = try put_object_if_absent(store, "p/000000000003", record); nothing catch e; e end
            @test e isa TransportError && e.status == 413 && !GWT.retryable(e) && occursin("HTTP 413 too_large: 4194305 bytes", sprint(showerror, e))
            # 409, 429, 5xx and Lambda's own errors are retried by the commit layer; JSON escapes are read back
            for (status, body) in ((409, gwtest_json(409, "conflict", "S3 409")[3]), (429, Vector{UInt8}("{\"Message\":\"Rate Exceeded.\"}")),
                                   (502, gwtest_json(502, "s3_error", "S3 said \"InternalError\"\n")[3]), (503, UInt8[]), (504, Vector{UInt8}("{}")))
                double.respond = req -> (status, [], body)
                e = try put_object_if_absent(store, "p/000000000003", record); nothing catch e; e end
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
            dead = GatewayObjectStore("bkt", "http://127.0.0.1:$port"; region = "eu-north-1", credentials = GWTEST_CREDS,
                                      endpoint = s3test_endpoint(s3), path_style = true, timeout = 5)
            e = try put_object_if_absent(dead, key, record); nothing catch e; e end
            @test e isa TransportError && e.status === nothing && GWT.retryable(e)
            @test startswith(sprint(showerror, e), "TransportError: PUT http://127.0.0.1:$port/?key=p%2F000000000001: no response")
        finally
            close(gw); close(s3)
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
            store = GatewayObjectStore("bkt", "https://abc.lambda-url.eu-north-1.on.aws"; region = "eu-north-1",
                                       credentials = GWTEST_CREDS, sts_endpoint = loopback_url(sts))
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
            other = LoopbackServer(gwtest_sts(Credentials("AKIAOTHER", "topsecret"; session_token = "session-token"), "eu-north-1",
                                              "arn:aws:iam::123456789012:user/engineering/erin"))
            try
                store2 = GatewayObjectStore("bkt", "https://abc.lambda-url.eu-north-1.on.aws"; region = "eu-north-1",
                                            credentials = rotating, sts_endpoint = loopback_url(other))
                # the first credentials are AKIATEST, whose signature `other` refuses: an STS failure is a TransportError
                e = try GWT.record_author(store2); nothing catch e; e end
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
                store3 = GatewayObjectStore("bkt", "https://abc.lambda-url.eu-north-1.on.aws"; region = "eu-north-1",
                                            credentials = GWTEST_CREDS, sts_endpoint = loopback_url(root))
                e = try GWT.record_author(store3); nothing catch e; e end
                @test e isa WriteRefusedError && e.reason == "not_allowed" && e.caller === nothing
                @test occursin("arn:aws:iam::123456789012:root is neither an IAM user nor an assumed role", sprint(showerror, e))
                @test store3.author === nothing
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
                store = GatewayObjectStore("bkt", loopback_url(gw); region = "eu-north-1", credentials = GWTEST_CREDS,
                                           endpoint = s3test_endpoint(s3), path_style = true, sts_endpoint = loopback_url(sts))
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
                    e = try GWT.commit!(w); nothing catch e; e end
                    @test e isa WriteRefusedError && e.reason == "not_allowed"
                    @test (e.chain_id, e.slot, e.key, e.caller) == (created.chain_id, 2, "exp/run-1/000000000002", "alice@example.com")
                    msg = sprint(showerror, e)
                    @test startswith(msg, "WriteRefusedError: write refused for slot 2 of chain $(created.chain_id) at bkt/exp/run-1: " *
                                          "the gateway at http://127.0.0.1:$(gw.port) refused to fill exp/run-1/000000000002 for caller alice@example.com — not_allowed: ")
                    @test occursin("ask the bucket's operator to add the name to the gateway policy", msg)
                    @test puts() == n + 1 && !haskey(s3.objects, "exp/run-1/000000000002")   # one attempt, never retried
                    @test GWT.head(copy).slot == 1 && length(GWT.table(copy, :samples)) == 1  # the copy stands at its head
                    @test_throws "this builder is spent" GWT.commit!(w)
                    # a refusal by author: the gateway sees a caller the record does not name
                    double.caller = "mallory"
                    double.policy = ["exp" => ["mallory"]]
                    w = GWT.write_builder(copy)
                    GWT.insert_rows!(w, :samples, [(id = 2, note = "mismatch")])
                    e = try GWT.commit!(w); nothing catch e; e end
                    @test e isa WriteRefusedError && e.reason == "author_mismatch" && e.slot == 2 && e.caller == "alice@example.com"
                    @test occursin("author_mismatch: the record names 'alice@example.com' as client.user but the caller is 'mallory'", sprint(showerror, e))
                    double.caller = "alice@example.com"
                    double.policy = ["exp" => ["alice@example.com"]]
                    # AWS refusing the invocation before the gateway ran
                    double.respond = _ -> (403, [], Vector{UInt8}("{\"Message\":\"User: arn:aws:sts::123456789012:assumed-role/x/alice is not authorized\"}"))
                    w = GWT.write_builder(copy)
                    GWT.insert_rows!(w, :samples, [(id = 2, note = "forbidden")])
                    e = try GWT.commit!(w); nothing catch e; e end
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
                    e = try GWT.commit!(w); nothing catch e; e end
                    @test e isa WriteBuilderError
                    @test occursin(r"^WriteBuilderError: commit!\(w\): record is 4194\d{3} bytes; the cap on a GatewayObjectStore is 4194304 bytes \(4 MiB\): split the write into more than one commit$", sprint(showerror, e))
                    @test puts() == n && GWT.head(copy).slot == 3 && length(GWT.table(copy, :samples)) == 3
                    close(copy)
                    # create_chain under a prefix the policy does not allow: refused at slot 0 with the minted id
                    e = try GWT.create_chain(Chain("bkt", "other/run-1"; store, cache_dir, assume_first_writer_wins = true)); nothing catch e; e end
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
    # Live gateway (issue #60): the one test only AWS can answer for ADR-0028. Skipped
    # without CHAINTABLES_GATEWAY_URL; the other variables are then required, no defaults —
    # the run line is in test/runtests.jl. Under an `aws sso login` session it creates a
    # chain under a fresh prefix the policy lists the caller under and commits through the
    # gateway; a direct put to the bucket is denied; a commit racing for a slot loses; a
    # record naming another author, and a chain under an unlisted prefix, are refused; a
    # record over 4 MiB fails at commit before any call. Never deletes (the port has no
    # delete verb): the bucket's operator expires `<prefix>/` objects, or keeps them.
    # ------------------------------------------------------------------------
    @testset "live gateway (issue #60; skipped without CHAINTABLES_GATEWAY_URL)" begin
        url = get(ENV, "CHAINTABLES_GATEWAY_URL", "")
        if isempty(url)
            @test_skip haskey(ENV, "CHAINTABLES_GATEWAY_URL")      # see the run line in test/runtests.jl
        else
            need(name) = (v = get(ENV, name, ""); isempty(v) ? error("live gateway test: $name is not set (see test/runtests.jl)") : v)
            bucket = need("CHAINTABLES_GATEWAY_BUCKET")
            listed = need("CHAINTABLES_GATEWAY_PREFIX")              # a prefix the policy lists the caller under
            unlisted = need("CHAINTABLES_GATEWAY_UNLISTED_PREFIX")   # one it does not
            profile = need("AWS_PROFILE")
            host_region = match(r"\.lambda-url\.([a-z0-9-]+)\.on\.aws", url)
            region = get(ENV, "AWS_REGION", host_region === nothing ? "" : String(host_region.captures[1]))
            isempty(region) && error("live gateway test: AWS_REGION is not set and the URL names no region")
            credentials = GWT.sso_credentials(profile)
            run = bytes2hex(rand(UInt8, 8))
            prefix = "$listed/$run"
            mktempdir() do dir
                cache_dir = joinpath(dir, "cache")
                chain = Chain(bucket, prefix; gateway = url, region, credentials, cache_dir)
                @test chain isa Chain{GatewayObjectStore} && GWT.is_aws(chain.store)
                store = chain.store
                # the author: the session name of the SSO role from STS, under the session's own key
                author = GWT.record_author(store)
                @test author isa String && !isempty(author) && store.author_key == credentials().access_key_id
                # create_chain through the gateway; the genesis carries the author; reads are direct
                key0 = GWT.slot_key(chain, 0)
                @test fetch_object(store, key0) === nothing && stat_object(store, key0) === nothing && isempty(list_objects(store, prefix * "/"))
                created = GWT.create_chain(chain)
                @test created.slot == 0
                genesis = fetch_object(store, key0)
                @test genesis !== nothing && GWT.Ops.decode_record(genesis; slot = 0).client.user == author
                @test [m.key for m in list_objects(store, prefix * "/")] == [key0]
                # the bucket policy's Deny: a direct put by the writer is refused by S3, only the gateway fills slots
                key1 = GWT.slot_key(chain, 1)
                e = try put_object_if_absent(store.s3, key1, genesis); nothing catch e; e end
                @test e isa TransportError && e.status == 403 && occursin("AccessDenied", sprint(showerror, e))
                @test stat_object(store, key1) === nothing
                # a taken slot through the gateway is slot_taken, never an overwrite
                @test put_object_if_absent(store, key0, gwtest_record(author)) == PutOutcome(false, 412)
                @test fetch_object(store, key0) == genesis
                # a commit round-trips through two local copies; the record names the author
                a = GWT.open(chain, joinpath(dir, "a"))
                @test GWT.sync!(a).slot == 0
                w = GWT.write_builder(a)
                GWT.create_table!(w, :samples) do t
                    GWT.column!(t, :id, Int64); GWT.column!(t, :note, String); GWT.primary_key!(t, :id)
                end
                GWT.insert_rows!(w, :samples, [(id = 1, note = "live"), (id = 2, note = "gateway")])
                done = GWT.commit!(w; comment = "the live gateway test")
                @test done.slot == 1
                @test GWT.Ops.decode_record(fetch_object(store, key1); slot = 1).client.user == author
                b = GWT.open(chain, joinpath(dir, "b"))
                @test GWT.sync!(b) == (; applied = 2, slot = 1, transaction_hash = done.transaction_hash)
                @test GWT.table(b, :samples)[2].note == "gateway"
                @test GWT.verify(b; full = true) === nothing
                close(b)
                # the lost race: a's record lands while c's put is in flight (after c's preflight); c
                # gets slot_taken, reads a's record back, and loses; its head and files stand
                racing = RacingGateway(store, _ -> nothing)
                c = GWT.open(Chain(bucket, prefix; store = racing, cache_dir), joinpath(dir, "c"))
                @test GWT.sync!(c).slot == 1
                wa = GWT.write_builder(a)
                GWT.insert_rows!(wa, :samples, [(id = 3, note = "from a")])
                wc = GWT.write_builder(c)
                GWT.insert_rows!(wc, :samples, [(id = 4, note = "from c")])
                ra = Ref{Any}(nothing)
                racing.before_put = key -> (racing.before_put = _ -> nothing; ra[] = GWT.commit!(wa); nothing)
                e = try GWT.commit!(wc); nothing catch e; e end
                @test ra[] !== nothing && ra[].slot == 2
                @test e isa LostRaceError && (e.chain_id, e.slot, e.transaction_hash) == (created.chain_id, 2, ra[].transaction_hash)
                @test GWT.head(c).slot == 1 && length(GWT.table(c, :samples)) == 2
                @test GWT.sync!(c).slot == 2 && [r.note for r in GWT.table(c, :samples)] == ["live", "gateway", "from a"]
                @test_throws "this builder is spent" GWT.commit!(wc)
                # a record naming another author is refused as author_mismatch; nothing lands
                key3 = GWT.slot_key(chain, 3)
                e = try put_object_if_absent(store, key3, gwtest_record(author * ".impostor")); nothing catch e; e end
                @test e isa WriteRefusedError && e.reason == "author_mismatch" && e.key == key3 && e.caller == author
                @test occursin("author_mismatch: the record names '$author.impostor' as client.user but the caller is '$author'", sprint(showerror, e))
                @test stat_object(store, key3) === nothing
                # a chain under a prefix the policy does not list the caller under: not_allowed at slot 0
                denied = Chain(bucket, "$unlisted/$run"; gateway = url, region, credentials, cache_dir)
                e = try GWT.create_chain(denied); nothing catch e; e end
                @test e isa WriteRefusedError && e.reason == "not_allowed" && e.slot == 0 && e.caller == author
                @test e.key == GWT.slot_key(denied, 0) && stat_object(denied.store, e.key) === nothing
                @test startswith(sprint(showerror, e), "WriteRefusedError: write refused for slot 0 of chain $(e.chain_id) at $bucket/$unlisted/$run: ")
                @test occursin("not_allowed: ", sprint(showerror, e)) && occursin("ask the bucket's operator to add the name to the gateway policy", sprint(showerror, e))
                # the cap: a record over 4 MiB is refused at commit before any put; the copy stands at its head
                # (c's store is the wrapper, and the message names the store it was asked about)
                puts = Ref(0)
                racing.before_put = _ -> (puts[] += 1; nothing)
                w = GWT.write_builder(c)
                GWT.insert_rows!(w, :samples, [(id = 5, note = "x"^(4 * 1024 * 1024 + 100))])
                e = try GWT.commit!(w); nothing catch e; e end
                @test e isa WriteBuilderError && occursin("the cap on a RacingGateway is 4194304 bytes (4 MiB)", sprint(showerror, e))
                @test puts[] == 0 && GWT.head(c).slot == 2 && stat_object(store, key3) === nothing
                close(a); close(c)
            end
        end
    end
end
