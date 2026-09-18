# ADR-0029 (issue #63) — `Bucket`: the bucket, its region, its gateway and the profile that
# reaches it as one plain value; `Chain(bucket, prefix)` is the long form field for field;
# `sso_login(bucket)`. Nothing reaches AWS: placeholders only, and the CLI is never run.
using ChainTables: Bucket, Chain, Credentials, S3ObjectStore, GatewayObjectStore
using ChainTables.Testing: InMemoryObjectStore

@testset "bucket" begin
    CT = ChainTables
    url = "https://abc123.lambda-url.eu-north-1.on.aws"
    creds = Credentials("AKIATEST", "topsecret"; session_token = "tok")

    @testset "construction: plain data, coerced, shown whole; each refusal" begin
        b = Bucket("bkt"; region = "eu-north-1", gateway = url, profile = "team")
        @test (b.name, b.region, b.gateway, b.profile) == ("bkt", "eu-north-1", url, "team")
        @test sprint(show, b) == "Bucket(\"bkt\"; region = \"eu-north-1\", gateway = \"$url\", profile = \"team\")"
        @test b == eval(Meta.parse("ChainTables." * sprint(show, b)))           # what is shown builds the same value
        plain = Bucket("bkt")
        @test (plain.region, plain.gateway, plain.profile) == (nothing, nothing, nothing)
        @test sprint(show, plain) == "Bucket(\"bkt\"; region = nothing, gateway = nothing, profile = nothing)"
        # unconstrained arguments, the fields coerce; the gateway is kept as scheme://host[:port]
        sub = Bucket(SubString("xbkt", 2); region = SubString("eu-north-1"), gateway = url * "/", profile = SubString("team"))
        @test sub == b && sub.name isa String && sub.gateway == url
        @test Bucket("bkt"; gateway = "http://127.0.0.1:9999", region = "us-east-1").gateway == "http://127.0.0.1:9999"
        @test Bucket("bkt"; gateway = url).region === nothing                   # no region yet: Chain's rule decides, and checks
        # the refusals are Chain's, message for message
        @test_throws "the bucket name is empty" Bucket("")
        @test_throws "bucket name \"my.bucket\" contains a dot, which breaks certificate matching" Bucket("my.bucket")
        @test_throws "region \"us-east-1\" disagrees with the region in the function URL host" Bucket("bkt"; region = "us-east-1", gateway = url)
        for bad in ("abc123.lambda-url.eu-north-1.on.aws", url * "/put", url * "?x=1", "ftp://x")
            @test_throws "gateway $(repr(bad)) is not of the form scheme://host[:port]" Bucket("bkt"; gateway = bad)
        end
        @test_throws "Bucket: profile must not be empty" Bucket("bkt"; profile = "")
    end

    @testset "Chain(bucket, prefix) is the long form, field for field" begin
        same(a, b) = all(f -> f === :cache ? getfield(a, f).dir == getfield(b, f).dir :
                              f === :store ? sprint(show, getfield(a, f)) == sprint(show, getfield(b, f)) :
                              getfield(a, f) == getfield(b, f), fieldnames(Chain))
        gated = Bucket("bkt"; region = "eu-north-1", gateway = url)
        short = Chain(gated, "p"; credentials = creds, cache_dir = "/c", read_ahead = 3, record_host = false)
        long = Chain("bkt", "p"; gateway = url, region = "eu-north-1", credentials = creds, cache_dir = "/c", read_ahead = 3, record_host = false)
        @test short isa Chain{GatewayObjectStore} && same(short, long)
        @test short.store.s3.credentials === creds && short.read_ahead == 3 && !short.record_host
        plain = Chain(Bucket("bkt"; region = "eu-north-1"), "p"; credentials = creds, cache_dir = "/c")
        @test plain isa Chain{S3ObjectStore} && same(plain, Chain("bkt", "p"; region = "eu-north-1", credentials = creds, cache_dir = "/c"))
        # no region in the bucket: Chain's rule — the environment, never guessed
        withenv("AWS_REGION" => "eu-north-1", "AWS_DEFAULT_REGION" => nothing) do
            @test Chain(Bucket("bkt"; gateway = url), "p"; credentials = creds, cache_dir = "/c").region == "eu-north-1"
        end
        withenv("AWS_REGION" => "us-east-1", "AWS_DEFAULT_REGION" => nothing) do
            @test_throws "region \"us-east-1\" disagrees with the region in the function URL" Chain(Bucket("bkt"; gateway = url), "p"; credentials = creds)
        end
        # no profile and no credentials: the environment, as for the long form
        withenv("AWS_ACCESS_KEY_ID" => "AKIAX", "AWS_SECRET_ACCESS_KEY" => "s3cret", "AWS_SESSION_TOKEN" => nothing) do
            @test Chain(gated, "p"; cache_dir = "/c").store.s3.credentials == Credentials("AKIAX", "s3cret")
        end
        # region and gateway are the bucket's to say
        @test_throws "region was given together with a Bucket, which already says it (\"eu-north-1\")" Chain(gated, "p"; region = "us-east-1", credentials = creds)
        @test_throws "gateway was given together with a Bucket" Chain(gated, "p"; gateway = url, credentials = creds)
        # Chain's own refusals pass through
        @test_throws "prefix \"p/\" begins or ends with '/'" Chain(gated, "p/"; credentials = creds)
    end

    @testset "a supplied store: the bucket's gateway is not forwarded" begin
        b = Bucket("bkt"; region = "eu-north-1", gateway = url, profile = "team")
        mktempdir() do dir
            store = InMemoryObjectStore()
            chain = Chain(b, "exp/run-1"; store, cache_dir = joinpath(dir, "cache"))
            @test chain isa Chain{InMemoryObjectStore} && chain.store === store && isempty(store.calls)
            @test CT.create_chain(chain).slot == 0 && haskey(store.objects, "exp/run-1/000000000000")
        end
    end

    @testset "the profile: sso_credentials by default, overridden by profile or credentials" begin
        b = Bucket("bkt"; region = "eu-north-1", gateway = url, profile = "chaintables-test-no-such-profile")
        store = InMemoryObjectStore()
        # with a store nothing resolves, so the callable is there to look at; calling it names its profile
        chain = Chain(b, "p"; store, cache_dir = "/c")
        @test chain.credentials isa Function
        @test_throws "aws sso login --profile chaintables-test-no-such-profile" chain.credentials()
        @test_throws "aws sso login --profile chaintables-test-mine" Chain(b, "p"; store, cache_dir = "/c",
            profile = "chaintables-test-mine").credentials()
        @test Chain(b, "p"; store, cache_dir = "/c", profile = nothing).credentials === nothing
        @test Chain(b, "p"; store, cache_dir = "/c", credentials = creds).credentials === creds
        # without a store the credentials resolve at construction (ADR-0019), so a dead profile fails there
        @test_throws "aws sso login --profile chaintables-test-no-such-profile" Chain(b, "p"; cache_dir = "/c")
        @test Chain(b, "p"; credentials = creds, cache_dir = "/c").store.s3.credentials === creds
    end

    @testset "sso_login(bucket) is sso_login(bucket.profile)" begin
        ran = Cmd[]
        b = Bucket("bkt"; profile = "team")
        @test CT.sso_login(b; device_code = true, runner = cmd -> push!(ran, cmd)) === nothing
        @test ran[1].exec == ["aws", "sso", "login", "--profile", "team", "--use-device-code"]
        @test_throws "has no profile to log in with" CT.sso_login(Bucket("bkt"))
    end
end
