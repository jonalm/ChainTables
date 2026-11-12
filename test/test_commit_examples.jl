using Test
using ChainTables: ChainTables, Chain, column!, commit!, create_chain, create_table!, head,
    insert_rows!, primary_key!, sync!, write_builder
using ChainTables.Testing: InMemoryObjectStore

# A new chain and a local copy bound to it at slot 0.
function example_copy(dir)
    chain = Chain("my-bucket", "run-7"; store = InMemoryObjectStore(), cache_dir = dir)
    create_chain(chain)
    copy = ChainTables.open(chain, joinpath(dir, "copy"))
    sync!(copy)
    return copy
end

@testset "write_builder example" begin
    mktempdir() do dir
        copy = example_copy(dir)
        # A write builder is a value used once; it collects the ops of one record.
        w = write_builder(copy)
        create_table!(w, :samples) do t
            column!(t, :id, Int64)
            primary_key!(t, :id)
        end
        insert_rows!(w, :samples, [(id = 1,), (id = 2,)])
        @test commit!(w).slot == 1
        close(copy)
    end
end

@testset "commit! example" begin
    mktempdir() do dir
        copy = example_copy(dir)
        w = write_builder(copy)
        create_table!(w, :samples) do t
            column!(t, :id, Int64)
            primary_key!(t, :id)
        end
        result = commit!(w; comment = "make samples")
        # The record is at the slot above the head, and the copy's head moved to it.
        @test result.slot == 1
        @test head(copy).transaction_hash == result.transaction_hash
        close(copy)
    end
end
