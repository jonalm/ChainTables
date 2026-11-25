using Test
using ChainTables: table, table_with_slots, update_rows!

include("fixtures/chain_copies.jl")

@testset "table_with_slots example" begin
    with_samples_copy() do local_copy
        # Both rows were inserted by the record at slot 1.
        @test table_with_slots(table(local_copy, :samples))._slot == [1, 1]

        # The record at slot 2 updates the row with id 2.
        commit_ops!(w -> update_rows!(w, :samples, [(id = 2, mass = 2.5)]), local_copy)

        # The rows changed after slot 1 are those with `_slot > 1`.
        with_slots = table_with_slots(table(local_copy, :samples))
        @test with_slots.id[with_slots._slot .> 1] == [2]
    end
end
