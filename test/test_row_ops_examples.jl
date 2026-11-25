using Test
using ChainTables: commit!, delete_rows!, insert_rows!, table, update_rows!, write_builder

include("fixtures/chain_copies.jl")

@testset "insert_rows! example" begin
    with_samples_copy() do local_copy
        # A row names every column of the table. Null is `missing`.
        w = write_builder(local_copy)
        insert_rows!(w, :samples, [(id = 3, label = "c", mass = missing)])
        commit!(w)
        @test table(local_copy, :samples)[3].label == "c"
    end
end

@testset "update_rows! example" begin
    with_samples_copy() do local_copy
        # A row names the primary key and the columns that change.
        w = write_builder(local_copy)
        update_rows!(w, :samples, [(id = 2, mass = 2.5)])
        commit!(w)
        @test table(local_copy, :samples)[2].mass == 2.5
    end
end

@testset "delete_rows! example" begin
    with_samples_copy() do local_copy
        # A row names the primary key and nothing else.
        w = write_builder(local_copy)
        delete_rows!(w, :samples, [(id = 1,)])
        commit!(w)
        @test !haskey(table(local_copy, :samples), 1)
    end
end
