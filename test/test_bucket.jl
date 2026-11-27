# The stores are internal: a test reads `chain.store` and its fields to see what
# `Chain(bucket, prefix)` built.
using Test
using ChainTables: Bucket, Chain, Credentials, CredentialsExportError, create_chain,
    sso_login
using ChainTables.Testing: InMemoryObjectStore

const URL = "https://abc123.lambda-url.eu-north-1.on.aws"
const CREDS = Credentials("AKIATEST", "topsecret"; session_token = "tok")
const GATED = Bucket("bkt"; region = "eu-north-1", gateway = URL)
const NO_PROFILE = "chaintables-test-no-such-profile"

const REFUSED = [
    (name = "an empty name", build = () -> Bucket(""), fragment = "bucket name is empty"),
    (
        name = "a name with a dot", build = () -> Bucket("my.bucket"),
        fragment = "bucket name \"my.bucket\" contains a dot",
    ),
    (
        name = "a gateway in another region",
        build = () -> Bucket("bkt"; region = "us-east-1", gateway = URL),
        fragment = "region \"us-east-1\" disagrees with the region in the function URL",
    ),
    (
        name = "a gateway with a path", build = () -> Bucket("bkt"; gateway = URL * "/put"),
        fragment = "is not of the form scheme://host[:port]",
    ),
    (
        name = "a gateway with no scheme",
        build = () -> Bucket("bkt"; gateway = "abc123.lambda-url.eu-north-1.on.aws"),
        fragment = "is not of the form scheme://host[:port]",
    ),
    (
        name = "an empty profile", build = () -> Bucket("bkt"; profile = ""),
        fragment = "Bucket: profile is empty",
    ),
]

const BUCKET_KEYWORDS = [
    (name = :region, keywords = (; region = "us-east-1"), value = "\"eu-north-1\""),
    (name = :gateway, keywords = (; gateway = URL), value = repr(URL)),
]

# What `Chain(bucket, prefix)` passes on, apart from the record cache.
function chain_summary(chain)
    return (
        chain.bucket, chain.prefix, sprint(show, chain.store), chain.read_ahead,
        chain.record_host, chain.record_user, chain.assume_first_writer_wins,
    )
end

@testset "Bucket infers a Bucket" begin
    @test @inferred(Bucket("bkt"; region = "eu-north-1")) isa Bucket
end

@testset "Bucket holds its name, region, gateway and profile" begin
    b = Bucket("bkt"; region = "eu-north-1", gateway = URL, profile = "team")
    @test (b.name, b.region, b.gateway, b.profile) == ("bkt", "eu-north-1", URL, "team")
end

@testset "Bucket leaves out what it is not given" begin
    b = Bucket("bkt")
    @test (b.region, b.gateway, b.profile) == (nothing, nothing, nothing)
end

@testset "Bucket shows the call that builds it" begin
    b = Bucket("bkt"; region = "eu-north-1", gateway = URL, profile = "team")
    @test sprint(show, b) == "Bucket(\"bkt\"; region = \"eu-north-1\", " *
        "gateway = \"$URL\", profile = \"team\")"
    @test eval(Meta.parse(sprint(show, b))) == b
    @test sprint(show, Bucket("bkt")) ==
        "Bucket(\"bkt\"; region = nothing, gateway = nothing, profile = nothing)"
end

@testset "Bucket converts its arguments to String" begin
    b = Bucket(
        SubString("xbkt", 2); region = SubString("eu-north-1"), gateway = URL,
        profile = SubString("team"),
    )
    @test b == Bucket("bkt"; region = "eu-north-1", gateway = URL, profile = "team")
    @test b.name isa String
end

@testset "Bucket keeps the gateway as scheme://host[:port]" begin
    @test Bucket("bkt"; gateway = URL * "/").gateway == URL
    loopback = Bucket("bkt"; gateway = "http://127.0.0.1:9999", region = "us-east-1")
    @test loopback.gateway == "http://127.0.0.1:9999"
end

@testset "Bucket refuses what Chain would refuse" begin
    @testset "$(case.name)" for case in REFUSED
        @test_throws ArgumentError case.fragment case.build()
    end
end

