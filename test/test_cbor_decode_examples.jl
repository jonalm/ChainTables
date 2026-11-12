using Test
using ChainTables: CBOR

@testset "decode example" begin
    # decode inverts encode: integers come back as Int64, maps as Dict{String,Any}.
    bytes = CBOR.encode((id = 7, name = "x"))
    @test CBOR.decode(bytes) == Dict{String, Any}("id" => 7, "name" => "x")
    # From a stream, it reads one item and leaves the stream after it.
    io = IOBuffer(vcat(CBOR.encode(1), CBOR.encode(2)))
    @test CBOR.decode(io) == 1
    @test CBOR.decode(io) == 2
end

@testset "DecodeError example" begin
    # Bytes outside the profile are refused, naming the byte offset.
    e = try
        CBOR.decode([0x18, 0x05]) # 5 written in two bytes, not its shortest form
    catch caught
        caught
    end
    @test e isa CBOR.DecodeError
    @test e.offset == 0
end
