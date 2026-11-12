using Test
using ChainTables: ChainTables, ChainTablesError, DivergenceError, FingerprintMismatchError,
    LayoutVersionError, LocalCopyInconsistentError, NotALocalCopyError, PinnedCopyError,
    RecordCacheError, StateFingerprint, TransactionHash, WrongChainError

const ZEROS = zeros(UInt8, 32)
const ONES = ones(UInt8, 32)
const CHAIN = "A"^26
const VERSIONS = (lib = "ChainTables 0.3.3", julia = "1.13.2")

# Each error built with Evidence and a detail, and the four parts its showerror writes.
const ERRORS = [
    (
        name = "PinnedCopyError",
        error = PinnedCopyError(;
            path = "/c", slot = 3, call = "sync!", detail = "the copy is held at slot 3",
        ),
        summary = "the local copy is pinned, so it cannot move",
        evidence = "call = sync!",
        next_move = "Run `unpin!(copy)`",
    ),
    (
        name = "FingerprintMismatchError",
        error = FingerprintMismatchError(;
            chain_id = CHAIN, slot = 3, expected = ZEROS, computed = ONES,
            record_client = VERSIONS, this_client = VERSIONS,
            detail = "after applying slot 3",
        ),
        summary = "the state fingerprint differs from the record's",
        evidence = "computed = $(bytes2hex(ONES))",
        next_move = "Run `repair!(copy)`",
    ),
    (
        name = "DivergenceError",
        error = DivergenceError(;
            path = "/c", chain_id = CHAIN, slot = 3, expected = ZEROS, computed = ONES,
            tables = ["t"], detail = "a fresh replay differs",
        ),
        summary = "a fresh replay does not reproduce the head's state",
        evidence = "tables = [\"t\"]",
        next_move = "Report it with the Julia and ChainTables versions.",
    ),
    (
        name = "NotALocalCopyError",
        error = NotALocalCopyError(; path = "/c", detail = "a file, not a directory"),
        summary = "the path is not a local copy",
        evidence = "path = /c",
        next_move = "Open another path",
    ),
    (
        name = "LayoutVersionError",
        error = LayoutVersionError(;
            path = "/c", file = "heads/000000000003", detail = "layout 2",
        ),
        summary = "the local copy has a newer layout than this client reads",
        evidence = "file = heads/000000000003",
        next_move = "Upgrade ChainTables",
    ),
    (
        name = "WrongChainError",
        error = WrongChainError(;
            path = "/c", bound = CHAIN, opened = "B"^26, detail = "another chain id",
        ),
        summary = "the local copy is bound to another chain",
        evidence = "opened = $("B"^26)",
        next_move = "Open another path for this chain.",
    ),
    (
        name = "LocalCopyInconsistentError",
        error = LocalCopyInconsistentError(;
            path = "/c", slot = 3, file = "tables/ab", detail = "the bytes hash elsewhere",
        ),
        summary = "the local copy is damaged",
        evidence = "file = tables/ab",
        next_move = "Run `repair!(copy)`",
    ),
    (
        name = "RecordCacheError",
        error = RecordCacheError(;
            chain_id = CHAIN, slot = 2, path = "/cache/p/2", expected = ZEROS, found = ONES,
            detail = "the file hashes elsewhere",
        ),
        summary = "the record cache does not hold the chain's record",
        evidence = "expected = $(bytes2hex(ZEROS))",
        next_move = "Run `repair!(copy)`, which fetches the record again",
    ),
]

@testset "$(case.name) is a ChainTablesError" for case in ERRORS
    @test case.error isa ChainTablesError
end

@testset "$(case.name) shows its summary and detail first" for case in ERRORS
    text = sprint(showerror, case.error)
    @test startswith(text, "$(case.name): $(case.summary): $(case.error.detail).")
end

@testset "$(case.name) shows its Evidence" for case in ERRORS
    @test occursin("\n  $(case.evidence)", sprint(showerror, case.error))
end

@testset "$(case.name) shows its next move" for case in ERRORS
    @test occursin(case.next_move, sprint(showerror, case.error))
end

@testset "$(case.name) leaves out unknown Evidence" for case in ERRORS
    bare = typeof(case.error)(; detail = "x")
    @test !occursin(" = nothing", sprint(showerror, bare))
end

@testset "fingerprints given as bytes are carried as StateFingerprint" begin
    e = DivergenceError(; expected = ZEROS, computed = ONES)
    @test e.expected isa StateFingerprint
    @test e.computed isa StateFingerprint
    e = FingerprintMismatchError(; expected = ZEROS, computed = ONES)
    @test e.expected isa StateFingerprint
    @test e.computed isa StateFingerprint
end

@testset "a fingerprint Evidence refuses what is not 32 bytes" begin
    @test_throws(
        ArgumentError, "a StateFingerprint is 32 bytes, got 3",
        FingerprintMismatchError(; expected = UInt8[1, 2, 3]),
    )
end

@testset "RecordCacheError carries transaction hashes" begin
    e = RecordCacheError(;
        slot = 2, path = "/c/bkt/p/000000000002", expected = ZEROS, found = ONES,
    )
    @test (e.slot, e.path) == (2, "/c/bkt/p/000000000002")
    @test e.expected isa TransactionHash
    @test e.found isa TransactionHash
end

@testset "DivergenceError names no table by default" begin
    @test DivergenceError().tables == String[]
end

@testset "error constructors infer" begin
    @test @inferred(PinnedCopyError(; slot = 1)).slot == 1
    mismatch = @inferred FingerprintMismatchError(; expected = ZEROS, slot = 1)
    @test mismatch.expected == ZEROS
    @test @inferred(DivergenceError(; computed = ONES, tables = ["t"])).tables == ["t"]
    @test @inferred(NotALocalCopyError(; path = "/c")).path == "/c"
    @test @inferred(LayoutVersionError(; file = "f")).file == "f"
    @test @inferred(WrongChainError(; bound = "b")).bound == "b"
    @test @inferred(LocalCopyInconsistentError(; slot = 1)).slot == 1
    @test @inferred(RecordCacheError(; expected = ZEROS)).expected == ZEROS
end
