using Test
using ChainTables: shape, table

include("fixtures/chain_copies.jl")

@testset "table example" begin
    with_samples_copy() do local_copy
        # A table view is a read of one table at the head of the local copy.
        v = table(local_copy, :samples)

        # The rows come in key order, and `v[key]` is the row at a primary key.
        @test [row.label for row in v] == ["a", "b"]
        @test v[1].mass == 1.5

        # A column is a vector. Null reads as `missing`.
        @test isequal(v.columns.mass, [1.5, missing])
    end
end

@testset "shape example" begin
    with_samples_copy() do local_copy
        # The shape of a table: its columns, with the type tags that `column!` takes,
        # and its primary key.
        declared = shape(local_copy, :samples)
        @test declared.key == [:id]
        @test declared.columns[3] == (name = :mass, type = Float64, nullable = true)

        # A table view has the shape of the table at the view's head.
        @test shape(table(local_copy, :samples)) == declared
    end
end
