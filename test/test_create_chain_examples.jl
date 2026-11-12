using Test
using ExplicitImports: check_all_explicit_imports_are_public,
    check_all_qualified_accesses_are_public
using ChainTables: ChainTables, Chain, create_chain, try_create_chain
using ChainTables.Testing: InMemoryObjectStore

@testset "create_chain example" begin
    mktempdir() do dir
        store = InMemoryObjectStore()
        chain = Chain("my-bucket", "experiments/run-7"; store, cache_dir = dir)
        # Only create_chain writes slot 0: a genesis record with no ops.
        created = create_chain(chain)
        @test created.slot == 0
        @test length(created.chain_id) == 26          # base32 text
    end
end

@testset "try_create_chain example" begin
    mktempdir() do dir
        store = InMemoryObjectStore()
        chain = Chain("my-bucket", "experiments/run-7"; store, cache_dir = dir)
        # Setup that runs more than once: the first call creates, later ones return nothing.
        @test try_create_chain(chain).slot == 0
        @test try_create_chain(chain) === nothing
    end
end

@testset "the examples use only public names" begin
    @test check_all_explicit_imports_are_public(@__MODULE__, @__FILE__) === nothing
    @test check_all_qualified_accesses_are_public(@__MODULE__, @__FILE__) === nothing
end
