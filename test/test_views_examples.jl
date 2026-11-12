using Test
using ChainTables: ChainTables, Chain, column!, commit!, create_chain, create_table!,
    insert_rows!, primary_key!, shape, sync!, table, write_builder
using ChainTables.Testing: InMemoryObjectStore

# A synced copy holding `samples` with one row at slot 1.
function with_samples(f)
    return mktempdir() do dir
        store = InMemoryObjectStore()
        chain = Chain("bkt", "p"; store, cache_dir = joinpath(dir, "cache"))
        create_chain(chain)
        copy = ChainTables.open(chain, joinpath(dir, "copy"))
        sync!(copy)
        w = write_builder(copy)
        create_table!(w, :samples) do t
            column!(t, :id, Int64)
            column!(t, :mass, Float64; nullable = true)
            primary_key!(t, :id)
        end
        insert_rows!(w, :samples, [(id = 1, mass = missing)])
        commit!(w)
        try
            f(copy)
        finally
            close(copy)
        end
    end
end

@testset "table example" begin
    with_samples() do copy
        # A view of the table as of the copy's head; null reads as `missing`.
        v = table(copy, :samples)
        @test v[1].mass === missing
        # Until the head moves, every call returns the same view.
        @test table(copy, :samples) === v
    end
end

@testset "shape example" begin
    with_samples() do copy
        s = shape(copy, :samples)
        @test s.key == [:id]
        @test s.columns[2] == (name = :mass, type = Float64, nullable = true)
        # A view has the shape of its table.
        @test shape(table(copy, :samples)) == s
    end
end
