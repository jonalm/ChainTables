# The S3 store is internal: `Chain` builds it, and the tests reach it as `chain.store`.
# The cases on its URL and on what counts as AWS read its fields and call `is_aws`,
# since no request shows them without the network.
using Test
using ChainTables: ChainTables, Chain, Credentials, ObjectMeta, PutOutcome,
    TransportError, UnsupportedStoreError, column!, commit!, create_chain, create_table!,
    fetch_object, head, insert_rows!, list_objects, open, primary_key!,
    put_object_if_absent, stat_object, sync!, table, write_builder

include("fixtures/s3_server.jl")

const SESSION_CREDENTIALS = Credentials("AKIATEST", "topsecret"; session_token = "tok")
const PLAIN_CREDENTIALS = Credentials("AKIATEST", "topsecret")
const KEY = "p/000000000001"
const WITHOUT_AWS_CREDENTIALS = (
    "AWS_ACCESS_KEY_ID" => nothing, "AWS_SECRET_ACCESS_KEY" => nothing,
    "AWS_SESSION_TOKEN" => nothing,
)
const AWS_ENDPOINTS = [
    "https://s3-fips.us-gov-west-1.amazonaws.com",
    "https://s3.dualstack.eu-north-1.amazonaws.com",
    "https://s3.cn-north-1.amazonaws.com.cn",
    "HTTPS://S3.EU-NORTH-1.AMAZONAWS.COM:443/",
]
const OTHER_ENDPOINTS = [
    "https://minio.local:9000", "http://127.0.0.1:9000", "https://r2.cloudflarestorage.com",
    "https://amazonaws.com", "https://evil-amazonaws.com",
    "https://amazonaws.com.example.org",
]
const MALFORMED_ENDPOINTS =
    ["minio.local:9000", "https://minio.local/bkt", "ftp://minio.local"]
const BOTH_UNSET = "AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY is not set"

function s3_chain(endpoint; credentials = PLAIN_CREDENTIALS, keywords...)
    return Chain(
        "bkt", "p"; region = "eu-north-1", credentials, endpoint, path_style = true,
        cache_dir = "/c", keywords...,
    )
end

s3_store(server; keywords...) = s3_chain(s3test_endpoint(server); keywords...).store

function with_session_server(f)
    return with_s3_server(f; bucket = "bkt", credentials = SESSION_CREDENTIALS)
end

with_plain_server(f) = with_s3_server(f; bucket = "bkt", credentials = PLAIN_CREDENTIALS)

function samples_builder(local_copy, rows)
    w = write_builder(local_copy)
    create_table!(w, :samples) do t
        column!(t, :id, Int64)
        column!(t, :mass, Float64)
        primary_key!(t, :id)
    end
    insert_rows!(w, :samples, rows)
    return w
end

@testset "Chain builds the S3 store from the AWS environment" begin
    environment = (
        "AWS_ACCESS_KEY_ID" => "AKIAX", "AWS_SECRET_ACCESS_KEY" => "s3cret",
        "AWS_SESSION_TOKEN" => "tok", "AWS_REGION" => "eu-north-1",
    )
    withenv(environment...) do
        store = Chain("bkt", "p"; cache_dir = "/c").store
        @test store isa ChainTables.S3ObjectStore
        @test store.credentials == Credentials("AKIAX", "s3cret"; session_token = "tok")
        @test store.region == "eu-north-1"
    end
end

@testset "Chain refuses unset AWS credentials when given none" begin
    withenv(WITHOUT_AWS_CREDENTIALS..., "AWS_REGION" => "eu-north-1") do
        @test_throws ArgumentError BOTH_UNSET Chain("bkt", "p"; cache_dir = "/c")
    end
    secret_only = (WITHOUT_AWS_CREDENTIALS..., "AWS_SECRET_ACCESS_KEY" => "s")
    withenv(secret_only..., "AWS_REGION" => "r") do
        @test_throws ArgumentError "and AWS_ACCESS_KEY_ID is not set" Chain(
            "bkt", "p"; cache_dir = "/c"
        )
    end
end

@testset "Chain takes credentials as a value with their fields" begin
    given = (; access_key_id = "id", secret_access_key = "secret", session_token = "t")
    store = Chain("bkt", "p"; region = "r", credentials = given, cache_dir = "/c").store
    @test store.credentials == Credentials("id", "secret"; session_token = "t")
end

@testset "Chain calls a credentials callable once, and again before each request" begin
    with_plain_server() do server
        calls = Ref(0)
        source = () -> (calls[] += 1; PLAIN_CREDENTIALS)
        store = s3_store(server; credentials = source)
        @test calls[] == 1
        fetch_object(store, KEY)
        fetch_object(store, KEY)
        @test calls[] == 3
    end
