using Test
using ChainTables: ChainTables, Chain, as_of, column!, commit!, create_chain,
    create_table!, head, insert_rows!, is_pinned, primary_key!, slot_at, sync!, table,
    write_builder
using ChainTables.Testing: InMemoryObjectStore

function example_chain(dir)
    chain = Chain("my-bucket", "run-7"; store = InMemoryObjectStore(), cache_dir = dir)
    create_chain(chain)
    copy = ChainTables.open(chain, joinpath(dir, "copy"))
    sync!(copy)
    w = write_builder(copy)
    create_table!(w, :samples) do t
        column!(t, :id, Int64)
        primary_key!(t, :id)
    end
    commit!(w)
    w = write_builder(copy)
    insert_rows!(w, :samples, [(id = 1,)])
    commit!(w)
    close(copy)
    return chain
end

@testset "as_of example" begin
    mktempdir() do dir
        chain = example_chain(dir)
        # A pinned temporary copy of the chain as it stood at slot 1, before the insert.
        old = as_of(chain, 1)
        @test head(old).slot == 1 && is_pinned(old)
        @test isempty(table(old, :samples))
        close(old)                                     # deletes the temporary copy
    end
end

@testset "slot_at example" begin
    mktempdir() do dir
        chain = example_chain(dir)
        # The newest slot committed at or before a time; here, any time from now on.
        now_ms = round(Int64, time() * 1000)
        @test slot_at(chain, now_ms) == 2
    end
end
