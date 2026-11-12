using Test
using ChainTables: ChainTables, Bucket, Chain, Credentials, GatewayObjectStore,
    S3ObjectStore, create_chain, sso_login
using ChainTables.Testing: InMemoryObjectStore

const URL = "https://abc123.lambda-url.eu-north-1.on.aws"
const KEYS = Credentials("AKIATEST", "topsecret"; session_token = "tok")
const GATED = Bucket("bkt"; region = "eu-north-1", gateway = URL)
const NO_SUCH_PROFILE = "chaintables-test-no-such-profile"

@testset "Bucket infers" begin
    b = @inferred Bucket("bkt"; region = "eu-north-1", gateway = URL, profile = "team")
    @test b.name == "bkt"
end

rebuilt(b) = eval(Meta.parse("ChainTables." * sprint(show, b)))

@testset "Bucket holds plain data and shows a value that builds it again" begin
    b = Bucket("bkt"; region = "eu-north-1", gateway = URL, profile = "team")
    @test (b.name, b.region, b.gateway, b.profile) == ("bkt", "eu-north-1", URL, "team")
    @test b == rebuilt(b)
    plain = Bucket("bkt")
    @test (plain.region, plain.gateway, plain.profile) == (nothing, nothing, nothing)
    @test plain == rebuilt(plain)
end

@testset "Bucket coerces its arguments and keeps the gateway as scheme://host[:port]" begin
    sub = Bucket(
        SubString("xbkt", 2); region = SubString("eu-north-1"), gateway = URL * "/",
        profile = SubString("team")
    )
    @test sub == Bucket("bkt"; region = "eu-north-1", gateway = URL, profile = "team")
    @test sub.name isa String
    local_url = "http://127.0.0.1:9999"
    @test Bucket("bkt"; gateway = local_url, region = "us-east-1").gateway == local_url
    @test Bucket("bkt"; gateway = URL).region === nothing
end

const REFUSED_BUCKETS = [
    (name = "empty", make = () -> Bucket(""), says = "the bucket name is empty"),
    (
        name = "dotted", make = () -> Bucket("my.bucket"),
        says = "bucket name \"my.bucket\" contains a dot, which breaks certificate",
    ),
    (
        name = "region against URL",
        make = () -> Bucket("bkt"; region = "us-east-1", gateway = URL),
        says = "region \"us-east-1\" disagrees with the region in the function URL host",
    ),
    (
        name = "empty profile", make = () -> Bucket("bkt"; profile = ""),
        says = "Bucket: profile must not be empty",
    ),
]

@testset "Bucket refuses $(case.name)" for case in REFUSED_BUCKETS
    @test_throws ArgumentError case.says case.make()
end

const BAD_GATEWAYS =
    ["abc123.lambda-url.eu-north-1.on.aws", URL * "/put", URL * "?x=1", "ftp://x"]

@testset "Bucket refuses a gateway $bad" for bad in BAD_GATEWAYS
    says = "gateway $(repr(bad)) is not of the form scheme://host[:port]"
    @test_throws ArgumentError says Bucket("bkt"; gateway = bad)
end

# A field of a chain as compared: the cache by its directory, the store by its print.
function comparable(chain, field)
    field === :cache && return chain.cache.dir
    field === :store && return sprint(show, chain.store)
    return getfield(chain, field)
end

const GATED_SHORT = Chain(
    GATED, "p"; credentials = KEYS, cache_dir = "/c", read_ahead = 3, record_host = false
)

const GATED_LONG = Chain(
    "bkt", "p"; gateway = URL, region = "eu-north-1", credentials = KEYS, cache_dir = "/c",
    read_ahead = 3, record_host = false
)

const PLAIN_BUCKET = Bucket("bkt"; region = "eu-north-1")

const PLAIN_SHORT = Chain(PLAIN_BUCKET, "p"; credentials = KEYS, cache_dir = "/c")

const PLAIN_LONG =
    Chain("bkt", "p"; region = "eu-north-1", credentials = KEYS, cache_dir = "/c")

@testset "Chain of a gateway Bucket is the long form in $f" for f in fieldnames(Chain)
    @test comparable(GATED_SHORT, f) == comparable(GATED_LONG, f)
end

@testset "Chain of a plain Bucket is the long form in $f" for f in fieldnames(Chain)
    @test comparable(PLAIN_SHORT, f) == comparable(PLAIN_LONG, f)
end

