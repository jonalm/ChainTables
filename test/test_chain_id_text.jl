using Test
using ChainTables: ChainTables, chain_id_bytes, chain_id_string
using StableRNGs: StableRNG

const CHAIN_ID_TEXTS = [
    (name = "0..15", bytes = UInt8.(0:15), text = "AAAQEAYEAUDAOCAJBIFQYDIOB4"),
    (name = "all zero", bytes = zeros(UInt8, 16), text = "A"^26),
    (name = "all ones", bytes = fill(0xff, 16), text = "7"^25 * "4"),
]

@testset "chain_id_string spells $(case.name) in base32" for case in CHAIN_ID_TEXTS
    @test chain_id_string(case.bytes) == case.text
    @test chain_id_bytes(case.text) == case.bytes
end

@testset "chain_id_bytes ignores case" begin
    @test chain_id_bytes(lowercase("AAAQEAYEAUDAOCAJBIFQYDIOB4")) == UInt8.(0:15)
end

const RANDOM_IDS = [
    (name = "seed $seed", bytes = rand(StableRNG(seed), UInt8, 16)) for seed in 1:20
]

@testset "chain_id_bytes inverts chain_id_string for $(case.name)" for case in RANDOM_IDS
    @test chain_id_bytes(chain_id_string(case.bytes)) == case.bytes
end

@testset "chain_id_string refuses a length other than 16 bytes" begin
    @test_throws ArgumentError "a chain id is 16 bytes, got 2" chain_id_string(UInt8[1, 2])
end

const BAD_TEXTS = [
    (name = "too short", text = "ABC", message = "a chain id is 26 base32 characters"),
    (
        name = "a digit 1",
        text = "1" * "A"^25,
        message = "is not a base32 character (A–Z, 2–7)",
    ),
    (
        name = "non-zero trailing bits",
        text = "A"^25 * "B",
        message = "its trailing bits are not zero",
    ),
]

@testset "chain_id_bytes refuses $(case.name)" for case in BAD_TEXTS
    @test_throws ArgumentError case.message chain_id_bytes(case.text)
end

@testset "chain id text functions infer" begin
    @test @inferred(chain_id_string(UInt8.(0:15))) isa String
    @test @inferred(chain_id_bytes("A"^26)) isa Vector{UInt8}
end
