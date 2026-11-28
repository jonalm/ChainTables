using Test
using ChainTables: chain_id_bytes, chain_id_string

@testset "chain_id_string example" begin
    # A transaction record holds the chain id as 16 bytes. Messages and the head file
    # hold it as 26 base32 characters.
    @test chain_id_string(UInt8.(0:15)) == "AAAQEAYEAUDAOCAJBIFQYDIOB4"
end

@testset "chain_id_bytes example" begin
    # The text back to the bytes.
    @test chain_id_bytes("AAAQEAYEAUDAOCAJBIFQYDIOB4") == UInt8.(0:15)
end
