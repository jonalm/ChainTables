using Test
using ChainTables: CBOR

@testset "encode example" begin
    # A value becomes its one deterministic encoding: a map's keys are sorted, and a
    # float takes the shortest form that keeps its value.
    bytes = CBOR.encode(Dict("slot" => 7, "ops" => ["insert", 1.5, missing]))
    @test bytes2hex(bytes) == "a2636f70738366696e73657274f93e00f664736c6f7407"

    # The same value written to a stream; the result is the byte count.
    io = IOBuffer()
    @test CBOR.encode(io, (slot = 7,)) == 7
    @test bytes2hex(take!(io)) == "a164736c6f7407"
end

@testset "write_array_header example" begin
    # Write an array too large to hold: its head first, then one item at a time.
    io = IOBuffer()
    CBOR.write_array_header(io, 3)
    foreach(item -> CBOR.encode(io, item), (10, 20, 30))
    @test take!(io) == CBOR.encode([10, 20, 30])
end
