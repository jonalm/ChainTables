using Test
using ChainTables: ChainTables, Bucket, Chain, Credentials, sso_login

@testset "Bucket example" begin
    # The facts of one deployment, held as one value; constructing it does no I/O.
    url = "https://abc123.lambda-url.eu-north-1.on.aws"
    bucket = Bucket("bkt"; region = "eu-north-1", gateway = url, profile = "team")
    # Log in with the bucket's profile; `runner` stands in for the AWS CLI here.
    sso_login(bucket; runner = cmd -> nothing)
    # The chain under a prefix; explicit credentials win over the profile.
    credentials = Credentials("AKIAEXAMPLE", "secret")
    chain = Chain(bucket, "exp/run-1"; credentials, cache_dir = "/c")
    @test chain.bucket == "bkt" && chain.region == "eu-north-1"
end