@testset "Chain with a Bucket is the long form" begin
    keywords = (;
        credentials = CREDS, cache_dir = "/c", read_ahead = 3, record_host = false,
    )
    short = Chain(GATED, "p"; keywords...)
    long = Chain("bkt", "p"; gateway = URL, region = "eu-north-1", keywords...)
    @test chain_summary(short) == chain_summary(long)
    plain = Bucket("bkt"; region = "eu-north-1")
    @test chain_summary(Chain(plain, "p"; credentials = CREDS)) ==
        chain_summary(Chain("bkt", "p"; region = "eu-north-1", credentials = CREDS))
end

@testset "Chain with a Bucket reads the region from the environment when it has none" begin
    withenv("AWS_REGION" => "eu-north-1", "AWS_DEFAULT_REGION" => nothing) do
        chain = Chain(Bucket("bkt"; gateway = URL), "p"; credentials = CREDS)
        @test chain.store.s3.region == "eu-north-1"
    end
end

@testset "Chain with a Bucket refuses an environment region its gateway contradicts" begin
    withenv("AWS_REGION" => "us-east-1", "AWS_DEFAULT_REGION" => nothing) do
        fragment = "region \"us-east-1\" disagrees with the region in the function URL"
        @test_throws ArgumentError fragment Chain(
            Bucket("bkt"; gateway = URL), "p"; credentials = CREDS
        )
    end
end

@testset "Chain with a Bucket and no profile reads the AWS_* credentials" begin
    environment = (
        "AWS_ACCESS_KEY_ID" => "AKIAX", "AWS_SECRET_ACCESS_KEY" => "s3cret",
        "AWS_SESSION_TOKEN" => nothing,
    )
    withenv(environment...) do
        @test Chain(GATED, "p").store.s3.credentials == Credentials("AKIAX", "s3cret")
    end
end

@testset "Chain with a Bucket refuses a region or a gateway of its own" begin
    @testset "$(case.name)" for case in BUCKET_KEYWORDS
        fragment = "$(case.name) was given together with a Bucket, which already says " *
            "it ($(case.value))"
        @test_throws ArgumentError fragment Chain(
            GATED, "p"; credentials = CREDS, case.keywords...
        )
    end
end

@testset "Chain with a Bucket refuses what Chain refuses" begin
    fragment = "prefix \"p/\" begins or ends with '/'"
    @test_throws ArgumentError fragment Chain(GATED, "p/"; credentials = CREDS)
end

@testset "Chain with a Bucket and a store does not pass the gateway" begin
    mktempdir() do dir
        store = InMemoryObjectStore()
        bucket = Bucket("bkt"; region = "eu-north-1", gateway = URL, profile = "team")
        chain = Chain(bucket, "exp/run-1"; store, cache_dir = dir)
        @test chain.store === store
        @test create_chain(chain).slot == 0
    end
end

@testset "Chain with a Bucket takes the credentials of its profile" begin
    bucket = Bucket("bkt"; region = "eu-north-1", gateway = URL, profile = NO_PROFILE)
    fragment = "aws sso login --profile $NO_PROFILE"
    @test_throws CredentialsExportError fragment Chain(bucket, "p")
end

@testset "Chain with a Bucket takes another profile" begin
    fragment = "aws sso login --profile chaintables-test-mine"
    @test_throws CredentialsExportError fragment Chain(
        GATED, "p"; profile = "chaintables-test-mine"
    )
end

@testset "Chain with a Bucket takes credentials over its profile" begin
    bucket = Bucket("bkt"; region = "eu-north-1", gateway = URL, profile = NO_PROFILE)
    @test Chain(bucket, "p"; credentials = CREDS).store.s3.credentials === CREDS
end

@testset "sso_login with a Bucket logs in to its profile" begin
    ran = Cmd[]
    bucket = Bucket("bkt"; profile = "team")
    @test sso_login(bucket; device_code = true, runner = cmd -> push!(ran, cmd)) === nothing
    @test only(ran).exec ==
        ["aws", "sso", "login", "--profile", "team", "--use-device-code"]
end

@testset "sso_login with a Bucket refuses a bucket with no profile" begin
    @test_throws ArgumentError "has no profile to log in with" sso_login(Bucket("bkt"))
end
