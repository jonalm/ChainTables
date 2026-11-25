using Test
using ChainTables: ChainTables, commit!, head, is_pinned, sync!, tables, unpin!,
    write_builder
using ChainTables.Testing: InMemoryObjectStore

include("fixtures/chain_copies.jl")

@testset "open example" begin
    mktempdir() do dir
        # A chain lives in a bucket. Here the bucket is an in-memory object store.
        cache_dir = joinpath(dir, "cache")
        chain = ChainTables.Chain("bkt", "lab"; store = InMemoryObjectStore(), cache_dir)
        ChainTables.create_chain(chain)

        # `open` makes the local copy in an empty or absent directory, and `sync!`
        # brings it to the chain's head.
        local_copy = ChainTables.open(chain, joinpath(dir, "copy"))
        sync!(local_copy)
        @test head(local_copy).slot == 0
        close(local_copy)
    end
end

@testset "head example" begin
    with_chain_copy() do local_copy
        # The head says which transaction record the local copy is the result of.
        at_head = head(local_copy)
        @test at_head.slot == 0

        # A commit moves the copy to the record it wrote.
        w = write_builder(local_copy)
        declare_samples!(w)
        committed = commit!(w)
        @test head(local_copy).slot == 1
        @test head(local_copy).transaction_hash == committed.transaction_hash
    end
end

@testset "tables example" begin
    with_samples_copy() do local_copy
        @test tables(local_copy) == ["samples"]
    end
end

@testset "is_pinned example" begin
    with_samples_copy() do local_copy
        # A copy from `open` is live. `as_of` gives a pinned copy, held at one slot.
        @test !is_pinned(local_copy)
        pinned = ChainTables.as_of(local_copy.chain, 0)
        @test is_pinned(pinned)
        close(pinned)
    end
end

@testset "unpin! example" begin
    with_samples_copy() do local_copy
        # A pinned copy at slot 0 goes live, and the next `sync!` moves it.
        pinned = ChainTables.as_of(local_copy.chain, 0)
        unpin!(pinned)
        sync!(pinned)
        @test head(pinned).slot == 1
        close(pinned)
    end
end
