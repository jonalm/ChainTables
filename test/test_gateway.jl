using Test
using ChainTables: ChainTables, Chain, Credentials, GatewayMismatchError,
    GatewayObjectStore, PutOutcome, S3ObjectStore, TransportError, WriteRefusedError,
    fetch_object, list_objects, put_object_if_absent, stat_object

include("fixtures/s3_server.jl")
include("fixtures/gateway_server.jl")
include("fixtures/gateway.jl")

const KEYS = Credentials("AKIATEST", "topsecret"; session_token = "tok")
const SESSION = Credentials("AKIATEST", "topsecret"; session_token = "session-token")
const URL = "https://abc123.lambda-url.eu-north-1.on.aws"
const ALICE = "alice@example.com"
const SLOT = "p/000000000003"
const RECORD = gateway_test_record(ALICE)

function gateway_chain(; kw...)
    return Chain(
        "bkt", "p"; gateway = URL, region = "eu-north-1", credentials = KEYS,
        cache_dir = "/c", kw...
    )
end

gateway_store(url; kw...) = GatewayObjectStore("bkt", url; credentials = KEYS, kw...)

@testset "GatewayObjectStore infers" begin
    store = @inferred gateway_store(URL; region = "eu-north-1")
    @test (store.s3.bucket, store.timeout) == ("bkt", 60)
end

@testset "Chain with a gateway builds a GatewayObjectStore, no I/O" begin
    chain = gateway_chain()
    @test chain isa Chain{GatewayObjectStore} && chain.record_user
    store = chain.store
    @test (store.function_url, store.host) == (URL, "abc123.lambda-url.eu-north-1.on.aws")
    @test store.s3 isa S3ObjectStore
    @test (store.s3.bucket, store.s3.region) == ("bkt", "eu-north-1")
    @test store.s3.credentials === KEYS && ChainTables.is_aws(store)
    @test store.sts_endpoint == "https://sts.eu-north-1.amazonaws.com"
    shown = "GatewayObjectStore(\"bkt\", \"$URL\"; region = \"eu-north-1\")"
    @test sprint(show, store) == shown
end

@testset "GatewayObjectStore finds STS in the China partition" begin
    store = gateway_store("https://abc.lambda-url.cn-north-1.on.aws"; region = "cn-north-1")
    @test store.sts_endpoint == "https://sts.cn-north-1.amazonaws.com.cn"
end

@testset "GatewayObjectStore keeps the function URL as scheme://host[:port]" begin
    @test gateway_chain(; gateway = URL * "/").store.function_url == URL
    @test gateway_store("http://127.0.0.1:9999"; region = "us-east-1").host ==
        "127.0.0.1:9999"
end

const BAD_URLS =
    ["abc123.lambda-url.eu-north-1.on.aws", URL * "/put", URL * "?x=1", "ftp://x"]

@testset "Chain refuses a gateway $bad" for bad in BAD_URLS
    says = "gateway $(repr(bad)) is not of the form scheme://host[:port]"
    @test_throws ArgumentError says gateway_chain(; gateway = bad)
end

@testset "Chain refuses a region the function URL contradicts" begin
    says = "region \"us-east-1\" disagrees with the region in the function URL"
    @test_throws ArgumentError says gateway_chain(; region = "us-east-1")
end

@testset "GatewayObjectStore refuses a dotted bucket" begin
    says = "bucket name \"my.bucket\" contains a dot"
    make = () -> GatewayObjectStore("my.bucket", URL; region = "r", credentials = KEYS)
    @test_throws ArgumentError says make()
end

const KEY_ENV = (
    "AWS_ACCESS_KEY_ID" => "AKIAX", "AWS_SECRET_ACCESS_KEY" => "s3cret",
    "AWS_SESSION_TOKEN" => nothing, "AWS_REGION" => "eu-north-1",
)

@testset "Chain resolves a gateway store's region and credentials as for S3" begin
    withenv(KEY_ENV...) do
        endpoint = "http://127.0.0.1:9000"
        chain = Chain("bkt", "p"; gateway = URL, endpoint, path_style = true)
        @test chain.store.s3.credentials == Credentials("AKIAX", "s3cret")
        @test chain.store.s3.base == endpoint && chain.store.s3.path_style
        @test !ChainTables.is_aws(chain.store)
        @test ChainTables.unsupported_store(chain)
    end
    withenv("AWS_REGION" => nothing, "AWS_DEFAULT_REGION" => nothing) do
        says = "region is required by the S3 client"
        @test_throws ArgumentError says Chain("bkt", "p"; gateway = URL, credentials = KEYS)
    end
end

@testset "GatewayObjectStore caps a record at 4 MiB" begin
    store = gateway_store(URL; region = "eu-north-1")
    @test ChainTables.record_cap(store) == 4 * 1024 * 1024
    @test ChainTables.record_cap(store.s3) == 64 * 1024 * 1024
