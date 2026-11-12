using Test
using Aqua: Aqua
using ChainTables: ChainTables
using ExplicitImports: check_all_explicit_imports_are_public,
    check_all_explicit_imports_via_owners, check_all_qualified_accesses_are_public,
    check_no_implicit_imports, check_no_stale_explicit_imports

@testset "Aqua finds no hygiene problem" begin
    Aqua.test_all(ChainTables)
end

const EXPLICIT_IMPORT_CHECKS = [
    (name = "no implicit imports", check = check_no_implicit_imports),
    (name = "no stale explicit imports", check = check_no_stale_explicit_imports),
    (name = "explicit imports via owners", check = check_all_explicit_imports_via_owners),
    (name = "qualified accesses are public", check = check_all_qualified_accesses_are_public),
    (name = "explicit imports are public", check = check_all_explicit_imports_are_public),
]

@testset "ExplicitImports finds $(case.name)" for case in EXPLICIT_IMPORT_CHECKS
    @test case.check(ChainTables) === nothing
end

const DOCUMENTED_MODULES = [
    (name = "ChainTables", mod = ChainTables),
    (name = "CBOR", mod = ChainTables.CBOR),
    (name = "Ops", mod = ChainTables.Ops),
    (name = "Testing", mod = ChainTables.Testing),
]

@testset "every public name of $(case.name) has a docstring" for case in DOCUMENTED_MODULES
    @test isempty(Docs.undocumented_names(case.mod))
end
