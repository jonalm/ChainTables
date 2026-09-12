# ADR-0020 — the taxonomy; #34 step 7 adds the @test_throws "<message>" provocation of every type.
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
    end
    @test isabstracttype(ChainTables.AbstractObjectStore)
end
