using Test
using ChainTables: ChainTables, Chain, column!, commit!, create_chain, create_table!,
    head, insert_rows!, primary_key!, sync!, table, write_builder
using ChainTables.Testing: InMemoryObjectStore

@testset "sync! example" begin
    mktempdir() do dir
        store = InMemoryObjectStore()
        chain = Chain("lab-bucket", "run-7"; store, cache_dir = joinpath(dir, "records"))
        create_chain(chain)

        # A fresh local copy has no head. The first `sync!` binds it to the chain.
        ours = ChainTables.open(chain, joinpath(dir, "ours"))
        @test sync!(ours) == (; applied = 1, slot = 0, head(ours).transaction_hash)

        # Another client commits a table.
        theirs = ChainTables.open(chain, joinpath(dir, "theirs"))
        sync!(theirs)
        w = write_builder(theirs)
        create_table!(w, :samples) do t
            column!(t, :id, Int64)
            primary_key!(t, :id)
        end
        insert_rows!(w, :samples, [(id = 1,), (id = 2,)])
        commit!(w)

        # `sync!` applies the records that the chain has above the head of the copy.
        @test sync!(ours).applied == 1
        @test table(ours, :samples).columns.id == [1, 2]

        # With nothing new it applies nothing.
        @test sync!(ours).applied == 0
        close(ours)
        close(theirs)
    end
end
