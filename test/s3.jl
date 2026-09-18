# #34 step 9 — ADR-0010, ADR-0016, ADR-0019, ADR-0020: the SigV4 signer against AWS's
# worked examples, the URL and endpoint rules, credential and region resolution, the four
# verbs against an in-process HTTP server that checks every signature, the backend gate
# end to end, and the one live test (issue #6; skipped without credentials).
using Sockets
using SHA: sha256
using ChainTables: Chain, Credentials, S3ObjectStore, PutOutcome, ObjectMeta, TransportError, UnsupportedStoreError,
    fetch_object, put_object_if_absent, stat_object, list_objects
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

const S3TEST_CREDS = Credentials("AKIAIOSFODNN7EXAMPLE", "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY")
const S3TEST_EMPTY = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"   # sha256 of nothing

@testset "s3" begin
    # ------------------------------------------------------------------------
    # The signer against AWS's worked examples (ADR-0010): the one check against the
    # standard rather than against ourselves. Access key AKIAIOSFODNN7EXAMPLE, bucket
    # examplebucket, us-east-1, 2013-05-24T00:00:00Z.
    # ------------------------------------------------------------------------
    @testset "SigV4: AWS's worked examples" begin
        date = "20130524T000000Z"
        host = "host" => "examplebucket.s3.amazonaws.com"
        # GET object with a Range header
        got = S3T.sign_request(S3TEST_CREDS, "us-east-1", "GET", "/test.txt", [],
                               [host, "range" => "bytes=0-9", "x-amz-content-sha256" => S3TEST_EMPTY, "x-amz-date" => date],
                               S3TEST_EMPTY, date)
        @test got.canonical_request == "GET\n/test.txt\n\nhost:examplebucket.s3.amazonaws.com\nrange:bytes=0-9\n" *
              "x-amz-content-sha256:$S3TEST_EMPTY\nx-amz-date:$date\n\nhost;range;x-amz-content-sha256;x-amz-date\n$S3TEST_EMPTY"
        @test got.string_to_sign == "AWS4-HMAC-SHA256\n$date\n20130524/us-east-1/s3/aws4_request\n" *
              "7344ae5b7ee6c3e7e6b0fe0640412a37625d1fbfff95c48bbb2dc43964946972"
        @test got.signature == "f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41"
        @test got.authorization == "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request, " *
              "SignedHeaders=host;range;x-amz-content-sha256;x-amz-date, Signature=$(got.signature)"
        # PUT object: a `$` in the key, encoded once; a Date header among the signed
        body_hash = bytes2hex(sha256("Welcome to Amazon S3."))
        @test body_hash == "44ce7dd67c959e0d3524ffac1771dfbba87d2b6b4b4e99e42034a8b803f8b072"
        @test S3T.uri_encode("test\$file.text"; keep_slash = true) == "test%24file.text"
        got = S3T.sign_request(S3TEST_CREDS, "us-east-1", "PUT", "/test%24file.text", [],
                               ["date" => "Fri, 24 May 2013 00:00:00 GMT", host, "x-amz-content-sha256" => body_hash,
                                "x-amz-date" => date, "x-amz-storage-class" => "REDUCED_REDUNDANCY"], body_hash, date)
        @test got.signature == "98ad721746da40c64f1a55b78f14c238d841ea1380cd77a1b5971af0ece108bd"
        # GET bucket lifecycle: a query parameter with no value
        got = S3T.sign_request(S3TEST_CREDS, "us-east-1", "GET", "/", ["lifecycle" => ""],
                               [host, "x-amz-content-sha256" => S3TEST_EMPTY, "x-amz-date" => date], S3TEST_EMPTY, date)
        @test occursin("\nlifecycle=\n", got.canonical_request)
        @test got.signature == "fea454ca298b7da1c68078a5d1bdbfbbe0d65c699e0f91ac7a200a0136783543"
        # GET bucket (list objects): two query parameters, sorted
        got = S3T.sign_request(S3TEST_CREDS, "us-east-1", "GET", "/", ["prefix" => "J", "max-keys" => "2"],
                               [host, "x-amz-content-sha256" => S3TEST_EMPTY, "x-amz-date" => date], S3TEST_EMPTY, date)
        @test occursin("\nmax-keys=2&prefix=J\n", got.canonical_request)
        @test got.signature == "34b48302e7b5fa45bde8084f4b7868a86f0a534bc59db6670ed5711ef69dc6f7"
        # header names are lowercased and values trimmed before signing; the order is by name
        mixed = S3T.sign_request(S3TEST_CREDS, "us-east-1", "GET", "/test.txt", [],
                                 ["X-Amz-Date" => date, "Range" => "  bytes=0-9 ", "x-amz-content-sha256" => S3TEST_EMPTY, "Host" => host[2]],
                                 S3TEST_EMPTY, date)
        @test mixed.signature == "f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41"
    end

    @testset "encoding, query strings and dates" begin
        @test S3T.uri_encode("a-b_c.d~e") == "a-b_c.d~e"
        @test S3T.uri_encode("p/000000000001"; keep_slash = true) == "p/000000000001"
        @test S3T.uri_encode("p/000000000001") == "p%2F000000000001"
        @test S3T.uri_encode("a b+c&d=e") == "a%20b%2Bc%26d%3De"
        @test S3T.uri_encode("é/ü"; keep_slash = true) == "%C3%A9/%C3%BC"
        @test S3T.uri_encode("*") == "%2A"                       # not unreserved, unlike encodeURIComponent
        @test S3T.canonical_query(["b" => "2", "a" => "x y", "c" => ""]) == "a=x%20y&b=2&c="
        @test S3T.query_string([]) == "" && S3T.query_string(["list-type" => "2"]) == "?list-type=2"
        @test S3T.amz_date(0) == "19700101T000000Z"
        @test S3T.amz_date(1369353600) == "20130524T000000Z"
        @test S3T.amz_date(951782400) == "20000229T000000Z"        # a leap day of a leap century
        @test S3T.amz_date(1700000000) == "20231114T221320Z"
        for t in (0, 86399, 951782400, 1700000000, 4102444800)      # the civil algorithms round-trip
            y, m, d = S3T.civil_from_days(fld(t, 86400))
            @test S3T.days_from_civil(y, m, d) * 86400 + mod(t, 86400) == t
        end
        @test S3T.parse_http_date("Wed, 12 Oct 2009 17:50:00 GMT") == 1255369800
        @test S3T.parse_iso_date("2009-10-12T17:50:00.000Z") == 1255369800
        @test S3T.parse_iso_date("2009-10-12T17:50:00Z") == 1255369800
        @test_throws "cannot parse the Last-Modified header" S3T.parse_http_date("yesterday")
        @test_throws "cannot parse the LastModified value" S3T.parse_iso_date("2009-10-12")
        @test S3T.xml_unescape("a&amp;b&lt;c&gt;d&quot;e&apos;f&#65;&#x42;") == "a&b<c>d\"e'fAB"
        @test S3T.xml_unescape("plain") == "plain"
    end

    # ------------------------------------------------------------------------
    # Credentials and region resolve at construction (ADR-0019, ADR-0010)
    # ------------------------------------------------------------------------
    @testset "credentials: environment, value, callable; the secret is never shown" begin
        withenv("AWS_ACCESS_KEY_ID" => "AKIAX", "AWS_SECRET_ACCESS_KEY" => "s3cret", "AWS_SESSION_TOKEN" => nothing) do
            c = S3T.credentials_from_env()
            @test (c.access_key_id, c.secret_access_key, c.session_token) == ("AKIAX", "s3cret", nothing)
            @test S3T.resolve_credentials(nothing) == c
        end
        withenv("AWS_ACCESS_KEY_ID" => "AKIAX", "AWS_SECRET_ACCESS_KEY" => "s3cret", "AWS_SESSION_TOKEN" => "tok") do
            @test S3T.credentials_from_env().session_token == "tok"
        end
        withenv("AWS_ACCESS_KEY_ID" => nothing, "AWS_SECRET_ACCESS_KEY" => "s3cret") do
            @test_throws "AWS_ACCESS_KEY_ID is not set" S3T.credentials_from_env()
        end
        withenv("AWS_ACCESS_KEY_ID" => "", "AWS_SECRET_ACCESS_KEY" => nothing) do
            @test_throws "AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY is not set" S3T.credentials_from_env()
            @test_throws "aws-vault exec" S3T.resolve_credentials(nothing)
        end
        c = Credentials("id", "secret"; session_token = "tok")
        @test S3T.resolve_credentials(c) === c
        @test S3T.resolve_credentials((; access_key_id = "id", secret_access_key = "secret")) == Credentials("id", "secret")
        @test S3T.resolve_credentials((; access_key_id = "id", secret_access_key = "secret", session_token = "t")) ==
              Credentials("id", "secret"; session_token = "t")
        calls = Ref(0)
        supplier = () -> (calls[] += 1; Credentials("id$(calls[])", "secret"))
        @test S3T.resolve_credentials(supplier) === supplier                  # a callable stays a callable …
        @test calls[] == 1                                                    # … but is called once now, to fail fast
        store = S3ObjectStore("bkt"; region = "eu-north-1", credentials = supplier)
        @test S3T.current_credentials(store).access_key_id == "id2"
        @test S3T.current_credentials(store).access_key_id == "id3"           # and again before every request
        @test_throws "credentials must be a ChainTables.Credentials" S3T.resolve_credentials(() -> "nope")
        @test_throws "credentials is a Int64, which is neither" S3T.resolve_credentials(1)
        @test sprint(show, c) == "Credentials(\"id\", <redacted>; session_token = <redacted>)"
        @test sprint(show, Credentials("id", "secret")) == "Credentials(\"id\", <redacted>)"
    end

    # ------------------------------------------------------------------------
    # sso_credentials (ADR-0028, issue #62): the CLI's cached `aws sso login` session as a
    # callable — parsed from `aws configure export-credentials --format env-no-export`,
    # re-run only near expiry. The CLI is a fake here; nothing reaches AWS.
    # ------------------------------------------------------------------------
    @testset "sso_credentials: the export parsed, cached, refreshed near expiry, refusals" begin
        t0 = 1255369800                                                       # 2009-10-12T17:50:00Z
        env(id, exp) = "AWS_ACCESS_KEY_ID=$id\nAWS_SECRET_ACCESS_KEY=s3cret\nAWS_SESSION_TOKEN=tok\nAWS_CREDENTIAL_EXPIRATION=$exp\n"
        # the parse: the four variables, the expiry as epoch seconds in Z, ±hh:mm and fractional forms
        c, expiry = S3T.parse_export_credentials(env("AKIA1", "2009-10-12T17:50:00Z"))
        @test c == Credentials("AKIA1", "s3cret"; session_token = "tok") && expiry == t0
        @test S3T.parse_export_credentials(env("AKIA1", "2009-10-12T17:50:00.123Z"))[2] == t0
        @test S3T.parse_export_credentials(env("AKIA1", "2009-10-12T19:50:00+02:00"))[2] == t0
        @test S3T.parse_export_credentials(env("AKIA1", "2009-10-12T12:20:00-05:30"))[2] == t0
        @test S3T.parse_export_credentials("AWS_ACCESS_KEY_ID=a\nAWS_SECRET_ACCESS_KEY=b\n") == (Credentials("a", "b"), Inf)
        @test S3T.parse_export_credentials("AWS_ACCESS_KEY_ID=a\r\nAWS_SECRET_ACCESS_KEY=b=c\r\n")[1] == Credentials("a", "b=c")
        @test_throws "cannot parse AWS_CREDENTIAL_EXPIRATION \"2009-10-12\"" S3T.parse_export_credentials(env("a", "2009-10-12"))
        @test_throws "printed no AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY" S3T.parse_export_credentials("AWS_ACCESS_KEY_ID=a\n")
        @test_throws "printed no AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY" S3T.parse_export_credentials("")
        # the callable: the fake exporter is run once, then again only within the margin of expiry
        runs = String[]
        clock = Ref(0.0)
        fake(exp) = profile -> (push!(runs, profile); exp === nothing ?
            "AWS_ACCESS_KEY_ID=AKIA$(length(runs))\nAWS_SECRET_ACCESS_KEY=s3cret\n" : env("AKIA$(length(runs))", exp))
        far = S3T.parse_export_credentials(env("x", "2009-10-12T17:50:00Z"))[2]
        clock[] = far - 3600                                                  # an hour before expiry
        get_credentials = S3T.sso_credentials("team"; exporter = fake("2009-10-12T17:50:00Z"), now = () -> clock[])
        @test get_credentials() == Credentials("AKIA1", "s3cret"; session_token = "tok") && runs == ["team"]
        @test get_credentials().access_key_id == "AKIA1" && length(runs) == 1  # cached: the CLI is not run again
        clock[] = far - 299                                                   # inside the five-minute margin
        @test get_credentials().access_key_id == "AKIA2" && length(runs) == 2  # refreshed
        clock[] = far - 301
        @test get_credentials().access_key_id == "AKIA2" && length(runs) == 2  # the fresh export is cached in turn
        # no expiry printed (an IAM user's static keys): exported once, never again
        static = S3T.sso_credentials("static"; exporter = fake(nothing), now = () -> clock[])
        @test static().access_key_id == "AKIA3" && static().access_key_id == "AKIA3" && length(runs) == 3
        # the callable is what Chain takes as credentials, and resolve_credentials runs it once now
        @test S3T.resolve_credentials(get_credentials) === get_credentials
        store = S3ObjectStore("bkt"; region = "eu-north-1", credentials = get_credentials)
        @test S3T.current_credentials(store).access_key_id == "AKIA2"
        # the refusals name the login command; a failed export carries the CLI's own text
        failing = S3T.sso_credentials("team"; exporter = _ -> error("The SSO session associated with this profile has expired"))
        @test_throws "aws sso login --profile team" failing()
        @test_throws "--use-device-code" failing()
        @test_throws "The SSO session associated with this profile has expired" failing()
        @test_throws "aws configure export-credentials --profile team printed no" S3T.sso_credentials("team"; exporter = _ -> "")()
        @test_throws ArgumentError S3T.sso_credentials("")
        @test_throws "profile must not be empty" S3T.sso_credentials("")
        @test !occursin("secret", sprint(show, store))
    end

    # ------------------------------------------------------------------------
    # sso_login (ADR-0029, issue #63): `aws sso login` from Julia, always asked for. The
    # runner is a fake; `sso_credentials(…; login = true)` logs in once, and only in an
    # interactive session.
    # ------------------------------------------------------------------------
    @testset "sso_login: the command line, the failure; login = true retries once, interactively only" begin
        ran = Cmd[]
        @test S3T.sso_login("team"; runner = cmd -> push!(ran, cmd)) === nothing
        @test S3T.sso_login("team"; device_code = true, runner = cmd -> push!(ran, cmd)) === nothing
        @test [c.exec for c in ran] == [["aws", "sso", "login", "--profile", "team"],
                                        ["aws", "sso", "login", "--profile", "team", "--use-device-code"]]
        @test_throws "aws sso login --profile team failed: the AWS CLI (aws) is not on PATH" S3T.sso_login("team";
            runner = _ -> error("the AWS CLI (aws) is not on PATH"))
        @test_throws "aws sso login --profile team --use-device-code failed:" S3T.sso_login("team"; device_code = true,
            runner = cmd -> run(`false`))
        @test_throws "sso_login: profile must not be empty" S3T.sso_login("")
        # login = true, interactive: an export failure logs in once and exports again
        good = "AWS_ACCESS_KEY_ID=AKIA1\nAWS_SECRET_ACCESS_KEY=s3cret\n"
        exports, logins = Ref(0), String[]
        expired_once = _ -> (exports[] += 1) == 1 ? error("The SSO session has expired") : good
        get_credentials = S3T.sso_credentials("team"; login = true, exporter = expired_once,
                                              login_with = p -> push!(logins, p), interactive = () -> true)
        @test get_credentials().access_key_id == "AKIA1" && exports[] == 2 && logins == ["team"]
        @test get_credentials().access_key_id == "AKIA1" && exports[] == 2 && logins == ["team"]      # cached; no second login
        # a second failure raises as without login, after exactly one login
        empty!(logins)
        still = S3T.sso_credentials("team"; login = true, exporter = _ -> error("The SSO session has expired"),
                                    login_with = p -> push!(logins, p), interactive = () -> true)
        @test_throws "aws sso login --profile team" still()
        @test logins == ["team"]
        # a failed login is reported, and the export is not run again
        exports[] = 0
        nologin = S3T.sso_credentials("team"; login = true, exporter = _ -> (exports[] += 1; error("expired")),
                                      login_with = _ -> error("aws sso login --profile team failed: cancelled"), interactive = () -> true)
        @test_throws "aws sso login --profile team failed: cancelled" nologin()
        @test exports[] == 1
        # not interactive: login = true changes nothing — it raises rather than block the run
        empty!(logins)
        batch = S3T.sso_credentials("team"; login = true, exporter = _ -> error("The SSO session has expired"),
                                    login_with = p -> push!(logins, p), interactive = () -> false)
        @test_throws "The SSO session has expired" batch()
        @test isempty(logins)
        # login = false, the default: never, interactive or not
        default = S3T.sso_credentials("team"; exporter = _ -> error("expired"), login_with = p -> push!(logins, p), interactive = () -> true)
        @test_throws "aws sso login --profile team" default()
        @test isempty(logins)
    end

    @testset "region: the keyword, else AWS_REGION, else AWS_DEFAULT_REGION, never guessed" begin
        withenv("AWS_REGION" => "us-east-1", "AWS_DEFAULT_REGION" => "us-west-2") do
            @test S3T.resolve_region("eu-north-1") == "eu-north-1"
            @test S3T.resolve_region(nothing) == "us-east-1"
        end
        withenv("AWS_REGION" => nothing, "AWS_DEFAULT_REGION" => "us-west-2") do
            @test S3T.resolve_region(nothing) == "us-west-2"
        end
        withenv("AWS_REGION" => nothing, "AWS_DEFAULT_REGION" => "") do
            @test_throws "region is required by the S3 client — SigV4 signs it" S3T.resolve_region(nothing)
        end
    end

    # ------------------------------------------------------------------------
    # URL forms and what counts as AWS (ADR-0010, ADR-0016)
    # ------------------------------------------------------------------------
    @testset "URLs: virtual-hosted by default, path-style on request, endpoints, the AWS suffix test" begin
        creds = Credentials("id", "secret")
        s = S3ObjectStore("bkt"; region = "eu-north-1", credentials = creds)
        @test (s.host, s.base) == ("bkt.s3.eu-north-1.amazonaws.com", "https://bkt.s3.eu-north-1.amazonaws.com")
        @test S3T.object_path(s, "p/000000000001") == "/p/000000000001"
        @test S3T.is_aws(s) && s.endpoint === nothing && s.timeout == 60
        @test sprint(show, s) == "S3ObjectStore(\"bkt\"; region = \"eu-north-1\")"
        s = S3ObjectStore("bkt"; region = "eu-north-1", credentials = creds, path_style = true)
        @test (s.host, s.base) == ("s3.eu-north-1.amazonaws.com", "https://s3.eu-north-1.amazonaws.com")
        @test S3T.object_path(s, "p/000000000001") == "/bkt/p/000000000001"
        @test S3T.is_aws(s)
        # a spelled-out AWS endpoint is AWS: FIPS, dual-stack, GovCloud, China
        for endpoint in ("https://s3-fips.us-gov-west-1.amazonaws.com", "https://s3.dualstack.eu-north-1.amazonaws.com",
                         "https://s3.cn-north-1.amazonaws.com.cn", "HTTPS://S3.EU-NORTH-1.AMAZONAWS.COM:443/")
            s = S3ObjectStore("bkt"; region = "eu-north-1", credentials = creds, endpoint)
            @test S3T.is_aws(s)
            @test s.endpoint == endpoint
        end
        s = S3ObjectStore("bkt"; region = "eu-north-1", credentials = creds, endpoint = "HTTPS://S3.EU-NORTH-1.AMAZONAWS.COM:443/")
        @test (s.host, s.base) == ("bkt.s3.eu-north-1.amazonaws.com", "https://bkt.s3.eu-north-1.amazonaws.com")   # default port dropped
        # anything else is not, including look-alikes
        for endpoint in ("https://minio.local:9000", "http://127.0.0.1:9000", "https://r2.cloudflarestorage.com",
                         "https://amazonaws.com", "https://evil-amazonaws.com", "https://amazonaws.com.example.org")
            s = S3ObjectStore("bkt"; region = "eu-north-1", credentials = creds, endpoint)
            @test !S3T.is_aws(s)
        end
        s = S3ObjectStore("bkt"; region = "eu-north-1", credentials = creds, endpoint = "https://minio.local:9000")
        @test (s.host, s.base) == ("bkt.minio.local:9000", "https://bkt.minio.local:9000")
        @test sprint(show, s) == "S3ObjectStore(\"bkt\"; region = \"eu-north-1\", endpoint = \"https://minio.local:9000\")"
        s = S3ObjectStore("bkt"; region = "eu-north-1", credentials = creds, endpoint = "http://127.0.0.1:9000", path_style = true)
        @test (s.host, s.base) == ("127.0.0.1:9000", "http://127.0.0.1:9000")
        @test S3T.object_path(s, "") == "/bkt/"
        @test_throws "endpoint \"minio.local:9000\" is not of the form scheme://host[:port]" S3ObjectStore("bkt"; region = "r", credentials = creds, endpoint = "minio.local:9000")
        @test_throws "not of the form scheme://host[:port]" S3ObjectStore("bkt"; region = "r", credentials = creds, endpoint = "https://minio.local/bkt")
        @test_throws "not of the form scheme://host[:port]" S3ObjectStore("bkt"; region = "r", credentials = creds, endpoint = "ftp://minio.local")
        @test_throws "bucket name \"my.bucket\" contains a dot, which breaks certificate matching" S3ObjectStore("my.bucket"; region = "r", credentials = creds)
        @test_throws "the bucket name is empty" S3ObjectStore(""; region = "r", credentials = creds)
        @test_throws "timeout is 0" S3ObjectStore("bkt"; region = "r", credentials = creds, timeout = 0)
    end

    @testset "Chain: store = nothing is the S3 client, resolved now, no I/O (ADR-0019)" begin
        withenv("AWS_ACCESS_KEY_ID" => "AKIAX", "AWS_SECRET_ACCESS_KEY" => "s3cret", "AWS_SESSION_TOKEN" => nothing,
                "AWS_REGION" => nothing, "AWS_DEFAULT_REGION" => nothing) do
            chain = Chain("bkt", "p"; region = "eu-north-1", cache_dir = "/c")
            @test chain isa Chain{S3ObjectStore}
            @test chain.credentials == Credentials("AKIAX", "s3cret") && chain.region == "eu-north-1"
            @test chain.store.bucket == "bkt" && chain.store.region == "eu-north-1" && chain.store.credentials == chain.credentials
            @test S3T.is_aws(chain.store) && !chain.assume_first_writer_wins
            @test sprint(show, chain) == "Chain(\"bkt\", \"p\"; store = S3ObjectStore)"
            @test_throws "region is required by the S3 client" Chain("bkt", "p")
            @test_throws "bucket name \"my.bucket\" contains a dot, which breaks certificate matching" Chain("my.bucket", "p"; region = "eu-north-1")
            chain = Chain("bkt", "p"; region = "eu-north-1", endpoint = "https://minio.local:9000", path_style = true,
                          credentials = Credentials("id", "secret"))
            @test chain.credentials == Credentials("id", "secret") && chain.endpoint == "https://minio.local:9000"
            @test chain.store.path_style && !S3T.is_aws(chain.store)
        end
        withenv("AWS_ACCESS_KEY_ID" => nothing, "AWS_SECRET_ACCESS_KEY" => nothing, "AWS_REGION" => "eu-north-1") do
            @test_throws "AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY is not set" Chain("bkt", "p")
            @test Chain("bkt", "p"; credentials = Credentials("id", "secret")).region == "eu-north-1"
        end
    end

    # ------------------------------------------------------------------------
    # The four verbs over the wire (ADR-0010, ADR-0019): against the loopback server,
    # which recomputes every signature. Absent is nothing, failure raises, one request
    # per call, `If-None-Match: *` bare and signed.
    # ------------------------------------------------------------------------
    @testset "the four verbs against a loopback S3" begin
        creds = Credentials("AKIATEST", "topsecret"; session_token = "session-token")
        server = S3TestServer(; bucket = "bkt", credentials = creds)
        try
            store = S3ObjectStore("bkt"; region = "eu-north-1", credentials = creds, endpoint = s3test_endpoint(server),
                                  path_style = true, timeout = 30)
            key = "p/000000000001"
            @test fetch_object(store, key) === nothing
            @test stat_object(store, key) === nothing
            @test put_object_if_absent(store, key, b"record one") == PutOutcome(true, 200)
            @test put_object_if_absent(store, key, b"record two") == PutOutcome(false, 412)   # refused, never overwritten
            @test fetch_object(store, key) == b"record one"
            @test server.objects[key] == b"record one"
            meta = stat_object(store, key)
            @test meta.key == key && meta.size == 10 && abs(meta.modified - time()) < 60
            # what went over the wire
            puts = filter(r -> r.method == "PUT", server.requests)
            @test length(puts) == 2
            @test all(r -> r.headers["if-none-match"] == "*", puts)                # the bare asterisk (ADR-0016 rule 3)
            @test all(r -> r.headers["content-length"] == "10", puts)
            @test all(r -> r.headers["x-amz-security-token"] == "session-token", server.requests)
            @test all(r -> occursin("x-amz-security-token", r.headers["authorization"]), server.requests)
            @test all(r -> occursin("SignedHeaders=host;if-none-match;x-amz-content-sha256;x-amz-date;x-amz-security-token,", r.headers["authorization"]), puts)
            @test all(r -> r.headers["host"] == "127.0.0.1:$(server.port)", server.requests)
            @test all(r -> r.rawpath == "/bkt/p/000000000001", server.requests)
            @test count(r -> r.method == "HEAD", server.requests) == 2 && count(r -> r.method == "GET", server.requests) == 2
            # keys are encoded once, and decode on the far side
            odd = "p/a b\$c/é"
            @test put_object_if_absent(store, odd, b"x").created
            @test server.requests[end].rawpath == "/bkt/p/a%20b%24c/%C3%A9" && haskey(server.objects, odd)
            @test fetch_object(store, odd) == b"x"
            # a listing: by prefix, by bytes, after a key, across pages, keys unescaped
            put_object_if_absent(store, "p/000000000002", b"two")
            put_object_if_absent(store, "p/000000000003", b"three")
            put_object_if_absent(store, "q/x&y<z", b"amp")
            listed = list_objects(store, "p/")
            @test sort([m.key for m in listed]) == [key, "p/000000000002", "p/000000000003", odd]
            @test Dict(m.key => m.size for m in listed)["p/000000000003"] == 5
            @test all(m -> abs(m.modified - time()) < 60, listed)
            @test [m.key for m in list_objects(store, "p/0"; start_after = "p/000000000001")] == ["p/000000000002", "p/000000000003"]
            @test [m.key for m in list_objects(store, "q/")] == ["q/x&y<z"]
            @test isempty(list_objects(store, "z"))
            @test server.requests[end].query == ["list-type" => "2", "prefix" => "z"]
            server.page_size = 2
            n = length(server.requests)
            @test length(list_objects(store, "p/")) == 4
            @test length(server.requests) - n == 2                              # two pages, two requests, no retry
            @test server.requests[end].query == ["continuation-token" => "3", "list-type" => "2", "prefix" => "p/"]   # canonical order
            server.page_size = 1000
            # a client signing with the wrong secret is refused by the server, and that raises
            wrong = S3ObjectStore("bkt"; region = "eu-north-1", credentials = Credentials("AKIATEST", "nope"; session_token = "session-token"),
                                  endpoint = s3test_endpoint(server), path_style = true)
            e = try fetch_object(wrong, key); nothing catch e; e end
            @test e isa TransportError && e.status == 403 && !S3T.retryable(e)
            @test occursin("HTTP 403 SignatureDoesNotMatch: expected", sprint(showerror, e))
            @test startswith(sprint(showerror, e), "TransportError: GET http://127.0.0.1:$(server.port)/bkt/p/000000000001: HTTP 403")
            # the bucket in the URL is the store's; a wrong region changes the signature
            other = S3ObjectStore("bkt"; region = "us-east-1", credentials = creds, endpoint = s3test_endpoint(server), path_style = true)
            e = try fetch_object(other, key); nothing catch e; e end
            @test e isa TransportError && e.status == 400 && !S3T.retryable(e)
            @test occursin("HTTP 400 AuthorizationHeaderMalformed: the region 'us-east-1' is wrong", sprint(showerror, e))
            # without a session token, none is sent or signed
            plain = S3TestServer(; bucket = "bkt", credentials = Credentials("AKIATEST", "topsecret"))
            try
                s2 = S3ObjectStore("bkt"; region = "eu-north-1", credentials = Credentials("AKIATEST", "topsecret"),
                                   endpoint = s3test_endpoint(plain), path_style = true)
                @test put_object_if_absent(s2, "k", b"v").created && fetch_object(s2, "k") == b"v"
                @test all(r -> !haskey(r.headers, "x-amz-security-token"), plain.requests)
                @test all(r -> !occursin("security-token", r.headers["authorization"]), plain.requests)
            finally
                close(plain)
            end
        finally
            close(server)
        end
    end

    @testset "failures: a status is a TransportError with it; no response is one without (ADR-0010)" begin
        creds = Credentials("AKIATEST", "topsecret")
        server = S3TestServer(; bucket = "bkt", credentials = creds)
        try
            store = S3ObjectStore("bkt"; region = "eu-north-1", credentials = creds, endpoint = s3test_endpoint(server), path_style = true)
            server.respond = req -> req.method == "PUT" ?
                (500, [], s3test_error("InternalError", "We encountered an internal error. Please try again.")) : nothing
            e = try put_object_if_absent(store, "k", b"v"); nothing catch e; e end
            @test e isa TransportError && e.status == 500 && S3T.retryable(e)
            @test occursin("PUT http://127.0.0.1:$(server.port)/bkt/k: HTTP 500 InternalError: We encountered an internal error", sprint(showerror, e))
            @test !haskey(server.objects, "k")
            server.respond = req -> req.method == "PUT" ? (409, [], s3test_error("ConditionalRequestConflict", "Conditional request cannot succeed due to a conflicting operation against this resource.")) : nothing
            e = try put_object_if_absent(store, "k", b"v"); nothing catch e; e end
            @test e isa TransportError && e.status == 409 && S3T.retryable(e)     # never a PutOutcome: the commit layer retries it
            server.respond = req -> (403, [], s3test_error("AccessDenied", "Access Denied"))
            for call in (() -> fetch_object(store, "k"), () -> stat_object(store, "k"), () -> list_objects(store, ""),
                         () -> put_object_if_absent(store, "k", b"v"))
                e = try call(); nothing catch e; e end
                @test e isa TransportError && e.status == 403 && !S3T.retryable(e)
            end
            @test sprint(showerror, try stat_object(store, "k") catch e; e end) ==      # a HEAD carries no error document
                  "TransportError: HEAD http://127.0.0.1:$(server.port)/bkt/k: HTTP 403 (HTTP 403)"
            server.respond = req -> (503, [], UInt8[])                            # no error document: the status alone
            e = try fetch_object(store, "k"); nothing catch e; e end
            @test e isa TransportError && e.status == 503 && sprint(showerror, e) == "TransportError: GET http://127.0.0.1:$(server.port)/bkt/k: HTTP 503 (HTTP 503)"
            server.respond = req -> req.method == "HEAD" ? (200, [], b"no last-modified") : nothing
            @test_throws "the response lacks Content-Length or Last-Modified" stat_object(store, "k")
            server.respond = req -> (200, ["content-type" => "application/xml"], Vector{UInt8}("<ListBucketResult><IsTruncated>true</IsTruncated></ListBucketResult>"))
            @test_throws "IsTruncated without a NextContinuationToken" list_objects(store, "")
        finally
            close(server)
        end
        # nothing listening: no status, retryable, the message says why
        closed = S3TestServer(; bucket = "bkt", credentials = creds)
        port = closed.port
        close(closed)
        sleep(0.1)
        store = S3ObjectStore("bkt"; region = "eu-north-1", credentials = creds, endpoint = "http://127.0.0.1:$port", path_style = true, timeout = 5)
        e = try fetch_object(store, "k"); nothing catch e; e end
        @test e isa TransportError && e.status === nothing && S3T.retryable(e)
        @test startswith(sprint(showerror, e), "TransportError: GET http://127.0.0.1:$port/bkt/k: no response")
    end

    # ------------------------------------------------------------------------
    # The gate (ADR-0016, ADR-0019, ADR-0020): a non-AWS endpoint warns once at open,
    # syncs, and refuses at commit! and create_chain before anything is applied;
    # assume_first_writer_wins lifts the refusal, and the message names the four things.
    # ------------------------------------------------------------------------
    @testset "the backend gate end to end" begin
        creds = Credentials("AKIATEST", "topsecret")
        server = S3TestServer(; bucket = "bkt", credentials = creds)
        mktempdir() do dir
            try
                cache_dir = joinpath(dir, "cache")
                endpoint = s3test_endpoint(server)
                unsure = Chain("bkt", "exp/run-1"; region = "eu-north-1", credentials = creds, endpoint, path_style = true, cache_dir)
                promised = Chain("bkt", "exp/run-1"; region = "eu-north-1", credentials = creds, endpoint, path_style = true, cache_dir,
                                 assume_first_writer_wins = true)
                @test !S3T.is_aws(unsure.store) && !S3T.is_aws(promised.store)
                # create_chain refuses: nothing written
                e = try S3T.create_chain(unsure); nothing catch e; e end
                @test e isa UnsupportedStoreError && e.endpoint == endpoint
                msg = sprint(showerror, e)
                @test startswith(msg, "UnsupportedStoreError: unsupported object store: create_chain(chain) refuses to commit to $endpoint, which is not AWS S3")
                @test occursin("If-None-Match: *", msg) && occursin("never overwrites", msg)      # the promise
                @test occursin("rewritten chain", msg) && occursin("silent data loss", msg)       # the consequence
                @test occursin("assume_first_writer_wins = true", msg)                            # the field
                @test isempty(server.requests) && isempty(server.objects)
                # with the promise made, it is an ordinary chain
                created = S3T.create_chain(promised)
                @test created.slot == 0 && haskey(server.objects, "exp/run-1/000000000000")
                # open warns once per process, and syncs and reads normally
                warning = r"^unsupported object store: the endpoint http://127\.0\.0\.1:\d+ is not AWS S3, the only store ChainTables v1 claims \(ADR-0016\)\. This local copy syncs and reads normally; commit!\(w\) will refuse unless the chain is constructed with assume_first_writer_wins = true\.$"
                copy = @test_logs (:warn, warning) S3T.open(unsure, joinpath(dir, "a"))
                @test S3T.sync!(copy).slot == 0
                w = S3T.write_builder(copy)
                S3T.create_table!(w, :samples) do t
                    S3T.column!(t, :id, Int64); S3T.column!(t, :mass, Float64); S3T.primary_key!(t, :id)
                end
                S3T.insert_rows!(w, :samples, [(id = 1, mass = 1.5)])
                n = length(server.requests)
                e = try S3T.commit!(w); nothing catch e; e end
                @test e isa UnsupportedStoreError && e.endpoint == endpoint
                @test startswith(sprint(showerror, e), "UnsupportedStoreError: unsupported object store: commit!(w) refuses to commit to $endpoint")
                @test length(server.requests) == n                       # before anything: no request, no file
                @test S3T.head(copy).slot == 0 && isempty(S3T.tables(copy)) && readdir(joinpath(dir, "a", "tables")) == []
                @test_throws "this builder is spent" S3T.commit!(w)
                # once per process (maxlog = 1): a logger sees it once however many opens, and as_of warns through the same path
                @test_logs (:warn, warning) begin
                    close(S3T.open(unsure, joinpath(dir, "a2")))
                    close(S3T.as_of(unsure, 0))
                    close(S3T.open(unsure, joinpath(dir, "a3")))
                end
                # the promised chain commits; the unsure one reads it back
                copy2 = S3T.open(promised, joinpath(dir, "b"))
                S3T.sync!(copy2)
                w = S3T.write_builder(copy2)
                S3T.create_table!(w, :samples) do t
                    S3T.column!(t, :id, Int64); S3T.column!(t, :mass, Float64); S3T.primary_key!(t, :id)
                end
                S3T.insert_rows!(w, :samples, [(id = 1, mass = 1.5), (id = 2, mass = 2.5)])
                done = S3T.commit!(w; comment = "over the wire")
                @test done.slot == 1 && haskey(server.objects, "exp/run-1/000000000001")
                put = last(filter(r -> r.method == "PUT", server.requests))
                @test put.rawpath == "/bkt/exp/run-1/000000000001" && put.headers["if-none-match"] == "*"
                @test S3T.sync!(copy) == (; applied = 1, slot = 1, transaction_hash = done.transaction_hash)
                @test S3T.table(copy, :samples)[2].mass == 2.5
                # the refusal is never suppressed: a second commit on the unsure chain refuses again
                w = S3T.write_builder(copy)
                S3T.insert_rows!(w, :samples, [(id = 3, mass = 3.5)])
                @test_throws UnsupportedStoreError S3T.commit!(w)
                close(copy); close(copy2)
                # an AWS endpoint spelled out passes the gate: no warning, and the refusal is not reached
                aws = Chain("bkt", "exp/run-1"; region = "eu-north-1", credentials = creds, endpoint = "https://s3.eu-north-1.amazonaws.com", cache_dir)
                @test S3T.is_aws(aws.store) && S3T.warn_unsupported_store(aws) === nothing
                @test S3T.refuse_unsupported_store(aws, "commit!(w)") === nothing
                @test S3T.refuse_unsupported_store(promised, "commit!(w)") === nothing
                @test_throws UnsupportedStoreError S3T.refuse_unsupported_store(unsure, "commit!(w)")
                @test S3T.warn_unsupported_store(nothing) === nothing         # a test's stand-in chain is silent
            finally
                close(server)
            end
        end
    end

    # ------------------------------------------------------------------------
    # Live S3 (issue #6): the one test only AWS can answer. Skipped without
    # CHAINTABLES_TEST_BUCKET; with it, credentials and AWS_REGION are required and nothing
    # has a default — the run line is in test/runtests.jl. Builds every chain it reads under a fresh prefix — the
    # bucket's lifecycle rule expires objects after 7 days — and never deletes: the
    # port has no delete verb.
    # ------------------------------------------------------------------------
    @testset "live S3 (issue #6; skipped without CHAINTABLES_TEST_BUCKET)" begin
        if isempty(get(ENV, "CHAINTABLES_TEST_BUCKET", ""))
            @test_skip haskey(ENV, "CHAINTABLES_TEST_BUCKET")   # see test/runtests.jl for the run line
        else
            bucket = ENV["CHAINTABLES_TEST_BUCKET"]
            region = get(ENV, "AWS_REGION", "")
            isempty(region) && error("live S3 test: AWS_REGION is not set (see test/runtests.jl)")
            prefix = "chaintables-test/" * bytes2hex(rand(UInt8, 8))
            mktempdir() do dir
                cache_dir = joinpath(dir, "cache")
                chain = Chain(bucket, prefix; region, cache_dir)
                @test chain.store isa S3ObjectStore && S3T.is_aws(chain.store)
                store = chain.store
                # under a session, the token is signed and sent — the request below would be 403 otherwise
                session = chain.credentials.session_token !== nothing
                req = S3T.request_headers(store, "GET", S3T.slot_key(chain, 0))
                @test session == any(kv -> kv[1] == "x-amz-security-token", req.headers)
                @test session == occursin("x-amz-security-token", last(req.headers[findfirst(kv -> kv[1] == "authorization", req.headers)]))
                key = S3T.slot_key(chain, 0)
                @test fetch_object(store, key) === nothing && stat_object(store, key) === nothing && isempty(list_objects(store, prefix * "/"))
                created = S3T.create_chain(chain)
                # the header is not silently dropped: the second conditional PUT to the key fails 412 …
                @test put_object_if_absent(store, key, b"an impostor genesis") == PutOutcome(false, 412)
                # … a GET of the just-created key returns it …
                bytes = fetch_object(store, key)
                @test bytes !== nothing && S3T.TransactionHash(S3T.Ops.transaction_hash(bytes)) == created.transaction_hash
                meta = stat_object(store, key)
                @test meta.key == key && meta.size == length(bytes) && abs(meta.modified - time()) < 300
                @test [m.key for m in list_objects(store, prefix * "/")] == [key]
                # … and a chain round-trips through two local copies
                copy = S3T.open(chain, joinpath(dir, "a"))
                @test S3T.sync!(copy).slot == 0
                w = S3T.write_builder(copy)
                S3T.create_table!(w, :samples) do t
                    S3T.column!(t, :id, Int64); S3T.column!(t, :label, String); S3T.primary_key!(t, :id)
                end
                S3T.insert_rows!(w, :samples, [(id = 1, label = "live"), (id = 2, label = "s3")])
                done = S3T.commit!(w; comment = "the live test")
                @test done.slot == 1
                other = S3T.open(chain, joinpath(dir, "b"))
                @test S3T.sync!(other) == (; applied = 2, slot = 1, transaction_hash = done.transaction_hash)
                @test S3T.table(other, :samples)[2].label == "s3"
                @test S3T.verify(other; full = true) === nothing
                close(copy); close(other)
            end
        end
    end
end