end

@testset "Chain refuses credentials it cannot sign with" begin
    @test_throws ArgumentError "credentials is a Int64, which is not" Chain(
        "bkt", "p"; region = "r", credentials = 1, cache_dir = "/c"
    )
    @test_throws ArgumentError "credentials must be a ChainTables.Credentials" Chain(
        "bkt", "p"; region = "r", credentials = () -> "nope", cache_dir = "/c"
    )
end

@testset "Chain takes the region, else AWS_REGION, else AWS_DEFAULT_REGION" begin
    region_of = chain -> chain.store.region
    withenv("AWS_REGION" => "us-east-1", "AWS_DEFAULT_REGION" => "us-west-2") do
        @test region_of(s3_chain(nothing)) == "eu-north-1"
        @test region_of(s3_chain(nothing; region = nothing)) == "us-east-1"
    end
    withenv("AWS_REGION" => nothing, "AWS_DEFAULT_REGION" => "us-west-2") do
        @test region_of(s3_chain(nothing; region = nothing)) == "us-west-2"
    end
    withenv("AWS_REGION" => nothing, "AWS_DEFAULT_REGION" => "") do
        @test_throws ArgumentError "the S3 store needs a region" s3_chain(
            nothing; region = nothing
        )
    end
end

@testset "Chain puts the bucket in the host, or in the path with path_style" begin
    virtual = s3_chain(nothing; path_style = false).store
    @test virtual.base == "https://bkt.s3.eu-north-1.amazonaws.com"
    @test ChainTables.object_path(virtual, KEY) == "/p/000000000001"
    path_style = s3_chain(nothing).store
    @test path_style.base == "https://s3.eu-north-1.amazonaws.com"
    @test ChainTables.object_path(path_style, KEY) == "/bkt/p/000000000001"
    other = s3_chain("https://minio.local:9000"; path_style = false).store
    @test other.base == "https://bkt.minio.local:9000"
end

@testset "Chain drops the default port of an endpoint" begin
    store = s3_chain("HTTPS://S3.EU-NORTH-1.AMAZONAWS.COM:443/"; path_style = false).store
    @test store.host == "bkt.s3.eu-north-1.amazonaws.com"
end

@testset "Chain counts a spelled-out AWS endpoint as AWS" begin
    @testset "$endpoint" for endpoint in AWS_ENDPOINTS
        @test ChainTables.is_aws(s3_chain(endpoint).store)
    end
end

@testset "Chain counts any other endpoint as not AWS" begin
    @testset "$endpoint" for endpoint in OTHER_ENDPOINTS
        @test !ChainTables.is_aws(s3_chain(endpoint).store)
    end
end

@testset "Chain refuses an endpoint that is not scheme://host[:port]" begin
    @testset "$endpoint" for endpoint in MALFORMED_ENDPOINTS
        @test_throws ArgumentError "is not of the form scheme://host[:port]" s3_chain(
            endpoint
        )
    end
end

@testset "Chain shows the S3 store without its credentials" begin
    store = s3_chain("https://minio.local:9000").store
    @test sprint(show, store) ==
        "S3ObjectStore(\"bkt\"; region = \"eu-north-1\", " *
        "endpoint = \"https://minio.local:9000\", path_style = true)"
end

@testset "put_object_if_absent creates a key once and never replaces it" begin
    with_session_server() do server
        store = s3_store(server; credentials = SESSION_CREDENTIALS)
        @test fetch_object(store, KEY) === nothing
        @test stat_object(store, KEY) === nothing
        @test put_object_if_absent(store, KEY, b"record one") == PutOutcome(true, 200)
        @test put_object_if_absent(store, KEY, b"record two") == PutOutcome(false, 412)
        @test fetch_object(store, KEY) == b"record one"
        @test server.objects[KEY] == b"record one"
        @test stat_object(store, KEY).size == 10
    end
end

@testset "put_object_if_absent signs If-None-Match and the session token" begin
    with_session_server() do server
        store = s3_store(server; credentials = SESSION_CREDENTIALS)
        put_object_if_absent(store, KEY, b"record one")
        put = only(server.requests)
        @test put.headers["if-none-match"] == "*"
        @test put.headers["content-length"] == "10"
        @test put.headers["x-amz-security-token"] == "tok"
        @test put.headers["host"] == "127.0.0.1:$(server.port)"
        @test put.rawpath == "/bkt/p/000000000001"
        @test occursin(
            "SignedHeaders=host;if-none-match;x-amz-content-sha256;x-amz-date;" *
                "x-amz-security-token,",
            put.headers["authorization"],
        )
    end
