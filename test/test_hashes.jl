using Test
using ChainTables: ChainTables, StateFingerprint, TransactionHash

const BYTES = UInt8.(0:31)
const HEX = bytes2hex(BYTES)
const HASH_TYPES = [
    (name = "TransactionHash", T = TransactionHash),
    (name = "StateFingerprint", T = StateFingerprint),
]

@testset "$(case.name) holds its own copy of 32 bytes" for case in HASH_TYPES
    h = case.T(BYTES)
    @test h.bytes == BYTES
    @test h.bytes !== BYTES
    @test case.T(h) === h
end

@testset "$(case.name) reads hex in either case" for case in HASH_TYPES
    h = case.T(BYTES)
    @test case.T(HEX) == h
    @test case.T(uppercase(HEX)) == h
    @test bytes2hex(h) == HEX
end

@testset "$(case.name) equals its bytes and hashes as them" for case in HASH_TYPES
    h = case.T(BYTES)
    @test h == BYTES
    @test BYTES == h
    @test isequal(h, case.T(copy(BYTES)))
    @test hash(h) == hash(case.T(copy(BYTES)))
    @test hash(h) == hash(BYTES)
    @test h != case.T(zeros(UInt8, 32))
    @test h != zeros(UInt8, 32)
end

@testset "$(case.name) shows as its constructor call" for case in HASH_TYPES
    @test sprint(show, case.T(BYTES)) == "$(case.name)(\"$HEX\")"
end

@testset "$(case.name) refuses what is not 32 bytes" for case in HASH_TYPES
    @test_throws ArgumentError "a $(case.name) is 32 bytes, got 2" case.T(UInt8[1, 2])
    @test_throws ArgumentError "a $(case.name) is 32 bytes, got 31" case.T(HEX[1:62])
    @test_throws ArgumentError "is not 64 hex characters" case.T("zz" * HEX[3:end])
    @test_throws(
        ArgumentError, "is 32 bytes or 64 hex characters, got a value of type Int64",
        case.T(7),
    )
end

@testset "TransactionHash and StateFingerprint never equal or accept each other" begin
    th = TransactionHash(BYTES)
    fp = StateFingerprint(BYTES)
    @test th != fp
    @test fp != th
    @test !isequal(th, fp)
    # The type prints qualified or not depending on what the caller imported.
    @test_throws(
        ArgumentError,
        "a TransactionHash is 32 bytes or 64 hex characters, got a value of type " *
            "$StateFingerprint",
        TransactionHash(fp),
    )
    @test_throws ArgumentError "got a value of type $TransactionHash" StateFingerprint(th)
end

@testset "$(case.name) round-trips through a Dict and a Set" for case in HASH_TYPES
    @test Dict(case.T(BYTES) => 1)[case.T(HEX)] == 1
    @test case.T(BYTES) in Set([case.T(copy(BYTES))])
    @test (case.T(BYTES) == case.T(BYTES)) isa Bool
end

@testset "$(case.name) constructors infer" for case in HASH_TYPES
    @test @inferred(case.T(BYTES)) == BYTES
    @test @inferred(case.T(HEX)) == BYTES
end
