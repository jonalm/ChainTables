using Test
using ExplicitImports: check_all_explicit_imports_are_public,
    check_all_qualified_accesses_are_public
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

@testset "the examples use only public names" begin
    @test check_all_explicit_imports_are_public(@__MODULE__, @__FILE__) === nothing
    @test check_all_qualified_accesses_are_public(@__MODULE__, @__FILE__) === nothing
end
