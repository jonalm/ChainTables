using Test
using ChainTables: CBOR

@testset "encode example" begin
    # One value in, its deterministic CBOR bytes out.
    @test CBOR.encode(1) == [0x01]
    # Map keys are sorted on their encoded bytes, so the input order never matters.
    @test CBOR.encode((b = 2, a = 1)) == CBOR.encode(Dict("a" => 1, "b" => 2))
    # A float takes its shortest exact width, and -0.0 keeps its sign.
    @test bytes2hex(CBOR.encode(-0.0)) == "f98000"
    # Writing to a stream returns the byte count.
    io = IOBuffer()
    @test CBOR.encode(io, "abc") == 4
end
