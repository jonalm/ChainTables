using Test
using ChainTables: ChainTables, repair!, verify

include("fixtures/chain_copies.jl")
include("fixtures/damaged_copies.jl")

@testset "repair! example" begin
    with_samples_copy() do local_copy
        # A sound copy has nothing to repair.
        @test repair!(local_copy) ==
            (; slot = 1, files_rewritten = 0, attachments_repaired = 0)

        # A damaged table file is written again from a replay of the chain's records.
        damage_table_file!(local_copy, "samples")
        @test repair!(local_copy).files_rewritten == 1
        @test verify(local_copy) === nothing
    end
end
