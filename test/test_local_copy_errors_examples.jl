using Test
using ExplicitImports: check_all_explicit_imports_are_public,
    check_all_qualified_accesses_are_public
using ChainTables: DivergenceError, FingerprintMismatchError, LayoutVersionError,
    LocalCopyInconsistentError, NotALocalCopyError, PinnedCopyError, RecordCacheError,
    WrongChainError

@testset "PinnedCopyError example" begin
    e = PinnedCopyError(; path = "/data/copy", slot = 3, call = "sync!")
    @test occursin("unpin!(copy)", sprint(showerror, e))
end

@testset "FingerprintMismatchError example" begin
    # Both fingerprints are carried, with the versions of both clients.
    e = FingerprintMismatchError(;
        slot = 3, expected = zeros(UInt8, 32), computed = ones(UInt8, 32),
        record_client = (lib = "ChainTables 0.3.2", julia = "1.12.0"),
    )
    @test e.expected != e.computed
end

@testset "DivergenceError example" begin
    e = DivergenceError(; slot = 3, tables = ["samples"])
    @test e.tables == ["samples"]
end

@testset "NotALocalCopyError example" begin
    e = NotALocalCopyError(; path = "/data/report.pdf", detail = "a file, not a directory")
    @test occursin("/data/report.pdf", sprint(showerror, e))
end

@testset "LayoutVersionError example" begin
    e = LayoutVersionError(; path = "/data/copy", file = "heads/000000000003")
    @test occursin("Upgrade ChainTables", sprint(showerror, e))
end

@testset "WrongChainError example" begin
    e = WrongChainError(; path = "/data/copy", bound = "A"^26, opened = "B"^26)
    @test e.bound != e.opened
end

@testset "LocalCopyInconsistentError example" begin
    e = LocalCopyInconsistentError(; path = "/data/copy", file = "tables/ab12")
    @test occursin("repair!(copy)", sprint(showerror, e))
end

@testset "RecordCacheError example" begin
    # `found` is nothing when the cache lacks the record.
    e = RecordCacheError(; slot = 2, expected = zeros(UInt8, 32))
    @test e.found === nothing
end

@testset "the examples use only public names" begin
    @test check_all_explicit_imports_are_public(@__MODULE__, @__FILE__) === nothing
    @test check_all_qualified_accesses_are_public(@__MODULE__, @__FILE__) === nothing
end
