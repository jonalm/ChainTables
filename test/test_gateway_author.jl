# `GatewayObjectStore` is internal: a test builds one to point it at the STS double.
using Test
using ChainTables: Credentials, GatewayObjectStore, TransportError, WriteRefusedError,
    record_author

include("fixtures/s3_server.jl")
include("fixtures/gateway_double.jl")

const URL = "https://abc.lambda-url.eu-north-1.on.aws"
const OTHER_CREDS = Credentials("AKIAOTHER", "topsecret"; session_token = "session-token")

const AUTHORS = [
    (name = "an assumed role", arn = GWTEST_ARN, author = ALICE),
    (name = "an IAM user", arn = "arn:aws:iam::123456789012:user/erin", author = "erin"),
    (
        name = "an IAM user with a path", arn = "arn:aws:iam::123456789012:user/a/b/erin",
        author = "erin",
    ),
    (
        name = "another partition",
        arn = "arn:aws-cn:sts::123456789012:assumed-role/R/sess", author = "sess",
    ),
]

const REFUSED_ARNS = [
    "arn:aws:iam::123456789012:root",
    "arn:aws:iam::123456789012:role/Role",
    "",
    "garbage",
    "arn:aws:iam::123456789012:user/erin\n",
]

function sts_store(sts; credentials = GWTEST_CREDS)
    return GatewayObjectStore(
        "bkt", URL; region = "eu-north-1", credentials, sts_endpoint = loopback_url(sts)
    )
end

@testset "record_author of a gateway store is the caller's name, not USER" begin
    with_loopback(StsDouble(GWTEST_CREDS, "eu-north-1", GWTEST_ARN)) do sts
        withenv("USER" => "carol") do
            @test record_author(sts_store(sts)) == ALICE
        end
    end
end

@testset "record_author of a gateway store takes the name from the ARN" begin
    @testset "$(case.name)" for case in AUTHORS
        with_loopback(StsDouble(GWTEST_CREDS, "eu-north-1", case.arn)) do sts
            @test record_author(sts_store(sts)) == case.author
        end
    end
end

@testset "record_author of a gateway store infers a String" begin
    @test Base.infer_return_type(record_author, (GatewayObjectStore,)) == String
end

@testset "record_author of a gateway store asks STS with a POST signed for sts" begin
    with_loopback(StsDouble(GWTEST_CREDS, "eu-north-1", GWTEST_ARN)) do sts
        record_author(sts_store(sts))
        request = only(sts.requests)
        scope = "/eu-north-1/sts/aws4_request, SignedHeaders=content-type;host;" *
            "x-amz-content-sha256;x-amz-date;x-amz-security-token,"
        @test (request.method, request.rawpath) == ("POST", "/")
        @test String(copy(request.body)) == "Action=GetCallerIdentity&Version=2011-06-15"
        @test request.headers["content-type"] ==
            "application/x-www-form-urlencoded; charset=utf-8"
        @test request.headers["host"] == "127.0.0.1:$(sts.port)"
        @test occursin(scope, request.headers["authorization"])
    end
end

@testset "record_author of a gateway store asks STS once per access key id" begin
    with_loopback(StsDouble(OTHER_CREDS, "eu-north-1", GWTEST_ARN)) do sts
        calls = Ref(0)
        rotating = () -> (calls[] += 1) == 1 ? GWTEST_CREDS : OTHER_CREDS
        store = sts_store(sts; credentials = rotating)
        @test_throws TransportError "status = 403" record_author(store)
        @test record_author(store) == ALICE
        @test record_author(store) == ALICE
        @test length(sts.requests) == 2
    end
end

@testset "record_author of a gateway store builds no request at construction" begin
    with_loopback(StsDouble(GWTEST_CREDS, "eu-north-1", GWTEST_ARN)) do sts
        sts_store(sts)
        @test isempty(sts.requests)
    end
end

@testset "record_author of a gateway store refuses a caller that is no user or role" begin
    @testset "$(repr(arn))" for arn in REFUSED_ARNS
        with_loopback(StsDouble(GWTEST_CREDS, "eu-north-1", arn)) do sts
            store = sts_store(sts)
            fragment = "is neither an IAM user nor an assumed role"
            e = (@test_throws WriteRefusedError fragment record_author(store)).value
            @test (e.reason, e.gateway, e.caller) == ("not_allowed", URL, nothing)
            @test e.detail == "the caller $arn is neither an IAM user nor an assumed role"
        end
    end
end

@testset "record_author of a gateway store throws TransportError when STS refuses" begin
    with_loopback(StsDouble(OTHER_CREDS, "eu-north-1", GWTEST_ARN)) do sts
        store = sts_store(sts)
        e = (@test_throws TransportError "a request failed" record_author(store)).value
        @test (e.method, e.url, e.status) == ("POST", loopback_url(sts) * "/", 403)
    end
end

@testset "record_author of a gateway store throws TransportError for no Arn" begin
    with_loopback(_ -> (200, [], Vector{UInt8}("<x/>"))) do sts
        fragment = "the sts:GetCallerIdentity response has no Arn"
        e = (@test_throws TransportError fragment record_author(sts_store(sts))).value
        @test (e.method, e.status) == ("POST", 200)
    end
end