end

# A gateway double over a loopback S3, and a store that writes through it.
function with_gateway(f; caller = ALICE)
    return with_gateway_doubles(SESSION, caller, ["p" => [ALICE]]; arn = "") do d
        f(d.store, d.s3, d.double, d.gw)
    end
end

@testset "GatewayObjectStore reads from S3 and never from the gateway" begin
    with_gateway() do store, s3, double, gw
        key = "p/000000000001"
        @test fetch_object(store, key) === nothing && stat_object(store, key) === nothing
        @test isempty(list_objects(store, "p/"))
        @test isempty(gw.requests) && length(s3.requests) == 3
    end
end

@testset "put_object_if_absent fills a slot through the gateway once" begin
    with_gateway() do store, s3, double, gw
        key = "p/000000000001"
        @test put_object_if_absent(store, key, RECORD) == PutOutcome(true, 200)
        again = gateway_test_record(ALICE)
        @test put_object_if_absent(store, key, again) == PutOutcome(false, 412)
        @test s3.objects[key] == RECORD && fetch_object(store, key) == RECORD
        @test stat_object(store, key).size == length(RECORD)
        @test [m.key for m in list_objects(store, "p/")] == [key]
    end
end

@testset "put_object_if_absent signs a PUT to /?key= for lambda" begin
    with_gateway() do store, s3, double, gw
        put_object_if_absent(store, "p/000000000001", RECORD)
        put = only(gw.requests)
        @test (put.method, put.rawpath) == ("PUT", "/")
        @test put.query == ["key" => "p/000000000001"]
        @test put.headers["content-type"] == "application/cbor"
        @test put.headers["content-length"] == string(length(RECORD))
        @test put.headers["x-amz-security-token"] == "session-token"
        @test put.headers["host"] == "127.0.0.1:$(gw.port)"
        signed = "/eu-north-1/lambda/aws4_request, SignedHeaders=content-type;host;" *
            "x-amz-content-sha256;x-amz-date;x-amz-security-token,"
        @test occursin(signed, put.headers["authorization"])
        @test !haskey(put.headers, "if-none-match")
    end
end

@testset "put_object_if_absent encodes the key in the query once, slash included" begin
    with_gateway() do store, s3, double, gw
        @test put_object_if_absent(store, "p/a b\$c/000000000002", RECORD).created
        @test gw.requests[end].rawquery == "key=p%2Fa%20b%24c%2F000000000002"
    end
end

@testset "put_object_if_absent raises a policy refusal as WriteRefusedError" begin
    with_gateway(; caller = "bob@example.com") do store, s3, double, gw
        says = "refused to fill the slot: bob@example.com may not write under p"
        bob = gateway_test_record("bob@example.com")
        call = () -> put_object_if_absent(store, SLOT, bob)
        e = (@test_throws WriteRefusedError says call()).value
        @test (e.reason, e.key, e.caller) == ("not_allowed", SLOT, nothing)
        @test occursin("the gateway at $(loopback_url(gw))", sprint(showerror, e))
        @test !haskey(s3.objects, SLOT)
    end
end

@testset "put_object_if_absent raises an author mismatch as WriteRefusedError" begin
    with_gateway() do store, s3, double, gw
        says = "the record names 'mallory' as client.user but the caller is '$ALICE'"
        mallory = gateway_test_record("mallory")
        call = () -> put_object_if_absent(store, SLOT, mallory)
        e = (@test_throws WriteRefusedError says call()).value
        @test e.reason == "author_mismatch"
    end
end

@testset "put_object_if_absent raises AWS's bare 403 as forbidden" begin
    with_gateway() do store, s3, double, gw
        wrong = GatewayObjectStore(
            "bkt", loopback_url(gw); region = "eu-north-1",
            credentials = Credentials("AKIATEST", "nope"; session_token = "session-token"),
            endpoint = s3test_endpoint(s3), path_style = true
        )
        says = "(HTTP 403 with no gateway code): Forbidden."
        call = () -> put_object_if_absent(wrong, SLOT, RECORD)
        e = (@test_throws WriteRefusedError says call()).value
        @test e.reason == "forbidden"
        aws = "AWS refused the invocation of $(loopback_url(gw))"
        @test occursin(aws, sprint(showerror, e))
    end
end

const EXPIRED = "The security token included in the request is expired"

const REFUSAL_REPLIES = [
    (
        name = "an expired token",
        reply = (403, Pair{String, String}[], Vector{UInt8}("{\"message\":\"$EXPIRED\"}")),
        reason = "forbidden", says = "(HTTP 403 with no gateway code): $EXPIRED.",
    ),
    (
        name = "S3 refusing the gateway",
        reply = gwtest_json(502, "s3_refused", "S3 answered 403 AccessDenied"),
        reason = "s3_refused", says = "S3 refused the gateway's own put, so the gateway's",
    ),
    (
        name = "an unknown reason", reply = gwtest_json(403, "brand_new", "a new reason"),
        reason = "brand_new", says = "a reason this client does not know: a new reason.",
    ),
]

