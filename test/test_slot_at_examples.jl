using Test
using ChainTables: ChainTables, commit_log, slot_at

include("fixtures/chain_copies.jl")

@testset "slot_at example" begin
    with_samples_copy() do local_copy
        commit_sample!(local_copy, 3)
        chain = local_copy.chain

        # Each record carries its committer's time, in milliseconds since the Unix
        # epoch. `slot_at` finds the highest slot at or below a time.
        times = [entry.time_ms for entry in commit_log(local_copy)]
        @test slot_at(chain, maximum(times)) == 2
        @test slot_at(chain, typemax(Int64)) == 2
    end
end
