# `GatewayObjectStore` is internal, like `S3ObjectStore`: a test builds one to point it at
# the loopback doubles (`sts_endpoint`, a short `timeout`), and reads its fields where
# `Chain` is the only way to see what was built.
using Test
using ChainTables: Chain, Credentials, GatewayMismatchError, GatewayObjectStore,
    PutOutcome, TransportError, UnsupportedStoreError, WriteRefusedError, create_chain,
    fetch_object, list_objects, put_object_if_absent, record_author, stat_object

include("fixtures/s3_server.jl")
include("fixtures/gateway.jl")
include("fixtures/gateway_double.jl")

const URL = "https://abc123.lambda-url.eu-north-1.on.aws"
const CREDS = Credentials("AKIATEST", "topsecret"; session_token = "tok")
const KEY = "p/000000000001"
const RECORD = gwtest_record(ALICE)
const RETRY_LATER = "The failure may pass"
const NO_RETRY = "A retry will not help"

const BAD_URLS =
    ["abc123.lambda-url.eu-north-1.on.aws", URL * "/put", URL * "?x=1", "ftp://x"]

const REFUSALS = [
    (
        name = "a caller outside the policy", caller = "bob@example.com", respond = nothing,
        credentials = GWTEST_CREDS, user = "bob@example.com", reason = "not_allowed",
        detail = "bob@example.com may not write under p",
    ),
    (
        name = "a record that names another author", caller = ALICE, respond = nothing,
        credentials = GWTEST_CREDS, user = "mallory", reason = "author_mismatch",
        detail = "the record names 'mallory' as client.user but the caller is '$ALICE'",
    ),
    (
        name = "a signature that AWS refuses", caller = ALICE, respond = nothing,
        credentials = Credentials("AKIATEST", "nope"; session_token = "session-token"),
        user = ALICE, reason = "forbidden", detail = "Forbidden",
    ),
    (
        name = "an expired token", caller = ALICE,
        respond = _ -> (403, [], Vector{UInt8}("{\"message\":\"The token is expired\"}")),
        credentials = GWTEST_CREDS, user = ALICE, reason = "forbidden",
        detail = "The token is expired",
    ),
    (
        name = "S3 refusing the gateway's own put", caller = ALICE,
        respond = _ -> gwtest_json(502, "s3_refused", "S3 answered 403 AccessDenied"),
        credentials = GWTEST_CREDS, user = ALICE, reason = "s3_refused",
        detail = "S3 answered 403 AccessDenied",
    ),
    (
        name = "a code this client does not know", caller = ALICE,
        respond = _ -> gwtest_json(403, "brand_new", "a newer gateway's reason"),
        credentials = GWTEST_CREDS, user = ALICE, reason = "brand_new",
        detail = "a newer gateway's reason",
    ),
]

const FAILURES = [
    (
        name = "not a slot", key = "p/genesis", bytes = RECORD, respond = nothing,
        status = 400, detail = "not_a_slot: p/genesis is not a slot", next_move = NO_RETRY,
    ),
    (
        name = "not a CBOR map", key = KEY, bytes = b"not cbor", respond = nothing,
        status = 400, detail = "not_cbor_map: the body is not a CBOR map",
        next_move = NO_RETRY,
    ),
    (
        name = "no author", key = KEY, bytes = gwtest_record(""), respond = nothing,
        status = 400, detail = "no_author: client.user is absent", next_move = NO_RETRY,
    ),
    (
        name = "too large", key = KEY, bytes = RECORD,
        respond = _ -> gwtest_json(413, "too_large", "4194305 bytes"), status = 413,
        detail = "too_large: 4194305 bytes", next_move = NO_RETRY,
    ),
    (
        name = "a conflict", key = KEY, bytes = RECORD,
        respond = _ -> gwtest_json(409, "conflict", "S3 409"), status = 409,
        detail = "conflict: S3 409", next_move = RETRY_LATER,
    ),
    (
        name = "Lambda's throttle", key = KEY, bytes = RECORD,
        respond = _ -> (429, [], Vector{UInt8}("{\"Message\":\"Rate Exceeded.\"}")),
        status = 429, detail = "Rate Exceeded.", next_move = RETRY_LATER,
    ),
    (
        name = "an S3 error", key = KEY, bytes = RECORD,
        respond = _ -> gwtest_json(502, "s3_error", "S3 said \"InternalError\"\n"),
        status = 502, detail = "s3_error: S3 said \"InternalError\"\n",
        next_move = RETRY_LATER,
    ),
    (
        name = "an empty reply", key = KEY, bytes = RECORD,
        respond = _ -> (503, [], UInt8[]), status = 503, detail = "",
        next_move = RETRY_LATER,
    ),
    (
        name = "an empty JSON object", key = KEY, bytes = RECORD,
        respond = _ -> (504, [], Vector{UInt8}("{}")), status = 504, detail = "",
        next_move = RETRY_LATER,
    ),
]

