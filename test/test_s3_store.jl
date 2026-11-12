using Test
using ChainTables: ChainTables, Chain, Credentials, ObjectMeta, PutOutcome, S3ObjectStore,
    TransportError, cache_namespace, fetch_object, list_objects, put_object_if_absent,
    stat_object

include("fixtures/s3_server.jl")

const KEYS = Credentials("id", "secret")
const SESSION = Credentials("AKIATEST", "topsecret"; session_token = "session-token")
const PLAIN = Credentials("AKIATEST", "topsecret")

const AWS_HOST = "bkt.s3.eu-north-1.amazonaws.com"

aws_store(; kw...) = S3ObjectStore("bkt"; region = "eu-north-1", credentials = KEYS, kw...)

function loopback_store(server; credentials = server.credentials, kw...)
    return S3ObjectStore(
        "bkt"; region = "eu-north-1", credentials, endpoint = s3test_endpoint(server),
        path_style = true, kw...
    )
end

@testset "S3ObjectStore infers" begin
    store = @inferred S3ObjectStore("bkt"; region = "eu-north-1", credentials = KEYS)
    @test store.bucket == "bkt"
end

@testset "S3ObjectStore addresses AWS virtual-hosted by default" begin
    s = aws_store()
    @test (s.host, s.base) == (AWS_HOST, "https://$AWS_HOST")
    @test ChainTables.object_path(s, "p/000000000001") == "/p/000000000001"
    @test ChainTables.is_aws(s) && s.endpoint === nothing && s.timeout == 60
    @test sprint(show, s) == "S3ObjectStore(\"bkt\"; region = \"eu-north-1\")"
end

@testset "S3ObjectStore addresses AWS path-style on request" begin
    s = aws_store(; path_style = true)
    @test (s.host, s.base) == (AWS_HOST[5:end], "https://$(AWS_HOST[5:end])")
    @test ChainTables.object_path(s, "p/000000000001") == "/bkt/p/000000000001"
    @test ChainTables.is_aws(s)
end

const AWS_ENDPOINTS = [
    "https://s3-fips.us-gov-west-1.amazonaws.com",
    "https://s3.dualstack.eu-north-1.amazonaws.com",
    "https://s3.cn-north-1.amazonaws.com.cn",
    "HTTPS://S3.EU-NORTH-1.AMAZONAWS.COM:443/",
]

@testset "S3ObjectStore counts $endpoint as AWS" for endpoint in AWS_ENDPOINTS
    s = aws_store(; endpoint)
    @test ChainTables.is_aws(s)
    @test s.endpoint == endpoint
end

const OTHER_ENDPOINTS = [
    "https://minio.local:9000", "http://127.0.0.1:9000", "https://r2.cloudflarestorage.com",
    "https://amazonaws.com", "https://evil-amazonaws.com",
    "https://amazonaws.com.example.org",
]

@testset "S3ObjectStore counts $endpoint as not AWS" for endpoint in OTHER_ENDPOINTS
    @test !ChainTables.is_aws(aws_store(; endpoint))
end

@testset "S3ObjectStore canonicalises an endpoint" begin
    s = aws_store(; endpoint = "HTTPS://S3.EU-NORTH-1.AMAZONAWS.COM:443/")
    @test (s.host, s.base) == (AWS_HOST, "https://$AWS_HOST")
    s = aws_store(; endpoint = "https://minio.local:9000")
    @test (s.host, s.base) == ("bkt.minio.local:9000", "https://bkt.minio.local:9000")
    @test sprint(show, s) ==
        "S3ObjectStore(\"bkt\"; region = \"eu-north-1\", " *
        "endpoint = \"https://minio.local:9000\")"
    s = aws_store(; endpoint = "http://127.0.0.1:9000", path_style = true)
    @test (s.host, s.base) == ("127.0.0.1:9000", "http://127.0.0.1:9000")
    @test ChainTables.object_path(s, "") == "/bkt/"
end

