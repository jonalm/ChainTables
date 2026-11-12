using Test
using ChainTables: ChainTables, Chain, CommitOutcomeUnknownError, Testing

@testset "InMemoryObjectStore example" begin
    mktempdir() do dir
        # A chain over an in-memory store: no AWS, no credentials.
        store = Testing.InMemoryObjectStore(; seed = 1, clock = () -> 1_700_000_000)
        chain = Chain("bkt", "lab"; store, cache_dir = dir)
        ChainTables.create_chain(chain)
        copy = ChainTables.open(chain, joinpath(dir, "copy"))
        ChainTables.sync!(copy)
        # Every request is logged as (verb, key).
        @test (:put_object_if_absent, "lab/000000000000") in store.calls
        # A fault simulates a lost reply: the record lands, the commit cannot know it.
        store.fault = (verb, key, phase) -> verb === :put_object_if_absent &&
            phase === :after && error("network down")
        w = ChainTables.write_builder(copy)
        ChainTables.create_table!(w, :plates) do t
            ChainTables.column!(t, :id, Int64)
            ChainTables.primary_key!(t, :id)
        end
        message = "may or may not have happened"
        @test_throws CommitOutcomeUnknownError message ChainTables.commit!(w)
    end
end
