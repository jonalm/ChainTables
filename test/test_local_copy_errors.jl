using Test
using ChainTables: LayoutVersionError, LocalCopyInconsistentError, NotALocalCopyError,
    WrongChainError

include("fixtures/evidence.jl")

@testset "NotALocalCopyError shows what happened, the evidence and the next move" begin
    e = NotALocalCopyError(; path = COPY_PATH)
    @test sprint(showerror, e) ==
        "NotALocalCopyError: the path is not a local copy.\n" *
        "  path = /lab/copy\n" *
        "Open a different path."
end

@testset "LayoutVersionError shows what happened, the evidence and the next move" begin
    e = LayoutVersionError(; path = COPY_PATH, file = "heads/000000000003")
    @test sprint(showerror, e) ==
        "LayoutVersionError: another version of ChainTables wrote this local copy.\n" *
        "  path = /lab/copy\n" *
        "  file = heads/000000000003\n" *
        "Delete the directory and sync a fresh local copy, or upgrade ChainTables."
end

@testset "WrongChainError shows what happened, the evidence and the next move" begin
    e = WrongChainError(; path = COPY_PATH, bound = CHAIN_ID, opened = "B"^26)
    @test sprint(showerror, e) ==
        "WrongChainError: the local copy is bound to another chain.\n" *
        "  path = /lab/copy\n" *
        "  bound = AAAAAAAAAAAAAAAAAAAAAAAAAA\n" *
        "  opened = BBBBBBBBBBBBBBBBBBBBBBBBBB\n" *
        "Open a different path for this chain."
end

@testset "LocalCopyInconsistentError shows what happened, the evidence, the next move" begin
    e = LocalCopyInconsistentError(; path = COPY_PATH, slot = 3, file = "tables/ab")
    @test sprint(showerror, e) ==
        "LocalCopyInconsistentError: the local copy is damaged.\n" *
        "  path = /lab/copy\n" *
        "  slot = 3\n" *
        "  file = tables/ab\n" *
        "Run `repair!(copy)`, which rewrites a table file from the record cache. " *
        "If no head can be opened, delete the directory and sync a fresh local copy."
end
