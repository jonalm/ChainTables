using Test
using ChainTables: chain_id_bytes, chain_id_string

# RFC 4648 base32 of 16 bytes, without the padding.
const CHAIN_ID_TEXTS = [
    (name = "0 to 15", bytes = UInt8.(0:15), text = "AAAQEAYEAUDAOCAJBIFQYDIOB4"),
    (name = "all zero", bytes = zeros(UInt8, 16), text = "A"^26),
    (name = "all ones", bytes = fill(0xff, 16), text = "7"^25 * "4"),
    (name = "0x11", bytes = fill(0x11, 16), text = "CEIRCEIRCEIRCEIRCEIRCEIRCE"),
    (
        name = "mixed", bytes = hex2bytes("00ff10ef20df30cf40bf50af609f708f"),
        text = "AD7RB3ZA34YM6QF7KCXWBH3QR4",
    ),
]

@testset "chain_id_string writes 16 bytes as 26 base32 characters" begin
    @testset "$(case.name)" for case in CHAIN_ID_TEXTS
        @test @inferred(chain_id_string(case.bytes)) == case.text
    end
end

@testset "chain_id_string refuses anything but 16 bytes" begin
    @test_throws ArgumentError "a chain id is 16 bytes, got 2" chain_id_string(UInt8[1, 2])
end

@testset "chain_id_bytes reads the text back" begin
    @testset "$(case.name)" for case in CHAIN_ID_TEXTS
        @test @inferred(chain_id_bytes(case.text)) == case.bytes
    end
end

@testset "chain_id_bytes ignores case" begin
    @test chain_id_bytes("aaaqeayeaudaocajbifqydiob4") == UInt8.(0:15)
end

@testset "chain_id_bytes refuses another length" begin
    @test_throws(
        ArgumentError, "a chain id is 26 base32 characters, got \"ABC\"",
        chain_id_bytes("ABC")
    )
end

@testset "chain_id_bytes refuses a character outside the alphabet" begin
    @test_throws(
        ArgumentError, "'1' in \"1AAAAAAAAAAAAAAAAAAAAAAAAA\" is not a base32 character",
        chain_id_bytes("1" * "A"^25)
    )
end

@testset "chain_id_bytes refuses trailing bits that are not zero" begin
    @test_throws(
        ArgumentError, "its trailing bits are not zero", chain_id_bytes("A"^25 * "B")
    )
end
