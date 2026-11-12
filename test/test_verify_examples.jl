using Test
using ExplicitImports: check_all_explicit_imports_are_public,
    check_all_qualified_accesses_are_public
using ChainTables: ChainTables, Chain, FingerprintMismatchError, column!, commit!,
    create_chain, create_table!, primary_key!, sync!, verify, write_builder
using ChainTables.Testing: InMemoryObjectStore

@testset "verify example" begin
    mktempdir() do dir
        chain = Chain("my-bucket", "run-7"; store = InMemoryObjectStore(), cache_dir = dir)
        create_chain(chain)
        copy = ChainTables.open(chain, joinpath(dir, "copy"))
        sync!(copy)
        w = write_builder(copy)
        create_table!(w, :samples) do t
            column!(t, :id, Int64)
            primary_key!(t, :id)
        end
        commit!(w)
        # A sound copy verifies to nothing; the full form also replays the record cache.
        @test verify(copy) === nothing
        @test verify(copy; full = true) === nothing
        # A table file whose bytes changed is a damaged copy, and verify says so.
        file = only(readdir(joinpath(copy.path, "tables"); join = true))
        write(file, b"damaged")
        @test_throws FingerprintMismatchError "hashes to" verify(copy)
        close(copy)
    end
end

@testset "the examples use only public names" begin
    @test check_all_explicit_imports_are_public(@__MODULE__, @__FILE__) === nothing
    @test check_all_qualified_accesses_are_public(@__MODULE__, @__FILE__) === nothing
end
