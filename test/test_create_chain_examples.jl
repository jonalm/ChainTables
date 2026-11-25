using Test
using ChainTables: ChainTables, Chain, create_chain, head, sync!, try_create_chain
using ChainTables.Testing: InMemoryObjectStore

@testset "create_chain example" begin
    mktempdir() do dir
        store = InMemoryObjectStore()
        chain = Chain("lab-bucket", "run-7"; store, cache_dir = joinpath(dir, "records"))

        # It writes slot 0 and returns the id of the new chain. It makes no local copy.
        created = create_chain(chain)
        @test created.slot == 0
        @test length(created.chain_id) == 26

        # A local copy is opened and synced from the chain.
        local_copy = ChainTables.open(chain, joinpath(dir, "copy"))
        sync!(local_copy)
        @test head(local_copy).transaction_hash == created.transaction_hash
        close(local_copy)
    end
end

@testset "try_create_chain example" begin
    mktempdir() do dir
        store = InMemoryObjectStore()
        chain = Chain("lab-bucket", "run-7"; store, cache_dir = joinpath(dir, "records"))

        # For setup that runs more than once: the first call creates the chain, and a
        # later one returns `nothing`.
        @test try_create_chain(chain).slot == 0
        @test try_create_chain(chain) === nothing
    end
end
