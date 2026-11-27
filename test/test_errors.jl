using Test
using ChainTables: ChainTables, ChainTablesError, StaleHeadError, UnsupportedStoreError

include("fixtures/evidence.jl")

const ERROR_TYPES = [
    ChainTables.AttachmentAbsentError, ChainTables.AttachmentCacheError,
    ChainTables.AttachmentChangedError, ChainTables.AttachmentDigestError,
    ChainTables.AttachmentURLExpiredError, ChainTables.ChainNotFoundError,
    ChainTables.CommitOutcomeUnknownError, ChainTables.CredentialsExportError,
    ChainTables.DivergenceError,
    ChainTables.FingerprintMismatchError, ChainTables.GatewayMismatchError,
    ChainTables.GatewaySessionEndingError, ChainTables.LayoutVersionError,
    ChainTables.LocalCopyInconsistentError, ChainTables.LoginError,
    ChainTables.LostRaceError,
    ChainTables.MalformedRecordError, ChainTables.NotALocalCopyError,
    ChainTables.PinnedCopyError, ChainTables.RecordCacheError,
    ChainTables.RewrittenChainError, ChainTables.StaleHeadError,
    ChainTables.TransportError, ChainTables.UnsupportedStoreError,
    ChainTables.WriteBuilderError,
    ChainTables.WriteRefusedError, ChainTables.WrongChainError,
]

@testset "ChainTables makes its 27 error types and their supertype public" begin
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
