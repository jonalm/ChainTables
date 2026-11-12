using Test
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
