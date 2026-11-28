using Test
using ChainTables: CBOR

@testset "decode example" begin
    # The bytes of one item become Julia values: a map is a Dict with text keys, an
    # array a Vector{Any}, null is missing.
    item = CBOR.decode(hex2bytes("a2636f70738366696e73657274f93e00f664736c6f7407"))
    expected = Dict{String, Any}("slot" => 7, "ops" => Any["insert", 1.5, missing])
    @test isequal(item, expected)

    # From a stream, decode reads exactly one item.
    io = IOBuffer(hex2bytes("0718ff"))
    @test CBOR.decode(io) == 7
    @test CBOR.decode(io) == 255
end

@testset "read_array_header example" begin
    # Read an array too large to hold: its head first, then one item at a time.
    io = IOBuffer(CBOR.encode([10, 20, 30]))
    n = CBOR.read_array_header(io)
    @test [CBOR.decode(io) for _ in 1:n] == [10, 20, 30]
end