const REFUSED_STORES = [
    (
        name = "no scheme", bucket = "bkt", kw = (; endpoint = "minio.local:9000"),
        says = "endpoint \"minio.local:9000\" is not of the form scheme://host[:port]",
    ),
    (
        name = "a path", bucket = "bkt", kw = (; endpoint = "https://minio.local/bkt"),
        says = "not of the form scheme://host[:port]",
    ),
    (
        name = "ftp", bucket = "bkt", kw = (; endpoint = "ftp://minio.local"),
        says = "not of the form scheme://host[:port]",
    ),
    (
        name = "a dot", bucket = "my.bucket", kw = (;),
        says = "bucket name \"my.bucket\" contains a dot, which breaks certificate",
    ),
    (name = "empty", bucket = "", kw = (;), says = "the bucket name is empty"),
    (name = "no timeout", bucket = "bkt", kw = (; timeout = 0), says = "timeout is 0"),
]

@testset "S3ObjectStore refuses $(case.name)" for case in REFUSED_STORES
    make = () -> S3ObjectStore(case.bucket; region = "r", credentials = KEYS, case.kw...)
    @test_throws ArgumentError case.says make()
end

const NAMESPACE_CASES = [
    (name = "AWS", kw = (;), namespace = "aws"),
    (name = "China", kw = (; region = "cn-north-1"), namespace = "aws-cn"),
    (name = "GovCloud", kw = (; region = "us-gov-west-1"), namespace = "aws-us-gov"),
]

@testset "cache_namespace of AWS's URL is its partition: $(case.name)" for case in
    NAMESPACE_CASES
    s = S3ObjectStore("bkt"; region = "eu-north-1", credentials = KEYS, case.kw...)
    @test cache_namespace(s) == case.namespace
end

@testset "cache_namespace of an endpoint hashes its canonical form" begin
    a = cache_namespace(aws_store(; endpoint = "HTTPS://Minio.local:443/"))
    @test a == cache_namespace(aws_store(; endpoint = "https://minio.local"))
    @test occursin(r"^ep-[0-9a-f]{8}$", a)
end

@testset "Chain with no store builds the S3 client, resolving its arguments now" begin
    withenv(
        "AWS_ACCESS_KEY_ID" => "AKIAX", "AWS_SECRET_ACCESS_KEY" => "s3cret",
        "AWS_SESSION_TOKEN" => nothing, "AWS_REGION" => nothing,
        "AWS_DEFAULT_REGION" => nothing,
    ) do
        chain = Chain("bkt", "p"; region = "eu-north-1", cache_dir = "/c")
        @test chain isa Chain{S3ObjectStore}
        @test (chain.store.bucket, chain.store.region) == ("bkt", "eu-north-1")
        @test chain.store.credentials == Credentials("AKIAX", "s3cret")
        @test ChainTables.is_aws(chain.store) && !chain.assume_first_writer_wins
        endpoint = "https://minio.local:9000"
        other = Chain("bkt", "p"; region = "r", endpoint, path_style = true)
        @test other.store.path_style && !ChainTables.is_aws(other.store)
    end
end

const REGION_CASES = [
    (
        name = "the keyword", region = "eu-north-1", env = ("AWS_REGION" => "us-east-1",),
        resolved = "eu-north-1",
    ),
    (
        name = "AWS_REGION", region = nothing,
        env = ("AWS_REGION" => "us-east-1", "AWS_DEFAULT_REGION" => "us-west-2"),
        resolved = "us-east-1",
    ),
    (
        name = "AWS_DEFAULT_REGION", region = nothing,
        env = ("AWS_REGION" => nothing, "AWS_DEFAULT_REGION" => "us-west-2"),
        resolved = "us-west-2",
    ),
]

@testset "Chain takes the region from $(case.name)" for case in REGION_CASES
    withenv(case.env...) do
        chain = Chain("bkt", "p"; case.region, credentials = KEYS, cache_dir = "/c")
        @test chain.store.region == case.resolved
    end
end

@testset "Chain never guesses a region" begin
    withenv("AWS_REGION" => nothing, "AWS_DEFAULT_REGION" => "") do
        says = "region is required by the S3 client"
        @test_throws ArgumentError says Chain("bkt", "p"; credentials = KEYS)
    end
end

