using Test
using ChainTables: ChainTables, Chain, column!, commit!, create_chain, create_table!,
    head, insert_rows!, primary_key!, sync!, table, write_builder
using ChainTables.Testing: InMemoryObjectStore

function with_synced_copy(f)
    mktempdir() do dir
        store = InMemoryObjectStore()
        chain = Chain("lab-bucket", "run-7"; store, cache_dir = joinpath(dir, "records"))
        create_chain(chain)
        local_copy = ChainTables.open(chain, joinpath(dir, "copy"))
        try
            sync!(local_copy)
            f(local_copy)
        finally
            close(local_copy)
        end
    end
    return nothing
end

@testset "write_builder example" begin
    with_synced_copy() do local_copy
        # A write builder collects the ops of one transaction record. It is taken at
        # the head of a local copy, and it changes nothing until `commit!`.
        w = write_builder(local_copy)
        create_table!(w, :samples) do t
            column!(t, :id, Int64)
            primary_key!(t, :id)
        end
        @test head(local_copy).slot == 0
    end
end

@testset "commit! example" begin
    with_synced_copy() do local_copy
        w = write_builder(local_copy)
        create_table!(w, :samples) do t
            column!(t, :id, Int64)
            column!(t, :label, String)
            primary_key!(t, :id)
        end
        insert_rows!(w, :samples, [(id = 1, label = "a"), (id = 2, label = "b")])

        # One record, at the slot above the head. The local copy moves with it.
        committed = commit!(w; comment = "first samples")
        @test committed.slot == 1
        @test head(local_copy) == committed
        @test table(local_copy, :samples).columns.label == ["a", "b"]
    end
end
