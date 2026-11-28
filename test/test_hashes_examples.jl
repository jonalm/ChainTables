using Test
using ChainTables: StateFingerprint, TransactionHash

@testset "TransactionHash example" begin
    # From the 32 bytes of a record's hash, or from their hex text.
    bytes = UInt8.(0:31)
    h = TransactionHash(bytes)
    @test TransactionHash(bytes2hex(bytes)) == h

    # It compares with raw bytes, and prints as hex.
    @test h == bytes
    @test bytes2hex(h) == "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"
end

@testset "StateFingerprint example" begin
    # A state fingerprint is a type of its own: the same bytes as a TransactionHash are
    # another value.
    bytes = UInt8.(0:31)
    @test StateFingerprint(bytes) == bytes
    @test StateFingerprint(bytes) != TransactionHash(bytes)
end