@testset "fetch_object and stat_object return nothing for an absent key" begin
    with_s3_server(; bucket = "bkt", credentials = SESSION) do server
        store = loopback_store(server)
        @test fetch_object(store, "p/000000000001") === nothing
        @test stat_object(store, "p/000000000001") === nothing
    end
end

@testset "put_object_if_absent creates once and never overwrites" begin
    with_s3_server(; bucket = "bkt", credentials = SESSION) do server
        store = loopback_store(server)
        key = "p/000000000001"
        @test put_object_if_absent(store, key, b"record one") == PutOutcome(true, 200)
        @test put_object_if_absent(store, key, b"record two") == PutOutcome(false, 412)
        @test fetch_object(store, key) == b"record one"
        meta = stat_object(store, key)
        @test (meta.key, meta.size) == (key, 10)
        @test abs(meta.modified - time()) < 60
    end
end

@testset "put_object_if_absent sends a bare If-None-Match, signed with the session" begin
    with_s3_server(; bucket = "bkt", credentials = SESSION) do server
        put_object_if_absent(loopback_store(server), "p/000000000001", b"record one")
        put = only(server.requests)
        @test put.headers["if-none-match"] == "*"
        @test put.headers["content-length"] == "10"
        @test put.headers["x-amz-security-token"] == "session-token"
        @test put.headers["host"] == "127.0.0.1:$(server.port)"
        @test put.rawpath == "/bkt/p/000000000001"
        @test occursin(
            "SignedHeaders=host;if-none-match;x-amz-content-sha256;x-amz-date;" *
                "x-amz-security-token,",
            put.headers["authorization"]
        )
    end
end

@testset "put_object_if_absent without a session sends no token" begin
    with_s3_server(; bucket = "bkt", credentials = PLAIN) do server
        store = loopback_store(server)
        @test put_object_if_absent(store, "k", b"v").created
        @test fetch_object(store, "k") == b"v"
        @test !haskey(server.requests[1].headers, "x-amz-security-token")
        @test !occursin("security-token", server.requests[1].headers["authorization"])
    end
end

@testset "put_object_if_absent encodes a key once" begin
    with_s3_server(; bucket = "bkt", credentials = SESSION) do server
        store = loopback_store(server)
        odd = "p/a b\$c/é"
        @test put_object_if_absent(store, odd, b"x").created
        @test server.requests[end].rawpath == "/bkt/p/a%20b%24c/%C3%A9"
        @test haskey(server.objects, odd) && fetch_object(store, odd) == b"x"
    end
end

const LISTED = ["p/000000000001", "p/000000000002", "p/000000000003", "q/x&y<z"]

function with_listed_server(f)
    return with_s3_server(; bucket = "bkt", credentials = SESSION) do server
        store = loopback_store(server)
        foreach(k -> put_object_if_absent(store, k, Vector{UInt8}(k)), LISTED)
        f(server, store)
    end
end

@testset "list_objects lists a prefix, after a key, with keys unescaped" begin
    with_listed_server() do server, store
        listed = list_objects(store, "p/")
        @test [m.key for m in listed] == LISTED[1:3]
        @test listed[3] isa ObjectMeta && listed[3].size == 14
        @test abs(listed[1].modified - time()) < 60
        after = list_objects(store, "p/0"; start_after = "p/000000000001")
        @test [m.key for m in after] == LISTED[2:3]
        @test [m.key for m in list_objects(store, "q/")] == ["q/x&y<z"]
        @test isempty(list_objects(store, "z"))
        @test server.requests[end].query == ["list-type" => "2", "prefix" => "z"]
    end
end

@testset "list_objects follows pages, one request each" begin
    with_listed_server() do server, store
        server.page_size = 2
        n = length(server.requests)
        @test length(list_objects(store, "p/")) == 3
        @test length(server.requests) - n == 2
        @test server.requests[end].query ==
            ["continuation-token" => "3", "list-type" => "2", "prefix" => "p/"]
    end
end

