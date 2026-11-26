using Test
using ChainTables: ChainTables, FingerprintMismatchError, verify

include("fixtures/chain_copies.jl")
include("fixtures/damaged_copies.jl")

@testset "verify example" begin
    with_samples_copy() do local_copy
        # A sound copy: every table file hashes to its name.
        @test verify(local_copy) === nothing

        # `full = true` also replays the record cache from slot 0, with no request to
        # the store.
        @test verify(local_copy; full = true) === nothing

        # A table file that no longer hashes to its name is a damaged copy.
        damage_table_file!(local_copy, "samples")
        @test_throws FingerprintMismatchError "hashes to" verify(local_copy)
    end
end