# The message as the gateway's JSON writes it, and as the refusal holds it.
const ESCAPES = [
    (name = "a surrogate pair", json = "a\\ud83d\\ude00b", text = "a😀b"),
    (name = "simple escapes", json = "\\u00e9\\n\\\"\\/", text = "é\n\"/"),
    (name = "a bad hex digit", json = "x\\uZZZZ y", text = "x\\uZZZZ y"),
    (name = "a lone high surrogate", json = "lone \\ud83d end", text = "lone \\ud83d end"),
    (name = "a low surrogate first", json = "\\ude00 low", text = "\\ude00 low"),
    (name = "a short escape at the end", json = "tail\\u12", text = "tail\\u12"),
    (name = "a high surrogate before é", json = "\\ud83dé", text = "\\ud83dé"),
    (name = "a backslash at the end", json = "end\\\\", text = "end\\"),
]

const MISMATCHES = [
    (name = "absent", held = nothing, detail = "the bucket does not hold the key"),
    (
        name = "another record", held = b"someone else's record",
        detail = "the bucket holds another record there, 21 bytes, not the " *
            "$(length(RECORD)) sent",
    ),
]

put_record(store; key = KEY, bytes = RECORD) = put_object_if_absent(store, key, bytes)

closed_port() = with_loopback(server -> server.port, _ -> nothing)

@testset "Chain with a gateway builds a store over the bucket's S3" begin
    chain = Chain("bkt", "p"; gateway = URL, region = "eu-north-1", credentials = CREDS)
    store = chain.store
    @test chain isa Chain{GatewayObjectStore}
    @test store.function_url == URL
    @test store.host == "abc123.lambda-url.eu-north-1.on.aws"
    @test store.s3.bucket == "bkt"
    @test store.s3.region == "eu-north-1"
    @test store.s3.credentials === CREDS
    @test store.sts_endpoint == "https://sts.eu-north-1.amazonaws.com"
end

@testset "Chain with a gateway asks STS of the China partition in a cn- region" begin
    url = "https://abc.lambda-url.cn-north-1.on.aws"
    chain = Chain("bkt", "p"; gateway = url, region = "cn-north-1", credentials = CREDS)
    @test chain.store.sts_endpoint == "https://sts.cn-north-1.amazonaws.com.cn"
end

@testset "Chain with a gateway shows the store's type, and the store hides the secret" begin
    chain = Chain("bkt", "p"; gateway = URL, region = "eu-north-1", credentials = CREDS)
    @test sprint(show, chain) == "Chain(\"bkt\", \"p\"; store = GatewayObjectStore)"
    @test sprint(show, chain.store) ==
        "GatewayObjectStore(\"bkt\", \"$URL\"; region = \"eu-north-1\")"
end

@testset "Chain with a gateway shows the store's endpoint and addressing" begin
    chain = Chain(
        "bkt", "p"; gateway = URL, region = "eu-north-1", credentials = CREDS,
        endpoint = "http://127.0.0.1:9000", path_style = true,
    )
    @test sprint(show, chain.store) ==
        "GatewayObjectStore(\"bkt\", \"$URL\"; region = \"eu-north-1\", " *
        "endpoint = \"http://127.0.0.1:9000\", path_style = true)"
end

@testset "Chain with a gateway keeps the function URL as scheme://host[:port]" begin
    chain = Chain(
        "bkt", "p"; gateway = URL * "/", region = "eu-north-1", credentials = CREDS
    )
    @test chain.store.function_url == URL
    loopback = Chain(
        "bkt", "p"; gateway = "http://127.0.0.1:9999", region = "us-east-1",
        credentials = CREDS,
    )
    @test loopback.store.host == "127.0.0.1:9999"
