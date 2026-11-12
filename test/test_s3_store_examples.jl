using Test
using ChainTables: ChainTables, Chain, Credentials, S3ObjectStore

@testset "S3ObjectStore example" begin
    # The S3 client of a plain bucket; Chain builds it when no store is given.
    credentials = Credentials("AKIAEXAMPLE", "secret")
    store = S3ObjectStore("bkt"; region = "eu-north-1", credentials)
    @test sprint(show, store) == "S3ObjectStore(\"bkt\"; region = \"eu-north-1\")"
    chain = Chain("bkt", "exp/run-1"; region = "eu-north-1", credentials, cache_dir = "/c")
    @test chain.store isa S3ObjectStore
end
