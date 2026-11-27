using Test
using ChainTables: Bucket, Chain, create_chain, sso_login
using ChainTables.Testing: InMemoryObjectStore

@testset "Bucket example" begin
    # One value says where the chains live and how this client reaches them. It holds
    # names only, never credentials, so it can be printed and kept in a config file.
    bucket = Bucket(
        "lab-chains"; region = "eu-north-1",
        gateway = "https://abc123.lambda-url.eu-north-1.on.aws", profile = "lab-writer"
    )

    # Log in to the profile once; a Fake runner stands in for the AWS CLI here.
    sso_login(bucket; runner = command -> nothing)

    # A chain under a prefix of the bucket. Without `store`, the credentials come from
    # the profile; here an in-memory store stands in for S3.
    mktempdir() do dir
        chain = Chain(bucket, "exp/run-1"; store = InMemoryObjectStore(), cache_dir = dir)
        @test create_chain(chain).slot == 0
    end
end
