using Test
using ExplicitImports: check_all_explicit_imports_are_public,
    check_all_qualified_accesses_are_public
using ChainTables: StateFingerprint, TransactionHash

@testset "TransactionHash example" begin
    # A transaction hash is 32 bytes; it reads them raw or as 64 hex characters.
    h = TransactionHash(fill(0xab, 32))
    @test bytes2hex(h) == "ab"^32
    @test TransactionHash("AB"^32) == h
    # It equals its raw bytes, so Evidence compares with computed bytes.
    @test h == fill(0xab, 32)
end

@testset "StateFingerprint example" begin
    fp = StateFingerprint("01"^32)
    @test fp == fill(0x01, 32)
    # The two hash types are never equal, even over the same bytes.
    @test fp != TransactionHash("01"^32)
end

@testset "the examples use only public names" begin
    @test check_all_explicit_imports_are_public(@__MODULE__, @__FILE__) === nothing
    @test check_all_qualified_accesses_are_public(@__MODULE__, @__FILE__) === nothing
end