end

@testset "Chain refuses a gateway whose host names another region" begin
    fragment = "region \"us-east-1\" disagrees with the region in the function URL host"
    @test_throws ArgumentError fragment Chain(
        "bkt", "p"; gateway = URL, region = "us-east-1", credentials = CREDS
    )
end

@testset "Chain refuses a gateway that is not scheme://host[:port]" begin
    @testset "$(repr(bad))" for bad in BAD_URLS
        fragment = "gateway $(repr(bad)) is not of the form scheme://host[:port]"
        @test_throws ArgumentError fragment Chain(
            "bkt", "p"; gateway = bad, region = "eu-north-1", credentials = CREDS
        )
    end
end

@testset "Chain refuses record_user = false with a gateway" begin
    fragment = "record_user = false with a gateway: the gateway refuses a record with " *
        "no author"
    @test_throws ArgumentError fragment Chain(
        "bkt", "p"; gateway = URL, region = "eu-north-1", credentials = CREDS,
        record_user = false,
    )
    store = GatewayObjectStore("bkt", URL; region = "eu-north-1", credentials = CREDS)
    @test_throws ArgumentError fragment Chain("bkt", "p"; store, record_user = false)
end

@testset "Chain with a gateway reads the region and credentials from the environment" begin
    environment = (
        "AWS_ACCESS_KEY_ID" => "AKIAX", "AWS_SECRET_ACCESS_KEY" => "s3cret",
        "AWS_SESSION_TOKEN" => nothing, "AWS_REGION" => "eu-north-1",
    )
    withenv(environment...) do
        store = Chain("bkt", "p"; gateway = URL).store
        @test store.s3.credentials == Credentials("AKIAX", "s3cret")
        @test store.s3.region == "eu-north-1"
    end
end

@testset "Chain with a gateway and no region anywhere is refused" begin
    withenv("AWS_REGION" => nothing, "AWS_DEFAULT_REGION" => nothing) do
        @test_throws ArgumentError "the S3 store needs a region" Chain(
            "bkt", "p"; gateway = URL, credentials = CREDS
        )
    end
end

@testset "create_chain through a gateway over a store that is not AWS is refused" begin
    endpoint = "http://127.0.0.1:9000"
    chain = Chain(
        "bkt", "p"; gateway = URL, region = "eu-north-1", credentials = CREDS, endpoint,
        path_style = true,
    )
    fragment = "the call was `create_chain`\n  endpoint = $endpoint"
    @test_throws UnsupportedStoreError fragment create_chain(chain)
end

@testset "put_object_if_absent through a gateway creates a slot only once" begin
    with_gateway() do world
        store = gateway_store(world)
        @test put_record(store) == PutOutcome(true, 200)
        @test put_record(store; bytes = gwtest_record(ALICE)) == PutOutcome(false, 412)
        @test world.s3.objects[KEY] == RECORD
    end
end

@testset "put_object_if_absent through a gateway sends a PUT signed for lambda" begin
    with_gateway() do world
        put_record(gateway_store(world))
        put = only(world.gateway.requests)
        scope = "/eu-north-1/lambda/aws4_request, SignedHeaders=content-type;host;" *
            "x-amz-content-sha256;x-amz-date;x-amz-security-token,"
        @test (put.method, put.rawpath, put.query) == ("PUT", "/", ["key" => KEY])
        @test put.body == RECORD
        @test put.headers["content-type"] == "application/cbor"
        @test put.headers["host"] == "127.0.0.1:$(world.gateway.port)"
        @test put.headers["x-amz-security-token"] == "session-token"
        @test occursin(scope, put.headers["authorization"])
        @test !haskey(put.headers, "if-none-match")
    end
end

@testset "put_object_if_absent through a gateway encodes the key once" begin
    with_gateway() do world
        key = "p/a b\$c/000000000002"
        store = gateway_store(world)
        put_record(store; key)
        @test haskey(world.s3.objects, key)
        world.double.respond = _ -> (503, [], UInt8[])
        e = (@test_throws TransportError "a request failed" put_record(store; key)).value
        @test endswith(e.url, "/?key=p%2Fa%20b%24c%2F000000000002")
    end
end

