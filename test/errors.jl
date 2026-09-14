# ADR-0020 — the taxonomy: fifteen types under one supertype, each with `msg` and its evidence as
# keyword fields defaulting to nothing. Every type is provoked, with @test_throws "<message>", in
# the test file of the lane that raises it (localcopy.jl, ops.jl, builder.jl, chain.jl, recovery.jl,
# gateway.jl); the one step 9 raises — UnsupportedStoreError — is checked by construction here.
@testset "errors" begin
    for T in (
        ChainTables.StaleHeadError, ChainTables.LostRaceError, ChainTables.WriteBuilderError,
        ChainTables.PinnedCopyError, ChainTables.FingerprintMismatchError, ChainTables.DivergenceError,
        ChainTables.UnsupportedStoreError, ChainTables.RewrittenChainError, ChainTables.ChainNotFoundError,
        ChainTables.NotALocalCopyError, ChainTables.LayoutVersionError, ChainTables.WrongChainError,
        ChainTables.LocalCopyInconsistentError, ChainTables.MalformedRecordError, ChainTables.WriteRefusedError,
    )
        @test T <: ChainTables.ChainTablesError
        @test ChainTables.ChainTablesError <: Exception
        @test fieldnames(T)[1] === :msg
        e = T("what happened")               # every evidence field is keyword-optional
        @test e.msg == "what happened"
        @test all(getfield(e, f) === nothing for f in fieldnames(T)[2:end])
        @test sprint(showerror, e) == "$(nameof(T)): what happened"
    end
    e = ChainTables.DivergenceError("divergence: this machine cannot reproduce the chain"; chain_id = "A"^26, slot = 3,
                                    expected = zeros(UInt8, 32), computed = ones(UInt8, 32))
    @test (e.chain_id, e.slot, e.expected, e.computed) == ("A"^26, 3, zeros(UInt8, 32), ones(UInt8, 32))
    # a hash given as raw bytes is carried as its type (ADR-0019): fingerprints and transaction hashes apart
    @test e.expected isa ChainTables.StateFingerprint && e.computed isa ChainTables.StateFingerprint
    e = ChainTables.RewrittenChainError("rewritten chain"; expected = zeros(UInt8, 32), found = ChainTables.TransactionHash(ones(UInt8, 32)))
    @test e.expected isa ChainTables.TransactionHash && e.found isa ChainTables.TransactionHash && e.found == ones(UInt8, 32)
    @test ChainTables.LostRaceError("lost race"; transaction_hash = zeros(UInt8, 32)).transaction_hash isa ChainTables.TransactionHash
    e = ChainTables.FingerprintMismatchError("mismatch"; expected = zeros(UInt8, 32), computed = ones(UInt8, 32))
    @test e.expected isa ChainTables.StateFingerprint && e.computed isa ChainTables.StateFingerprint
    @test_throws "a StateFingerprint is 32 bytes, got 3" ChainTables.FingerprintMismatchError("mismatch"; expected = UInt8[1, 2, 3])
    e = ChainTables.UnsupportedStoreError("unsupported store"; endpoint = "https://minio.local")
    @test e.endpoint == "https://minio.local"
    @test fieldnames(ChainTables.WriteBuilderError) == (:msg,)   # the call to fix is the whole evidence
    # the gateway's refusal (ADR-0028): one type, the reason a field, never retried
    e = ChainTables.WriteRefusedError("write refused"; chain_id = "A"^26, slot = 4, key = "p/000000000004",
                                      caller = "alice@example.com", reason = "not_allowed")
    @test (e.chain_id, e.slot, e.key, e.caller, e.reason) == ("A"^26, 4, "p/000000000004", "alice@example.com", "not_allowed")
    @test fieldnames(ChainTables.WriteRefusedError) == (:msg, :chain_id, :slot, :key, :caller, :reason)
    @test !ChainTables.retryable(e)
    @test isabstracttype(ChainTables.AbstractObjectStore)
end
