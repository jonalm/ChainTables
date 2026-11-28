using Test
using Aqua: Aqua
using ChainTables: ChainTables, CBOR, Model, Ops, SigV4, Testing
using ExplicitImports: check_all_explicit_imports_are_public,
    check_all_explicit_imports_via_owners, check_all_qualified_accesses_are_public,
    check_no_implicit_imports, check_no_stale_explicit_imports

# The Tables.jl interface: documented, not marked public (ADR-0024).
const TABLES_NON_PUBLIC = (
    :Schema, :columnaccess, :columns, :istable, :rowaccess, :rows, :schema,
)

# No public option refuses a redirect or ends a stall (`set_stream_options`).
const DOWNLOADS_NON_PUBLIC = (
    :Curl, :setopt, :CURLOPT_FOLLOWLOCATION, :CURLOPT_LOW_SPEED_LIMIT,
    :CURLOPT_LOW_SPEED_TIME, :CURLOPT_TIMEOUT_MS,
)

# No public errno constant: a cached file gone mid-open is ENOENT (`hash_entry`).
const BASE_NON_PUBLIC = (:ENOENT,)

const NON_PUBLIC = (TABLES_NON_PUBLIC..., DOWNLOADS_NON_PUBLIC..., BASE_NON_PUBLIC...)

const MODULES = [ChainTables, CBOR, Model, Ops, SigV4, Testing]

@testset "Aqua passes every check" begin
    Aqua.test_all(ChainTables)
end

@testset "ExplicitImports finds no implicit import" begin
    @test check_no_implicit_imports(ChainTables) === nothing
end

@testset "ExplicitImports finds no stale explicit import" begin
    @test check_no_stale_explicit_imports(ChainTables) === nothing
end

@testset "ExplicitImports finds every explicit import via its owner" begin
    @test check_all_explicit_imports_via_owners(ChainTables) === nothing
end

@testset "ExplicitImports finds every qualified access public" begin
    @test check_all_qualified_accesses_are_public(ChainTables; ignore = NON_PUBLIC) ===
        nothing
end

@testset "ExplicitImports finds every explicit import public" begin
    @test check_all_explicit_imports_are_public(ChainTables; ignore = NON_PUBLIC) ===
        nothing
end

@testset "Docs.undocumented_names is empty: $(nameof(M))" for M in MODULES
    @test isempty(Docs.undocumented_names(M))
end