@testset "fetch_object raises a refused signature with S3's code" begin
    with_s3_server(; bucket = "bkt", credentials = SESSION) do server
        wrong = Credentials("AKIATEST", "nope"; session_token = "session-token")
        store = loopback_store(server; credentials = wrong)
        url = "http://127.0.0.1:$(server.port)/bkt/k"
        says = "GET $url: SignatureDoesNotMatch: expected"
        e = (@test_throws TransportError says fetch_object(store, "k")).value
        @test e.status == 403
    end
end

@testset "fetch_object raises a wrong region with S3's code" begin
    with_s3_server(; bucket = "bkt", credentials = SESSION) do server
        store = S3ObjectStore(
            "bkt"; region = "us-east-1", credentials = SESSION,
            endpoint = s3test_endpoint(server), path_style = true
        )
        says = "AuthorizationHeaderMalformed: the region 'us-east-1' is wrong"
        e = (@test_throws TransportError says fetch_object(store, "k")).value
        @test e.status == 400
    end
end

const PUT_FAILURES = [
    (name = "500", status = 500, code = "InternalError", says = "Internal error"),
    (name = "409", status = 409, code = "ConditionalRequestConflict", says = "Conflict"),
]

@testset "put_object_if_absent raises a $(case.name) with its status" for case in
    PUT_FAILURES
    with_s3_server(; bucket = "bkt", credentials = PLAIN) do server
        store = loopback_store(server)
        server.respond = req -> s3test_refusal(case.status, case.code, case.says)
        url = "http://127.0.0.1:$(server.port)/bkt/k"
        says = "PUT $url: $(case.code): $(case.says)"
        e = (@test_throws TransportError says put_object_if_absent(store, "k", b"v")).value
        @test e.status == case.status
        @test !haskey(server.objects, "k")
    end
end

const VERBS = [
    (name = "fetch_object", call = store -> fetch_object(store, "k")),
    (name = "stat_object", call = store -> stat_object(store, "k")),
    (name = "list_objects", call = store -> list_objects(store, "")),
    (name = "put_object_if_absent", call = store -> put_object_if_absent(store, "k", b"v")),
]

@testset "$(case.name) raises an access refusal with its status" for case in VERBS
    with_s3_server(; bucket = "bkt", credentials = PLAIN) do server
        server.respond = _ -> s3test_refusal(403, "AccessDenied", "Access Denied")
        store = loopback_store(server)
        e = (@test_throws TransportError "a request failed" case.call(store)).value
        @test e.status == 403
    end
end

@testset "stat_object raises a HEAD refusal with the status alone" begin
    with_s3_server(; bucket = "bkt", credentials = PLAIN) do server
        server.respond = _ -> s3test_refusal(403, "AccessDenied", "Access Denied")
        store = loopback_store(server)
        says = "HEAD http://127.0.0.1:$(server.port)/bkt/k."
        e = (@test_throws TransportError says stat_object(store, "k")).value
        @test e.status == 403
    end
end

@testset "stat_object refuses a reply without Last-Modified" begin
    with_s3_server(; bucket = "bkt", credentials = PLAIN) do server
        server.respond = req -> (200, Pair{String, String}[], b"no last-modified")
        store = loopback_store(server)
        says = "the response lacks Content-Length or Last-Modified"
        @test_throws TransportError says stat_object(store, "k")
    end
end

@testset "list_objects refuses a truncated page without a token" begin
    with_s3_server(; bucket = "bkt", credentials = PLAIN) do server
        page = "<ListBucketResult><IsTruncated>true</IsTruncated></ListBucketResult>"
        server.respond = req -> (200, Pair{String, String}[], Vector{UInt8}(page))
        store = loopback_store(server)
        says = "IsTruncated without a NextContinuationToken"
        @test_throws TransportError says list_objects(store, "")
    end
end

@testset "fetch_object raises no response as a TransportError without status" begin
    closed = S3TestServer(; bucket = "bkt", credentials = PLAIN)
    port = closed.port
    close(closed)
    store = S3ObjectStore(
        "bkt"; region = "eu-north-1", credentials = PLAIN,
        endpoint = "http://127.0.0.1:$port", path_style = true, timeout = 5
    )
    says = "GET http://127.0.0.1:$port/bkt/k: no response"
    e = (@test_throws TransportError says fetch_object(store, "k")).value
    @test e.status === nothing
end
