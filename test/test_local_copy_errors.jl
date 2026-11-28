using Test
using ChainTables: LayoutVersionError, LocalCopyInconsistentError, NotALocalCopyError,
    WrongChainError

include("fixtures/evidence.jl")

const REPAIR = "Run `repair!(copy)`, which rewrites the table file from the record cache."
const NOT_A_LOCAL_COPY_NEXT_MOVES = [
    (reason = :not_a_directory, next_move = "The path is a file. Open a directory path."),
    (
        reason = :no_layout,
        next_move = "The directory is not empty and has no `heads/` and `tables/`. Open " *
            "a different path, or empty this directory if it is disposable.",
    ),
    (
        reason = :foreign_head,
        next_move = "ChainTables did not write the head file. Open a different path.",
    ),
    (reason = :unknown_to_this_client, next_move = "Open a different path."),
    (reason = nothing, next_move = "Open a different path."),
]
const DAMAGED_COPY_NEXT_MOVES = [
    (
        reason = :no_usable_head,
        next_move = "`repair!` needs a head file that can be opened. Delete the " *
            "directory and sync a fresh local copy.",
    ),
    (reason = :table_file_missing, next_move = REPAIR),
    (reason = :table_file_hash, next_move = REPAIR),
    (reason = :table_file_not_canonical, next_move = REPAIR),
    (reason = :row_slot_above_head, next_move = REPAIR),
    (
        reason = nothing,
        next_move = "Run `repair!(copy)`, which rewrites a table file from the record " *
            "cache. If no head file can be opened, delete the directory and sync a fresh " *
            "local copy.",
    ),
]

@testset "NotALocalCopyError shows what happened, the evidence and the next move" begin
    e = NotALocalCopyError(;
        path = COPY_PATH, file = "heads/000000000003", reason = :foreign_head
    )
    @test sprint(showerror, e) ==
        "NotALocalCopyError: the path is not a local copy.\n" *
        "  path = /lab/copy\n" *
        "  file = heads/000000000003\n" *
        "  reason = foreign_head\n" *
        "ChainTables did not write the head file. Open a different path."
end

@testset "NotALocalCopyError takes its next move from the reason" begin
    @testset "$(repr(case.reason))" for case in NOT_A_LOCAL_COPY_NEXT_MOVES
        text = sprint(showerror, NotALocalCopyError(; case.reason))
        @test last(split(text, "\n")) == case.next_move
    end
end

@testset "LayoutVersionError shows what happened, the evidence and the next move" begin
    e = LayoutVersionError(;
        path = COPY_PATH, file = "heads/000000000003",
        detail = "the head file has layout version 2; this client's is 1"
    )
    @test sprint(showerror, e) ==
        "LayoutVersionError: another version of ChainTables wrote this local copy.\n" *
        "the head file has layout version 2; this client's is 1\n" *
        "  path = /lab/copy\n" *
        "  file = heads/000000000003\n" *
        "Delete the directory and sync a fresh local copy, or upgrade ChainTables."
end

@testset "WrongChainError shows what happened, the evidence and the next move" begin
    e = WrongChainError(;
        path = COPY_PATH, bucket = "bkt", prefix = "p", bound = CHAIN_ID, opened = "B"^26,
    )
    @test sprint(showerror, e) ==
        "WrongChainError: the local copy is bound to another chain.\n" *
        "  path = /lab/copy\n" *
        "  bucket = bkt\n" *
        "  prefix = p\n" *
        "  bound = AAAAAAAAAAAAAAAAAAAAAAAAAA\n" *
        "  opened = BBBBBBBBBBBBBBBBBBBBBBBBBB\n" *
        "Open a different path for this chain."
end

@testset "LocalCopyInconsistentError shows what happened, the evidence, the next move" begin
    e = LocalCopyInconsistentError(;
        path = COPY_PATH, chain_id = CHAIN_ID, slot = 3, file = "tables/ab",
        reason = :table_file_hash, detail = "table \"t\": the file hashes to cd"
    )
    @test sprint(showerror, e) ==
        "LocalCopyInconsistentError: the local copy is damaged.\n" *
        "table \"t\": the file hashes to cd\n" *
        "  path = /lab/copy\n" *
        "  chain_id = AAAAAAAAAAAAAAAAAAAAAAAAAA\n" *
        "  slot = 3\n" *
        "  file = tables/ab\n" *
        "  reason = table_file_hash\n" *
        "Run `repair!(copy)`, which rewrites the table file from the record cache."
end

@testset "LocalCopyInconsistentError takes its next move from the reason" begin
    @testset "$(repr(case.reason))" for case in DAMAGED_COPY_NEXT_MOVES
        text = sprint(showerror, LocalCopyInconsistentError(; case.reason))
        @test last(split(text, "\n")) == case.next_move
    end
end
