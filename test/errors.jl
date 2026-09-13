# ADR-0020 — the taxonomy: fourteen types under one supertype, each with `msg` and its evidence as
# keyword fields defaulting to nothing. Every type is provoked, with @test_throws "<message>", in
# the test file of the lane that raises it (localcopy.jl, ops.jl, builder.jl, chain.jl); the two
# steps 8 and 9 raise — DivergenceError, UnsupportedStoreError — are checked by construction here.
@testset "errors" begin
    for T in (
        ChainTables.StaleHeadError, ChainTables.LostRaceError, ChainTables.WriteBuilderError,
        ChainTables.PinnedCopyError, ChainTables.FingerprintMismatchError, ChainTables.DivergenceError,
        ChainTables.UnsupportedStoreError, ChainTables.RewrittenChainError, ChainTables.ChainNotFoundError,
        ChainTables.NotALocalCopyError, ChainTables.LayoutVersionError, ChainTables.WrongChainError,
        ChainTables.LocalCopyInconsistentError, ChainTables.MalformedRecordError,
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
    @test (e.chain_id, e.slot, e.expected[1], e.computed[1]) == ("A"^26, 3, 0x00, 0x01)
    e = ChainTables.UnsupportedStoreError("unsupported store"; endpoint = "https://minio.local")
    @test e.endpoint == "https://minio.local"
    @test fieldnames(ChainTables.WriteBuilderError) == (:msg,)   # the call to fix is the whole evidence
    @test isabstracttype(ChainTables.AbstractObjectStore)
end
