using Test
using ChainTables: ChainTables, Chain, add_column!, column!, commit!, create_chain,
    create_table!, delete_rows!, drop_column!, drop_table!, insert_rows!, primary_key!,
    shape, sync!, table, tables, update_rows!, write_builder
using ChainTables.Testing: InMemoryObjectStore

# A synced local copy of a new chain in an in-memory store.
function with_new_copy(f)
    return mktempdir() do dir
        store = InMemoryObjectStore()
        chain = Chain("bkt", "p"; store, cache_dir = joinpath(dir, "cache"))
        create_chain(chain)
        copy = ChainTables.open(chain, joinpath(dir, "copy"))
        sync!(copy)
        try
            f(copy)
        finally
            close(copy)
        end
    end
end

# The `samples` table with two rows, committed.
function with_samples(f)
    return with_new_copy() do copy
        w = write_builder(copy)
        create_table!(w, :samples) do t
            column!(t, :id, Int64)
            column!(t, :label, String)
            column!(t, :mass, Float64; nullable = true)
            primary_key!(t, :id)
        end
        rows = [(id = 1, label = "a", mass = 1.5), (id = 2, label = "b", mass = missing)]
        insert_rows!(w, :samples, rows)
        commit!(w)
        f(copy)
    end
end

@testset "create_table! example" begin
    with_new_copy() do copy
        # Every write goes through a builder taken from the copy.
        w = write_builder(copy)
        # The block declares the columns and the primary key.
        create_table!(w, :samples) do t
            column!(t, :id, Int64)
            column!(t, :label, String)
            primary_key!(t, :id)
        end
        commit!(w)
        @test tables(copy) == ["samples"]
    end
end

@testset "column! example" begin
    with_new_copy() do copy
        w = write_builder(copy)
        create_table!(w, :readings) do t
            column!(t, :id, Int64)
            # A nullable column holds `missing` where a row has no value.
            column!(t, :value, Float64; nullable = true)
            primary_key!(t, :id)
        end
        commit!(w)
        value = (name = :value, type = Float64, nullable = true)
        @test shape(copy, :readings).columns[2] == value
    end
end

@testset "primary_key! example" begin
    with_new_copy() do copy
        w = write_builder(copy)
        create_table!(w, :grid) do t
            column!(t, :row, Int64)
            column!(t, :col, Int64)
            # A composite key: rows sort by `row`, then by `col`.
            primary_key!(t, :row, :col)
        end
        commit!(w)
        @test shape(copy, :grid).key == [:row, :col]
    end
end

@testset "insert_rows! example" begin
    with_samples() do copy
        w = write_builder(copy)
        # A row set is a collection of rows; each row names every column.
        insert_rows!(w, :samples, [(id = 3, label = "c", mass = 0.5)])
        commit!(w)
        @test table(copy, :samples)[3] == (id = 3, label = "c", mass = 0.5)
    end
end

@testset "update_rows! example" begin
    with_samples() do copy
        w = write_builder(copy)
        # Name the key and the columns that change; other columns keep their value.
        update_rows!(w, :samples, [(id = 2, mass = 2.5)])
        commit!(w)
        @test table(copy, :samples)[2] == (id = 2, label = "b", mass = 2.5)
    end
end

@testset "delete_rows! example" begin
    with_samples() do copy
        w = write_builder(copy)
        # A delete names the key columns only.
        delete_rows!(w, :samples, [(id = 1,)])
        commit!(w)
        @test keys(table(copy, :samples)) == [2]
    end
end

@testset "add_column! example" begin
    with_samples() do copy
        w = write_builder(copy)
        # Every existing row receives the fill.
        add_column!(w, :samples, :batch, Int64; fill = 0)
        commit!(w)
        @test table(copy, :samples)[1].batch == 0
    end
end

@testset "drop_column! example" begin
    with_samples() do copy
        w = write_builder(copy)
        drop_column!(w, :samples, :mass)
        commit!(w)
        @test table(copy, :samples)[1] == (id = 1, label = "a")
    end
end

@testset "drop_table! example" begin
    with_samples() do copy
        w = write_builder(copy)
        drop_table!(w, :samples)
        commit!(w)
        @test isempty(tables(copy))
    end
end
