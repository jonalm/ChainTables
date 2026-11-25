using Test
using ChainTables: CommitOutcomeUnknownError, LostRaceError, PinnedCopyError,
    StaleHeadError, TransactionHash, UnsupportedStoreError, WriteBuilderError

include("fixtures/evidence.jl")

@testset "StaleHeadError shows what happened, the evidence and the next move" begin
    e = StaleHeadError(; chain_id = CHAIN_ID, slot = 1, chain_slot = 2)
    @test sprint(showerror, e) ==
        "StaleHeadError: the write builder's head is behind the chain.\n" *
        "  chain_id = AAAAAAAAAAAAAAAAAAAAAAAAAA\n" *
        "  slot = 1\n" *
        "  chain_slot = 2\n" *
        "Run `sync!(copy)`, recompute the row set and build again with " *
        "`write_builder(copy)`. This builder is spent."
end

@testset "LostRaceError shows what happened, the evidence and the next move" begin
    e = LostRaceError(;
        chain_id = CHAIN_ID, slot = 4, transaction_hash = TransactionHash(ONES)
    )
    @test sprint(showerror, e) ==
        "LostRaceError: another client's record is in this slot.\n" *
        "  chain_id = AAAAAAAAAAAAAAAAAAAAAAAAAA\n" *
        "  slot = 4\n" *
        "  transaction_hash = $ONES_HEX\n" *
        "The write is never retried. Run `sync!(copy)` to read the chain as it is " *
        "now; after a commit, recompute the row set and build again."
end

@testset "CommitOutcomeUnknownError shows what happened, the evidence, the next move" begin
    e = CommitOutcomeUnknownError(;
        chain_id = CHAIN_ID, slot = 4, transaction_hash = TransactionHash(ZEROS),
        landed = true, cause = ErrorException("the head was not written")
    )
    @test sprint(showerror, e) ==
        "CommitOutcomeUnknownError: the commit stopped after the put of its record " *
        "began.\n" *
        "  chain_id = AAAAAAAAAAAAAAAAAAAAAAAAAA\n" *
        "  slot = 4\n" *
        "  transaction_hash = $ZEROS_HEX\n" *
        "  landed = true\n" *
        "  cause = the head was not written\n" *
        "Run `sync!(copy)`: the commit happened exactly when `commit_log(copy)` " *
        "shows `transaction_hash` at `slot`. This builder is spent."
end

@testset "CommitOutcomeUnknownError needs its cause" begin
    @test_throws UndefKeywordError "cause" CommitOutcomeUnknownError(; slot = 4)
end

@testset "UnsupportedStoreError shows what happened, the evidence and the next move" begin
    e = UnsupportedStoreError(; endpoint = "https://minio.local")
    @test sprint(showerror, e) ==
        "UnsupportedStoreError: the object store is not AWS S3, so nothing promises " *
        "that a put never replaces an existing key.\n" *
        "  endpoint = https://minio.local\n" *
        "Use AWS S3, or construct the `Chain` with `assume_first_writer_wins = true` " *
        "to make that promise for the store."
end

@testset "WriteBuilderError shows what happened, its detail and the next move" begin
    e = WriteBuilderError(; detail = "commit!(w): this builder is spent")
    @test fieldnames(WriteBuilderError) == (:detail,)
    @test sprint(showerror, e) ==
        "WriteBuilderError: the write was refused before anything was written.\n" *
        "commit!(w): this builder is spent\n" *
        "Correct the call that the message names."
end

@testset "PinnedCopyError shows what happened, the evidence and the next move" begin
    e = PinnedCopyError(; path = COPY_PATH, slot = 3)
    @test sprint(showerror, e) ==
        "PinnedCopyError: the local copy is pinned, so the call does not move it.\n" *
        "  path = /lab/copy\n" *
        "  slot = 3\n" *
        "Run `unpin!(copy)` to make it live, or use a live copy."
end
