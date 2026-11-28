using Test
using ChainTables: StateFingerprint, TransactionHash

const HASH_BYTES = UInt8.(0:31)
const HASH_HEX = bytes2hex(HASH_BYTES)
const BOTH_HASH_TYPES = [
    (name = "TransactionHash", T = TransactionHash),
    (name = "StateFingerprint", T = StateFingerprint),
]

@testset "$(case.name) holds its own copy of 32 bytes" for case in BOTH_HASH_TYPES
    bytes = copy(HASH_BYTES)
    h = case.T(bytes)
    bytes[1] = 0xff
    @test h.bytes == HASH_BYTES
end

@testset "$(case.name) reads 64 hex characters, in either case" for case in BOTH_HASH_TYPES
    @test case.T(HASH_HEX) == case.T(HASH_BYTES)
    @test case.T(uppercase(HASH_HEX)) == case.T(HASH_BYTES)
end

@testset "TransactionHash infers from bytes and from hex" begin
    @test @inferred(TransactionHash(HASH_BYTES)) == TransactionHash(HASH_HEX)
    @test @inferred(TransactionHash(HASH_HEX)) == TransactionHash(HASH_BYTES)
end

@testset "StateFingerprint infers from bytes and from hex" begin
    @test @inferred(StateFingerprint(HASH_BYTES)) == StateFingerprint(HASH_HEX)
    @test @inferred(StateFingerprint(HASH_HEX)) == StateFingerprint(HASH_BYTES)
end

@testset "$(case.name) of a $(case.name) is that value" for case in BOTH_HASH_TYPES
    h = case.T(HASH_BYTES)
    @test case.T(h) === h
end

@testset "$(case.name) gives its hex text" for case in BOTH_HASH_TYPES
    h = case.T(HASH_BYTES)
    @test bytes2hex(h) == HASH_HEX
    @test sprint(show, h) == "$(case.name)(\"$HASH_HEX\")"
end

@testset "$(case.name) equals its bytes, either way round" for case in BOTH_HASH_TYPES
    h = case.T(HASH_BYTES)
    @test (h == HASH_BYTES) === true
    @test (HASH_BYTES == h) === true
    @test (h == zeros(UInt8, 32)) === false
end

@testset "$(case.name) conforms: one key of a Dict and a Set" for case in BOTH_HASH_TYPES
    h = case.T(HASH_BYTES)
    twin = case.T(copy(HASH_BYTES))
    @test (h == twin) === true
    @test isequal(h, twin) === true
    @test (h == case.T(zeros(UInt8, 32))) === false
    @test hash(h) == hash(twin) == hash(HASH_BYTES)
    @test Dict(h => 1)[case.T(HASH_HEX)] == 1
    @test twin in Set([h])
end

@testset "$(case.name) refuses bytes that are not 32" for case in BOTH_HASH_TYPES
    @test_throws ArgumentError "a $(case.name) is 32 bytes, got 2" case.T(UInt8[1, 2])
    @test_throws ArgumentError "a $(case.name) is 32 bytes, got 31" case.T(HASH_HEX[1:62])
end

@testset "$(case.name) refuses text that is not hex" for case in BOTH_HASH_TYPES
    @test_throws ArgumentError "is not 64 hex characters" case.T("zz" * HASH_HEX[3:end])
    @test_throws ArgumentError "is not 64 hex characters" case.T(HASH_HEX[1:63])
end

@testset "$(case.name) refuses a value that is neither" for case in BOTH_HASH_TYPES
    @test_throws(
        ArgumentError, "is 32 bytes or 64 hex characters, got a value of type Int64",
        case.T(7)
    )
end

@testset "TransactionHash and StateFingerprint are never equal" begin
    transaction_hash = TransactionHash(HASH_BYTES)
    fingerprint = StateFingerprint(HASH_BYTES)
    @test (transaction_hash == fingerprint) === false
    @test (fingerprint == transaction_hash) === false
    @test isequal(transaction_hash, fingerprint) === false
end

# A type's name in a message is qualified wherever the type is not imported into `Main`,
# so the fragment stops before it.
@testset "TransactionHash and StateFingerprint never accept each other" begin
    refused = "is 32 bytes or 64 hex characters, got a value of type"
    fingerprint = StateFingerprint(HASH_BYTES)
    err = (
        @test_throws ArgumentError "a TransactionHash $refused" TransactionHash(
            fingerprint
        )
    ).value
    @test endswith(err.msg, "StateFingerprint")
    transaction_hash = TransactionHash(HASH_BYTES)
    err = (
        @test_throws ArgumentError "a StateFingerprint $refused" StateFingerprint(
            transaction_hash
        )
    ).value
    @test endswith(err.msg, "TransactionHash")
end
