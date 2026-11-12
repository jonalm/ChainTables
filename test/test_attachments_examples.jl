using Test
using ChainTables: ChainTables, Chain, put_attachment, touch_attachment
using ChainTables.Testing: InMemoryObjectStore

@testset "put_attachment example" begin
    mktempdir() do dir
        chain = Chain("bkt", "lab"; store = InMemoryObjectStore(), cache_dir = dir)
        # Put a file: the hash it returns is what a row refers to the attachment by.
        file = joinpath(dir, "plate.csv")
        write(file, "well,value\nA1,0.5\n")
        hash = put_attachment(chain, file)
        @test length(hash) == 64
        # A seekable IO works the same; putting the same bytes again uploads nothing.
        @test put_attachment(chain, IOBuffer("well,value\nA1,0.5\n")) == hash
    end
end

@testset "touch_attachment example" begin
    mktempdir() do dir
        chain = Chain("bkt", "lab"; store = InMemoryObjectStore(), cache_dir = dir)
        hash = put_attachment(chain, IOBuffer("a protocol"))
        # Before a new row reuses an attachment, extend its retention.
        @test touch_attachment(chain, hash) === nothing
    end
end
