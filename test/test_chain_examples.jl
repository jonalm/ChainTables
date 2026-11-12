using Test
using ExplicitImports: check_all_explicit_imports_are_public,
    check_all_qualified_accesses_are_public
using ChainTables: ChainTables, Chain
using ChainTables.Testing: InMemoryObjectStore

@testset "Chain example" begin
    mktempdir() do dir
        # A chain is where the records live: a bucket and a prefix, reached through a store.
        # Against AWS the store is built from the region and the credentials; a test
        # passes the in-memory store instead.
        store = InMemoryObjectStore()
        chain = Chain("my-bucket", "experiments/run-7"; store, cache_dir = dir)
        @test chain.prefix == "experiments/run-7"
        # Constructing a chain performs no I/O.
        @test isempty(store.calls)
    end
end

@testset "the examples use only public names" begin
    @test check_all_explicit_imports_are_public(@__MODULE__, @__FILE__) === nothing
    @test check_all_qualified_accesses_are_public(@__MODULE__, @__FILE__) === nothing
end