@testset "Chain of a Bucket builds the store its gateway asks for" begin
    @test GATED_SHORT isa Chain{GatewayObjectStore}
    @test GATED_SHORT.store.s3.credentials === KEYS
    @test PLAIN_SHORT isa Chain{S3ObjectStore}
end

@testset "Chain of a Bucket without a region takes the environment's" begin
    ungated_region = Bucket("bkt"; gateway = URL)
    withenv("AWS_REGION" => "eu-north-1", "AWS_DEFAULT_REGION" => nothing) do
        chain = Chain(ungated_region, "p"; credentials = KEYS, cache_dir = "/c")
        @test chain.region == "eu-north-1"
    end
    withenv("AWS_REGION" => "us-east-1", "AWS_DEFAULT_REGION" => nothing) do
        says = "region \"us-east-1\" disagrees with the region in the function URL"
        @test_throws ArgumentError says Chain(ungated_region, "p"; credentials = KEYS)
    end
end

const KEY_ENV = (
    "AWS_ACCESS_KEY_ID" => "AKIAX", "AWS_SECRET_ACCESS_KEY" => "s3cret",
    "AWS_SESSION_TOKEN" => nothing,
)

@testset "Chain of a Bucket without a profile reads the environment's credentials" begin
    withenv(KEY_ENV...) do
        chain = Chain(GATED, "p"; cache_dir = "/c")
        @test chain.store.s3.credentials == Credentials("AKIAX", "s3cret")
    end
end

@testset "Chain of a Bucket refuses a region or gateway keyword" begin
    says = "region was given together with a Bucket, which already says it (\"eu-north-1\")"
    @test_throws ArgumentError says Chain(GATED, "p"; region = "r", credentials = KEYS)
    says = "gateway was given together with a Bucket"
    @test_throws ArgumentError says Chain(GATED, "p"; gateway = URL, credentials = KEYS)
    says = "prefix \"p/\" begins or ends with '/'"
    @test_throws ArgumentError says Chain(GATED, "p/"; credentials = KEYS)
end

@testset "Chain of a Bucket with a supplied store does not forward the gateway" begin
    b = Bucket("bkt"; region = "eu-north-1", gateway = URL, profile = "team")
    mktempdir() do dir
        store = InMemoryObjectStore()
        chain = Chain(b, "exp/run-1"; store, cache_dir = joinpath(dir, "cache"))
        @test chain isa Chain{InMemoryObjectStore} && chain.store === store
        @test create_chain(chain).slot == 0
        @test haskey(store.objects, "exp/run-1/000000000000")
    end
end

const PROFILED =
    Bucket("bkt"; region = "eu-north-1", gateway = URL, profile = NO_SUCH_PROFILE)

@testset "Chain of a Bucket with a profile signs with sso_credentials of it" begin
    store = InMemoryObjectStore()
    mktempdir() do dir
        withenv("PATH" => dir) do
            chain = Chain(PROFILED, "p"; store, cache_dir = "/c")
            @test chain.credentials isa Function
            says = "aws sso login --profile $NO_SUCH_PROFILE"
            @test_throws ArgumentError says chain.credentials()
            @test_throws ArgumentError says Chain(PROFILED, "p"; cache_dir = "/c")
            mine = Chain(PROFILED, "p"; store, cache_dir = "/c", profile = "mine")
            @test_throws ArgumentError "aws sso login --profile mine" mine.credentials()
        end
    end
end

@testset "Chain of a Bucket prefers explicit credentials, and no profile to its own" begin
    store = InMemoryObjectStore()
    @test Chain(PROFILED, "p"; store, cache_dir = "/c", profile = nothing).credentials ===
        nothing
    @test Chain(PROFILED, "p"; store, cache_dir = "/c", credentials = KEYS).credentials ===
        KEYS
    chain = Chain(PROFILED, "p"; credentials = KEYS, cache_dir = "/c")
    @test chain.store.s3.credentials === KEYS
end

@testset "sso_login of a Bucket logs in with its profile" begin
    ran = Cmd[]
    team = Bucket("bkt"; profile = "team")
    @test sso_login(team; device_code = true, runner = cmd -> push!(ran, cmd)) === nothing
    @test only(ran) == `aws sso login --profile team --use-device-code`
    @test_throws ArgumentError "has no profile to log in with" sso_login(Bucket("bkt"))
end

@testset "sso_login of a Bucket infers" begin
    team = Bucket("bkt"; profile = "team")
    @test @inferred(sso_login(team; runner = identity)) === nothing
end
