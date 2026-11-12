using Test
using ExplicitImports: check_all_explicit_imports_are_public,
    check_all_qualified_accesses_are_public
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

@testset "the examples use only public names" begin
    @test check_all_explicit_imports_are_public(@__MODULE__, @__FILE__) === nothing
    @test check_all_qualified_accesses_are_public(@__MODULE__, @__FILE__) === nothing
end
