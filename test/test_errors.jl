using Test
using ChainTables: ChainTables, ChainTablesError, DivergenceError,
    FingerprintMismatchError, LostRaceError, RewrittenChainError, StaleHeadError,
    StateFingerprint, TransactionHash, UnsupportedStoreError

include("fixtures/evidence.jl")

const ERROR_TYPES = [
    ChainTables.AttachmentAbsentError, ChainTables.AttachmentCacheError,
    ChainTables.AttachmentChangedError, ChainTables.AttachmentDigestError,
    ChainTables.AttachmentURLExpiredError, ChainTables.ChainNotFoundError,
    ChainTables.CommitOutcomeUnknownError, ChainTables.DivergenceError,
    ChainTables.FingerprintMismatchError, ChainTables.GatewayMismatchError,
    ChainTables.GatewaySessionEndingError, ChainTables.LayoutVersionError,
    ChainTables.LocalCopyInconsistentError, ChainTables.LostRaceError,
    ChainTables.MalformedRecordError, ChainTables.NotALocalCopyError,
    ChainTables.PinnedCopyError, ChainTables.RecordCacheError,
    ChainTables.RewrittenChainError, ChainTables.StaleHeadError,
    ChainTables.UnsupportedStoreError, ChainTables.WriteBuilderError,
    ChainTables.WriteRefusedError, ChainTables.WrongChainError,
]

@testset "ChainTables makes its 24 error types and their supertype public" begin
    public_errors = filter(name -> endswith(string(name), "Error"), names(ChainTables))
    @test sort(public_errors) == sort([nameof.(ERROR_TYPES); :ChainTablesError])
end

@testset "ChainTablesError is the supertype of every public error type" begin
    @test ChainTablesError <: Exception
    @testset "$(nameof(T))" for T in ERROR_TYPES
        @test T <: ChainTablesError
        @test fieldnames(T)[end] === :detail
    end
end

@testset "showerror leaves out an evidence field that is nothing" begin
    e = StaleHeadError(; slot = 1)
    @test sprint(showerror, e) ==
        "StaleHeadError: the write builder's head is behind the chain.\n" *
        "  slot = 1\n" *
        "Run `sync!(copy)`, recompute the row set and build again with " *
        "`write_builder(copy)`. This builder is spent."
end

@testset "showerror writes detail on a line of its own, below the summary" begin
    e = UnsupportedStoreError(; endpoint = "https://minio.local", detail = "At commit!.")
    lines = split(sprint(showerror, e), "\n")
    @test lines[2] == "At commit!."
    @test lines[3] == "  endpoint = https://minio.local"
end

# The tests below are of the form that the throw sites not yet rewritten use. They go
# with it: https://github.com/jonalm/julia_codestyle/issues/130

@testset "an error built from a message holds the message as detail" begin
    e = DivergenceError("divergence at slot 3"; chain_id = CHAIN_ID, slot = 3)
    @test e.detail == "divergence at slot 3"
    @test e.chain_id == CHAIN_ID
    @test e.slot == 3
    @test e.expected === nothing
end

@testset "an error built from a message holds a hash given as bytes as its type" begin
    divergence = DivergenceError("divergence"; expected = ZEROS, computed = ONES)
    @test divergence.expected isa StateFingerprint
    @test divergence.computed == StateFingerprint(ONES)
    rewritten = RewrittenChainError(
        "rewritten chain"; expected = ZEROS, found = TransactionHash(ONES)
    )
    @test rewritten.expected isa TransactionHash
    @test rewritten.found == TransactionHash(ONES)
    @test LostRaceError("lost race"; transaction_hash = ZEROS).transaction_hash ==
        TransactionHash(ZEROS)
end

@testset "an error built from a message refuses a hash that is not 32 bytes" begin
    @test_throws ArgumentError "a StateFingerprint is 32 bytes, got 3" (
        FingerprintMismatchError("mismatch"; expected = UInt8[1, 2, 3])
    )
end
