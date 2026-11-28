using Test
using ChainTables: ChainTables, as_of, head, is_pinned, table, unpin!

include("fixtures/chain_copies.jl")

@testset "as_of example" begin
    with_samples_copy() do local_copy
        first_row = commit_sample!(local_copy, 3)
        commit_sample!(local_copy, 4)

        # A pinned copy of the chain as it stood at slot 2. Without `path` it is
        # temporary, and `close` deletes it.
        pinned = as_of(local_copy.chain, 2)
        @test head(pinned).slot == 2
        @test is_pinned(pinned)
        @test length(table(pinned, :samples)) == 3
        close(pinned)

        # A record is also found by its transaction hash.
        pinned = as_of(local_copy.chain, first_row.transaction_hash)
        @test head(pinned).slot == 2
        close(pinned)

        # A pinned copy at a path of your own is kept, and `unpin!` makes it live.
        path = joinpath(dirname(local_copy.path), "at_slot_1")
        pinned = as_of(local_copy.chain, 1; path)
        unpin!(pinned)
        @test !is_pinned(pinned)
        close(pinned)
    end
end
