using Test
using ExplicitImports: check_all_explicit_imports_are_public,
    check_all_qualified_accesses_are_public
using ChainTables: ChainTables, Chain, create_chain, head, sync!
using ChainTables.Testing: InMemoryObjectStore

@testset "sync! example" begin
    mktempdir() do dir
        chain = Chain("my-bucket", "run-7"; store = InMemoryObjectStore(), cache_dir = dir)
        create_chain(chain)
        # open does no I/O; the first sync binds the copy to the chain at slot 0.
        copy = ChainTables.open(chain, joinpath(dir, "copy"))
        @test sync!(copy).applied == 1
        @test head(copy).slot == 0
        # Nothing new: applied = 0, never an error.
        @test sync!(copy).applied == 0
        close(copy)
    end
end

@testset "the examples use only public names" begin
    @test check_all_explicit_imports_are_public(@__MODULE__, @__FILE__) === nothing
    @test check_all_qualified_accesses_are_public(@__MODULE__, @__FILE__) === nothing
end