@testset "fetch_object, stat_object and list_objects of a gateway store go to S3" begin
    with_gateway() do world
        store = gateway_store(world)
        s3test_store!(world.s3, KEY, RECORD)
        @test fetch_object(store, KEY) == RECORD
        @test stat_object(store, KEY).size == length(RECORD)
        @test [meta.key for meta in list_objects(store, "p/")] == [KEY]
        @test isempty(world.gateway.requests)
    end
end

@testset "put_object_if_absent through a gateway throws WriteRefusedError" begin
    @testset "$(case.name)" for case in REFUSALS
        with_gateway() do world
            world.double.caller = case.caller
            world.double.respond = something(case.respond, _ -> nothing)
            store = gateway_store(world; case.credentials)
            put = () -> put_record(store; bytes = gwtest_record(case.user))
            e = (@test_throws WriteRefusedError "the gateway refused the write" put()).value
            @test (e.reason, e.detail) == (case.reason, case.detail)
            @test (e.key, e.caller) == (KEY, nothing)
            @test e.gateway == loopback_url(world.gateway)
            @test !haskey(world.s3.objects, KEY)
        end
    end
end

@testset "put_object_if_absent through a gateway names the author it has fetched" begin
    with_gateway() do world
        store = gateway_store(world)
        record_author(store)
        world.double.caller = "bob@example.com"
        e = (@test_throws WriteRefusedError "the gateway refused" put_record(store)).value
        @test e.caller == ALICE
    end
end

@testset "put_object_if_absent through a gateway throws TransportError on other codes" begin
    @testset "$(case.name)" for case in FAILURES
        with_gateway() do world
            world.double.respond = something(case.respond, _ -> nothing)
            store = gateway_store(world)
            put = () -> put_record(store; case.key, case.bytes)
            e = (@test_throws TransportError "a request failed" put()).value
            @test (e.method, e.status, e.detail) == ("PUT", case.status, case.detail)
            @test startswith(e.url, loopback_url(world.gateway) * "/?key=")
            @test startswith(last(split(sprint(showerror, e), "\n")), case.next_move)
        end
    end
end

@testset "put_object_if_absent through a gateway reads the escapes of a message" begin
    @testset "$(case.name)" for case in ESCAPES
        with_gateway() do world
            body = "{\"code\": \"not_allowed\", \"message\": \"$(case.json)\"}"
            world.double.respond = _ -> (403, [], Vector{UInt8}(body))
            store = gateway_store(world)
            e = (@test_throws WriteRefusedError "refused" put_record(store)).value
            @test e.detail == case.text
            @test isvalid(e.detail)
        end
    end
end

@testset "put_object_if_absent through a gateway refuses over 4 MiB before a request" begin
    with_gateway() do world
        bytes = zeros(UInt8, 4 * 1024 * 1024 + 1)
        fragment = "4194305 bytes for $KEY is over the gateway's 4 MiB record cap"
        @test_throws ArgumentError fragment put_record(gateway_store(world); bytes)
        @test isempty(world.gateway.requests)
    end
end

@testset "put_object_if_absent through a gateway that does not answer may be retried" begin
    port = closed_port()
    dead = GatewayObjectStore(
        "bkt", "http://127.0.0.1:$port"; region = "eu-north-1", credentials = GWTEST_CREDS,
        timeout = 5,
    )
    e = (@test_throws TransportError RETRY_LATER put_record(dead)).value
    @test e.status === nothing
    @test e.url == "http://127.0.0.1:$port/?key=p%2F000000000001"
    @test startswith(e.detail, "no response")
end

@testset "put_object_if_absent through a gateway filling another bucket is a mismatch" begin
    @testset "$(case.name)" for case in MISMATCHES
        with_s3_server(; bucket = "bkt", credentials = GWTEST_CREDS) do ours
            case.held === nothing || s3test_store!(ours, KEY, case.held)
            with_gateway(; bucket = "other") do world
                put = () -> put_record(gateway_store(world; s3 = ours))
                e = (@test_throws GatewayMismatchError "does not act as" put()).value
                @test (e.key, e.bucket) == (KEY, "bkt")
                @test e.gateway == loopback_url(world.gateway)
                @test e.detail == "the gateway answered 200 created, and " * case.detail
                @test haskey(world.s3.objects, KEY)
            end
        end
    end
end