@testset "put_object_if_absent raises $(case.name) as WriteRefusedError" for case in
    REFUSAL_REPLIES
    with_gateway() do store, s3, double, gw
        double.respond = _ -> case.reply
        put = () -> put_object_if_absent(store, SLOT, RECORD)
        e = (@test_throws WriteRefusedError case.says put()).value
        @test e.reason == case.reason
    end
end

const CLIENT_BUGS = [
    (name = "not a slot", key = "p/genesis", record = RECORD, code = "not_a_slot"),
    (name = "not CBOR", key = SLOT, record = b"not cbor", code = "not_cbor_map"),
    (name = "no author", key = SLOT, record = gateway_test_record(""), code = "no_author"),
]

@testset "put_object_if_absent raises a client bug: $(case.name)" for case in CLIENT_BUGS
    with_gateway() do store, s3, double, gw
        put = () -> put_object_if_absent(store, case.key, case.record)
        e = (@test_throws TransportError "$(case.code): " put()).value
        @test e.status == 400
    end
end

@testset "put_object_if_absent refuses a record over the cap before any request" begin
    with_gateway() do store, s3, double, gw
        says = "4194305 bytes for $SLOT is over the gateway's 4 MiB record cap"
        big = zeros(UInt8, 4 * 1024 * 1024 + 1)
        @test_throws ArgumentError says put_object_if_absent(store, SLOT, big)
        @test isempty(gw.requests)
    end
end

const NO_PAIRS = Pair{String, String}[]

const TRANSIENT_REPLIES = [
    (name = "413", reply = gwtest_json(413, "too_large", "4 MiB"), says = "too_large"),
    (name = "409", reply = gwtest_json(409, "conflict", "S3 409"), says = "conflict: S3"),
    (
        name = "429", reply = (429, NO_PAIRS, Vector{UInt8}("{\"Message\":\"Slow down\"}")),
        says = "/?key=p%2F000000000003.",
    ),
    (
        name = "502 with escapes", reply = gwtest_json(502, "s3_error", "said \"Oops\"\n"),
        says = "s3_error: said \"Oops\"\n",
    ),
    (name = "503 empty", reply = (503, NO_PAIRS, UInt8[]), says = "%2F000000000003."),
    (name = "504 {}", reply = (504, NO_PAIRS, b"{}"), says = "a request failed"),
]

@testset "put_object_if_absent raises a $(case.name) with its status" for case in
    TRANSIENT_REPLIES
    with_gateway() do store, s3, double, gw
        double.respond = _ -> case.reply
        put = () -> put_object_if_absent(store, SLOT, RECORD)
        e = (@test_throws TransportError case.says put()).value
        @test e.status == case.reply[1]
    end
end

@testset "put_object_if_absent raises no response as TransportError without status" begin
    with_gateway() do store, s3, double, gw
        closed = LoopbackServer(Returns(nothing))
        port = closed.port
        close(closed)
        dead = GatewayObjectStore(
            "bkt", "http://127.0.0.1:$port"; region = "eu-north-1", credentials = SESSION,
            endpoint = s3test_endpoint(s3), path_style = true, timeout = 5
        )
        says = "PUT http://127.0.0.1:$port/?key=p%2F000000000003: no response"
        call = () -> put_object_if_absent(dead, SLOT, RECORD)
        e = (@test_throws TransportError says call()).value
        @test e.status === nothing
    end
end

# A gateway double that fills another bucket than the one the store reads.
function with_mispaired_gateway(f)
    doubles = (SESSION, ALICE, ["exp" => [ALICE]])
    return with_gateway_doubles(doubles...; arn = "", filled_bucket = "other") do d
        f(d.store, d.s3, d.filled, d.gw)
    end
end

@testset "put_object_if_absent raises a gateway that fills another bucket" begin
    with_mispaired_gateway() do store, ours, theirs, gw
        key = "exp/run-1/000000000000"
        says = "answered 200 created, and the bucket does not hold the object"
        call = () -> put_object_if_absent(store, key, RECORD)
        e = (@test_throws GatewayMismatchError says call()).value
        @test (e.key, e.bucket, e.gateway) == (key, "bkt", loopback_url(gw))
        @test haskey(theirs.objects, key) && !haskey(ours.objects, key)
    end
end

@testset "put_object_if_absent raises another record in our bucket as a mismatch" begin
    with_mispaired_gateway() do store, ours, theirs, gw
        key = "exp/run-3/000000000000"
        s3test_store!(ours, key, b"someone else's record")
        says = "holds another object there (21 bytes"
        @test_throws GatewayMismatchError says put_object_if_absent(store, key, RECORD)
    end
end
