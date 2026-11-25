using Test
using ChainTables: Chain
using ChainTables.Testing: InMemoryObjectStore

@testset "Chain example" begin
    # A chain is a bucket and a prefix, and the object store to reach them through.
    # Without `store` it is the S3 client; a test passes the in-memory store.
    store = InMemoryObjectStore()
    chain = Chain("lab-bucket", "experiments/run-7"; store, cache_dir = "/tmp/records")

    # Constructing it performs no I/O.
    @test isempty(store.calls)
    @test chain.bucket == "lab-bucket"
    @test chain.prefix == "experiments/run-7"
    @test chain.store === store
end
