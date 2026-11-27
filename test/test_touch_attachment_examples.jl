using Test
using ChainTables: ChainTables, Chain, put_attachment, touch_attachment
using ChainTables.Testing: InMemoryObjectStore

@testset "touch_attachment example" begin
    mktempdir() do dir
        chain = Chain("bkt", "lab"; store = InMemoryObjectStore(), cache_dir = dir)
        h = put_attachment(chain, IOBuffer("the bytes of a scan"))

        # Before a new row refers to an attachment that is already stored, touch it.
        @test touch_attachment(chain, h) === nothing
    end
end
