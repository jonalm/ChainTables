using Test
using ChainTables: add_column!, column!, commit!, create_table!, drop_column!,
    drop_table!, primary_key!, shape, table, tables, write_builder

include("fixtures/chain_copies.jl")

@testset "create_table! example" begin
    with_chain_copy() do local_copy
        # A write builder collects the ops of one transaction record.
        w = write_builder(local_copy)
        create_table!(w, :samples) do t
            column!(t, :id, Int64)
            column!(t, :label, String)
            primary_key!(t, :id)
        end

        # `commit!` writes the record and moves the local copy to it.
        commit!(w)
        @test tables(local_copy) == ["samples"]
    end
end

@testset "column! example" begin
    with_chain_copy() do local_copy
        # A column takes a type tag: Int64, Float64, String or Vector{UInt8}. Only a
        # nullable column holds `missing`.
        w = write_builder(local_copy)
        create_table!(w, :samples) do t
            column!(t, :id, Int64)
            column!(t, :mass, Float64; nullable = true)
            primary_key!(t, :id)
        end
        commit!(w)
        @test shape(local_copy, :samples).columns[2] ==
            (name = :mass, type = Float64, nullable = true)
    end
end

@testset "primary_key! example" begin
    with_chain_copy() do local_copy
        # A composite key lists its columns in the order that the rows sort in.
        w = write_builder(local_copy)
        create_table!(w, :wells) do t
            column!(t, :row, String)
            column!(t, :plate, Int64)
            primary_key!(t, :plate, :row)
        end
        commit!(w)
        @test shape(local_copy, :wells).key == [:plate, :row]
    end
end

@testset "add_column! example" begin
    with_samples_copy() do local_copy
        # Every row of the table gets the fill.
        w = write_builder(local_copy)
        add_column!(w, :samples, :checked, Int64; fill = 0)
        commit!(w)
        @test table(local_copy, :samples).columns.checked == [0, 0]
    end
end

@testset "drop_column! example" begin
    with_samples_copy() do local_copy
        w = write_builder(local_copy)
        drop_column!(w, :samples, :mass)
        commit!(w)
        @test keys(table(local_copy, :samples).columns) == (:id, :label)
    end
end

@testset "drop_table! example" begin
    with_samples_copy() do local_copy
        w = write_builder(local_copy)
        drop_table!(w, :samples)
        commit!(w)
        @test tables(local_copy) == String[]
    end
end
