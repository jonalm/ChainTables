using Test
using ChainTables: ChainTables, Chain, Credentials, GatewayObjectStore, S3ObjectStore,
    TransportError, WriteRefusedError, create_chain, record_author

include("fixtures/s3_server.jl")
include("fixtures/gateway_server.jl")

const SESSION = Credentials("AKIATEST", "topsecret"; session_token = "session-token")
const OTHER = Credentials("AKIAOTHER", "topsecret"; session_token = "session-token")
const URL = "https://abc.lambda-url.eu-north-1.on.aws"
const ALICE_ARN = "arn:aws:sts::123456789012:assumed-role/" *
    "AWSReservedSSO_chaintables-writer_0123456789abcdef/alice@example.com"
const ROOT_ARN = "arn:aws:iam::123456789012:root"
const NOT_A_PRINCIPAL = "neither an IAM user nor an assumed role"

function sts_store(sts; credentials = SESSION)
    return GatewayObjectStore(
        "bkt", URL; region = "eu-north-1", credentials, sts_endpoint = loopback_url(sts)
    )
end

with_sts(f, arn; credentials = SESSION) =
    with_loopback_server(f, StsDouble(credentials, "eu-north-1", arn))

@testset "record_author on an S3 store is the environment's user" begin
    store = S3ObjectStore("bkt"; region = "eu-north-1", credentials = SESSION)
    withenv("USER" => "carol", "USERNAME" => nothing) do
        @test record_author(store) == "carol"
    end
end

@testset "record_author on a gateway store asks STS, not the environment" begin
    with_sts(ALICE_ARN) do sts
        store = sts_store(sts)
        @test store.author === nothing && isempty(sts.requests)
        withenv("USER" => "carol") do
            @test record_author(store) == "alice@example.com"
        end
        @test (store.author, store.author_key) == ("alice@example.com", "AKIATEST")
    end
end

@testset "record_author signs a GetCallerIdentity POST for sts" begin
    with_sts(ALICE_ARN) do sts
        record_author(sts_store(sts))
        req = only(sts.requests)
        @test (req.method, req.rawpath) == ("POST", "/")
        @test String(copy(req.body)) == "Action=GetCallerIdentity&Version=2011-06-15"
        form = "application/x-www-form-urlencoded; charset=utf-8"
        @test req.headers["content-type"] == form
        @test req.headers["host"] == "127.0.0.1:$(sts.port)"
        signed = "/eu-north-1/sts/aws4_request, SignedHeaders=content-type;host;" *
            "x-amz-content-sha256;x-amz-date;x-amz-security-token,"
        @test occursin(signed, req.headers["authorization"])
    end
end

@testset "record_author is memoized per access key id" begin
    with_sts(ALICE_ARN) do sts
        store = sts_store(sts)
        record_author(store)
        @test record_author(store) == "alice@example.com"
        @test length(sts.requests) == 1
    end
end

@testset "record_author fetches again for another key, and raises an STS refusal" begin
    with_sts("arn:aws:iam::123456789012:user/engineering/erin"; credentials = OTHER) do sts
        calls = Ref(0)
        rotating = () -> (calls[] += 1; calls[] <= 1 ? SESSION : OTHER)
        store = sts_store(sts; credentials = rotating)
        says = "POST http://127.0.0.1:$(sts.port)/"
        e = (@test_throws TransportError says record_author(store)).value
        @test e.status == 403 && store.author === nothing
        @test record_author(store) == "erin"
        @test store.author_key == "AKIAOTHER"
        @test record_author(store) == "erin" && length(sts.requests) == 2
    end
end

@testset "record_author refuses the account root, as the gateway would" begin
    with_sts(ROOT_ARN) do sts
        store = sts_store(sts)
        says = "$ROOT_ARN is $NOT_A_PRINCIPAL"
        e = (@test_throws WriteRefusedError says record_author(store)).value
        @test (e.reason, e.caller) == ("not_allowed", nothing)
        @test store.author === nothing
    end
end

@testset "create_chain refuses the account root for slot 0, writing nothing" begin
    with_sts(ROOT_ARN) do sts
        mktempdir() do dir
            store = sts_store(sts)
            promised = (; assume_first_writer_wins = true)
            chain = Chain("bkt", "p"; store, cache_dir = dir, promised...)
            e = (@test_throws WriteRefusedError NOT_A_PRINCIPAL create_chain(chain)).value
            @test (e.reason, e.slot, e.key) == ("not_allowed", 0, "p/000000000000")
            @test e.chain_id isa String
        end
    end
end

const ARN_CASES = [
    (name = "SSO session", arn = ALICE_ARN, author = "alice@example.com"),
    (name = "IAM user", arn = "arn:aws:iam::123456789012:user/erin", author = "erin"),
    (name = "user, path", arn = "arn:aws:iam::123456789012:user/a/b/eve", author = "eve"),
    (name = "China", arn = "arn:aws-cn:sts::123456789012:assumed-role/R/s", author = "s"),
]

@testset "author_from_arn takes the name: $(case.name)" for case in ARN_CASES
    @test ChainTables.author_from_arn(case.arn) == case.author
end

const REFUSED_ARNS = [
    ROOT_ARN, "arn:aws:iam::123456789012:role/Role", "", "garbage",
    "arn:aws:iam::123456789012:user/erin\n",
]

@testset "author_from_arn refuses $(repr(arn))" for arn in REFUSED_ARNS
    @test_throws WriteRefusedError NOT_A_PRINCIPAL ChainTables.author_from_arn(arn)
end

@testset "author_from_sts_response refuses a reply without an Arn" begin
    says = "sts:GetCallerIdentity returned no Arn"
    @test_throws TransportError says ChainTables.author_from_sts_response(b"<x/>")
end
