using Test
using ExplicitImports: check_all_explicit_imports_are_public,
    check_all_qualified_accesses_are_public
using ChainTables: ChainTables, Chain, attachment, put_attachment
using ChainTables.Testing: InMemoryObjectStore

@testset "attachment example" begin
    mktempdir() do dir
        chain = Chain("bkt", "lab"; store = InMemoryObjectStore(), cache_dir = dir)
        ChainTables.create_chain(chain)
        hash = put_attachment(chain, IOBuffer("a plate image"))
        copy = ChainTables.open(chain, joinpath(dir, "copy"))
        ChainTables.sync!(copy)
        # The path of a read-only file in the attachment cache, fetched on first use.
        path = attachment(copy, hash)
        @test read(path, String) == "a plate image"
    end
end

@testset "the examples use only public names" begin
    @test check_all_explicit_imports_are_public(@__MODULE__, @__FILE__) === nothing
    @test check_all_qualified_accesses_are_public(@__MODULE__, @__FILE__) === nothing
end