end

@testset "put_object_if_absent sends no session token without one" begin
    with_plain_server() do server
        store = s3_store(server)
        @test put_object_if_absent(store, "k", b"v").created
        put = only(server.requests)
        @test !haskey(put.headers, "x-amz-security-token")
        @test !occursin("security-token", put.headers["authorization"])
    end
end

@testset "fetch_object encodes a key once" begin
    with_plain_server() do server
        store = s3_store(server)
        odd = "p/a b\$c/é"
        put_object_if_absent(store, odd, b"x")
        @test server.requests[end].rawpath == "/bkt/p/a%20b%24c/%C3%A9"
        @test haskey(server.objects, odd)
        @test fetch_object(store, odd) == b"x"
    end
end

@testset "stat_object reads Last-Modified as Unix seconds" begin
    with_plain_server() do server
        store = s3_store(server)
        put_object_if_absent(store, KEY, b"x")
        server.modified[KEY] = 1255369800
        @test stat_object(store, KEY) == ObjectMeta(KEY, 1, 1255369800)
    end
end

@testset "list_objects lists a prefix, by bytes, with keys unescaped" begin
    with_plain_server() do server
        store = s3_store(server)
        keys = ["p/000000000001", "p/000000000002", "p/a b", "q/x&y<z"]
        foreach(key -> put_object_if_absent(store, key, b"three"), keys)
        server.modified["p/000000000002"] = 1255369800
        listed = list_objects(store, "p/")
        @test sort([meta.key for meta in listed]) == keys[1:3]
        @test ObjectMeta("p/000000000002", 5, 1255369800) in listed
        @test [meta.key for meta in list_objects(store, "q/")] == ["q/x&y<z"]
        @test isempty(list_objects(store, "z"))
    end
end

@testset "list_objects lists only keys after start_after" begin
    with_plain_server() do server
        store = s3_store(server)
        foreach(slot -> put_object_if_absent(store, "p/00$slot", b"x"), 1:3)
        @test [meta.key for meta in list_objects(store, "p/"; start_after = "p/001")] ==
            ["p/002", "p/003"]
    end
end

@testset "list_objects reads every page, one request each" begin
    paged = (; bucket = "bkt", credentials = PLAIN_CREDENTIALS, page_size = 2)
    with_s3_server(; paged...) do server
        store = s3_store(server)
        foreach(slot -> put_object_if_absent(store, "p/00$slot", b"x"), 1:4)
        n_requests = length(server.requests)
        @test length(list_objects(store, "p/")) == 4
        @test length(server.requests) - n_requests == 2
        @test server.requests[end].query ==
            ["continuation-token" => "3", "list-type" => "2", "prefix" => "p/"]
    end
end

@testset "fetch_object throws TransportError when the store refuses the signature" begin
    with_session_server() do server
        wrong = Credentials("AKIATEST", "nope"; session_token = "tok")
        store = s3_store(server; credentials = wrong)
        err = (
            @test_throws TransportError "SignatureDoesNotMatch: expected" fetch_object(
                store, KEY
            )
        ).value
        @test err.status == 403
        @test err.method == "GET"
        @test err.url == "http://127.0.0.1:$(server.port)/bkt/p/000000000001"
        @test occursin("A retry will not help", sprint(showerror, err))
    end
end

@testset "fetch_object throws TransportError when the region is wrong" begin
    with_plain_server() do server
        store = s3_store(server; region = "us-east-1")
        err = (
            @test_throws TransportError "the region 'us-east-1' is wrong" fetch_object(
                store, KEY
            )
        ).value
        @test err.status == 400
    end
end

@testset "put_object_if_absent throws a retryable TransportError for a 500 and a 409" begin
    with_plain_server() do server
        store = s3_store(server)
        server.respond = _ -> (500, [], s3test_error("InternalError", "Please try again."))
        put = () -> put_object_if_absent(store, "k", b"v")
        err = (@test_throws TransportError "InternalError: Please try again." put()).value
        @test err.status == 500
        @test occursin("run the call again later", sprint(showerror, err))
        @test !haskey(server.objects, "k")
        server.respond = _ -> (409, [], s3test_error("ConditionalRequestConflict", "busy"))
        err = (@test_throws TransportError "ConditionalRequestConflict" put()).value
        @test err.status == 409
    end
end

