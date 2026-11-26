using Test
using ChainTables: ChainTables, commit!, commit_log, insert_rows!, write_builder

include("fixtures/chain_copies.jl")

@testset "commit_log example" begin
    with_samples_copy() do local_copy
        w = write_builder(local_copy)
        insert_rows!(w, :samples, [(id = 3, label = "c", mass = 3.0)])
        commit!(w; comment = "sample c")

        # The commit log of the local copy, newest first, down to the genesis record.
        log = commit_log(local_copy)
        @test [entry.slot for entry in log] == [2, 1, 0]
        @test log[1].comment == "sample c"

        # `last` keeps the newest records only.
        @test commit_log(local_copy; last = 1) == log[1:1]
    end
end
