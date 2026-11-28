using Test
using ChainTables: ChainTables, Chain, attachment, create_chain, put_attachment, sync!
using ChainTables.Testing: InMemoryObjectStore

@testset "attachment example" begin
    mktempdir() do dir
        chain = Chain("bkt", "lab"; store = InMemoryObjectStore(), cache_dir = dir)
        create_chain(chain)
        h = put_attachment(chain, IOBuffer("the bytes of a scan"))
        local_copy = ChainTables.open(chain, joinpath(dir, "copy"))
        sync!(local_copy)

        # The path of a read-only file in the attachment cache.
        path = attachment(local_copy, h)
        @test read(path, String) == "the bytes of a scan"
        close(local_copy)
    end
end