@testset "fetch_object, stat_object, list_objects, put_object_if_absent fail on 403" begin
    calls = [
        (name = "fetch_object", call = store -> fetch_object(store, "k")),
        (name = "stat_object", call = store -> stat_object(store, "k")),
        (name = "list_objects", call = store -> list_objects(store, "")),
        (name = "put", call = store -> put_object_if_absent(store, "k", b"v")),
    ]
    with_plain_server() do server
        store = s3_store(server)
        server.respond = _ -> (403, [], s3test_error("AccessDenied", "Access Denied"))
        @testset "$(case.name)" for case in calls
            err = (@test_throws TransportError "status = 403" case.call(store)).value
            @test err.status == 403
        end
    end
end

@testset "stat_object throws TransportError with the status alone for a HEAD" begin
    with_plain_server() do server
        store = s3_store(server)
        server.respond = _ -> (403, [], s3test_error("AccessDenied", "Access Denied"))
        err = (@test_throws TransportError "status = 403" stat_object(store, "k")).value
        @test err.detail == ""
    end
end

@testset "stat_object throws TransportError for a response it cannot read" begin
    with_plain_server() do server
        store = s3_store(server)
        server.respond = request -> (200, ["last-modified" => "yesterday"], b"x")
        err = (
            @test_throws TransportError "no Content-Length or Last-Modified" stat_object(
                store, "k"
            )
        ).value
        @test err.status == 200
    end
end

@testset "list_objects throws TransportError for a listing it cannot read" begin
    truncated = "<ListBucketResult><IsTruncated>true</IsTruncated></ListBucketResult>"
    no_size = "<ListBucketResult><Contents><Key>k</Key></Contents></ListBucketResult>"
    with_plain_server() do server
        store = s3_store(server)
        server.respond = _ -> (200, [], Vector{UInt8}(truncated))
        @test_throws TransportError "has no NextContinuationToken" list_objects(store, "")
        server.respond = _ -> (200, [], Vector{UInt8}(no_size))
        unreadable = "has no Key, Size or LastModified"
        @test_throws TransportError unreadable list_objects(store, "")
    end
end

@testset "fetch_object throws a retryable TransportError when nothing listens" begin
    port = with_plain_server(server -> server.port)
    store = s3_chain("http://127.0.0.1:$port").store
    err = (@test_throws TransportError "no response" fetch_object(store, "k")).value
    @test err.status === nothing
    @test err.url == "http://127.0.0.1:$port/bkt/k"
    @test occursin("run the call again later", sprint(showerror, err))
end

@testset "create_chain refuses a store that is not AWS S3, before any request" begin
    with_plain_server() do server
        chain = s3_chain(s3test_endpoint(server))
        lifts = "assume_first_writer_wins = true"
        err = (@test_throws UnsupportedStoreError lifts create_chain(chain)).value
        @test err.endpoint == s3test_endpoint(server)
        @test err.detail == "the call was `create_chain`"
        @test isempty(server.requests)
    end
end

@testset "commit! refuses a store that is not AWS S3, every time, before any request" begin
    with_plain_server() do server
        mktempdir() do dir
            promised = s3_chain(
                s3test_endpoint(server); cache_dir = dir, assume_first_writer_wins = true
            )
            create_chain(promised)
            unsure = s3_chain(s3test_endpoint(server); cache_dir = dir)
            local_copy = open(unsure, joinpath(dir, "a"))
            sync!(local_copy)
            n_requests = length(server.requests)
            w = samples_builder(local_copy, [(id = 1, mass = 1.5)])
            err = (@test_throws UnsupportedStoreError "is not AWS S3" commit!(w)).value
            @test err.detail == "the call was `commit!`"
            @test length(server.requests) == n_requests
            @test head(local_copy).slot == 0
            w = samples_builder(local_copy, [(id = 2, mass = 2.5)])
            @test_throws UnsupportedStoreError "is not AWS S3" commit!(w)
            close(local_copy)
        end
    end
end

@testset "commit! writes to a store that is not AWS S3 with assume_first_writer_wins" begin
    with_plain_server() do server
        mktempdir() do dir
            endpoint = s3test_endpoint(server)
            promised = s3_chain(endpoint; cache_dir = dir, assume_first_writer_wins = true)
            create_chain(promised)
            writer = open(promised, joinpath(dir, "b"))
            sync!(writer)
            done = commit!(samples_builder(writer, [(id = 1, mass = 1.5)]))
            @test done.slot == 1
            @test haskey(server.objects, "p/000000000001")
            unsure = s3_chain(endpoint; cache_dir = dir)
            reader = @test_logs open(unsure, joinpath(dir, "a"))
            @test sync!(reader).slot == 1
            @test table(reader, :samples)[1].mass == 1.5
            close(reader)
            close(writer)
        end
    end
end
