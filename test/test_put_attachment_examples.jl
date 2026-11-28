using Test
using ChainTables: ChainTables, Chain, put_attachment
using ChainTables.Testing: InMemoryObjectStore

@testset "put_attachment example" begin
    mktempdir() do dir
        chain = Chain("bkt", "lab"; store = InMemoryObjectStore(), cache_dir = dir)

        # Put a file: the hash that comes back is what a row stores to refer to it.
        scan = joinpath(dir, "scan.tif")
        write(scan, "the bytes of a scan")
        h = put_attachment(chain, scan)
        @test length(h) == 64

        # The same bytes from an IO give the same hash, and are not stored twice.
        @test put_attachment(chain, IOBuffer("the bytes of a scan")) == h
    end
end
