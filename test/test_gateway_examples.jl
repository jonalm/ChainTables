using Test
using ChainTables: ChainTables, Chain, Credentials, GatewayObjectStore

@testset "GatewayObjectStore example" begin
    # A gateway bucket: Chain builds the store from the gateway's function URL. Commits
    # go through the gateway; reads go to the bucket directly.
    url = "https://abc123.lambda-url.eu-north-1.on.aws"
    credentials = Credentials("AKIAEXAMPLE", "secret")
    region = "eu-north-1"
    chain = Chain("bkt", "exp/run-1"; gateway = url, region, credentials, cache_dir = "/c")
    @test chain.store isa GatewayObjectStore
    # It can also be built directly, for a test or a supplied store.
    store = GatewayObjectStore("bkt", url; region = "eu-north-1", credentials)
    shown = "GatewayObjectStore(\"bkt\", \"$url\"; region = \"eu-north-1\")"
    @test sprint(show, store) == shown
end
