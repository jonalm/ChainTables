using Test
using ChainTables: CBOR
# The decoder's own error is the subject here: a record or a table file names it only
# through the public error it becomes.
using ChainTables.CBOR: DecodeError

include("fixtures/cbor_corpus.jl")
include("fixtures/cbor_hand_written.jl")
include("fixtures/internal_errors.jl")

decoded_hex(hex) = CBOR.decode(hex2bytes(replace(hex, " " => "")))

# The decoder yields the canonical NaN, so a NaN of the corpus compares by its bits.
bits_of(value) = reinterpret(UInt64, isnan(value) ? NaN : value)

const DECODED_VALUES = [
    (name = "-0.0", hex = "f98000", value = -0.0),
    (name = "0.0", hex = "f90000", value = 0.0),
    (name = "Inf", hex = "f97c00", value = Inf),
    (name = "-Inf", hex = "f9fc00", value = -Inf),
    (name = "a float64 2.0 stays a float", hex = "f94000", value = 2.0),
    (name = "an integer 2", hex = "02", value = Int64(2)),
    (name = "an integer above 2^53", hex = "1b0020000000000001", value = 9007199254740993),
    (name = "the largest int64", hex = "1b7fffffffffffffff", value = typemax(Int64)),
    (name = "the smallest int64", hex = "3b7fffffffffffffff", value = typemin(Int64)),
    (name = "1.1", hex = "fb3ff199999999999a", value = 1.1),
]

const DECODE_REFUSALS = [
    (hex = "a2 6161 01 6161 02", fragment = "duplicate map key \"a\""),
    (hex = "a2 6162 01 6161 02", fragment = "not in RFC 8949 §4.2.1 order"),
    # length first: "z" sorts before "aa"
    (hex = "a2 626161 01 617a 02", fragment = "not in RFC 8949 §4.2.1 order"),
    (hex = "a1 01 01", fragment = "map key must be text"),
    (hex = "9f 01 ff", fragment = "indefinite length"),
    (hex = "bf ff", fragment = "indefinite length"),
    (hex = "5f ff", fragment = "indefinite length"),
    (hex = "7f ff", fragment = "indefinite length"),
    (hex = "ff", fragment = "unexpected break"),
    (hex = "c0 6161", fragment = "tag 0; tags are not in the format"),
    (hex = "d8 20 6161", fragment = "tag 32; tags are not in the format"),
    (hex = "18 05", fragment = "not in its shortest form"),
    (hex = "19 00ff", fragment = "not in its shortest form"),
    (hex = "1a 0000ffff", fragment = "not in its shortest form"),
    (hex = "1b 00000000ffffffff", fragment = "not in its shortest form"),
    (hex = "38 00", fragment = "not in its shortest form"),
    # a length is a head argument too
    (hex = "58 03 010203", fragment = "not in its shortest form"),
    # 1.0 as float64, 1.0 as float32, 100000.0 as float64, Inf as float32
    (hex = "fb 3ff0000000000000", fragment = "not in its shortest form"),
    (hex = "fa 3f800000", fragment = "not in its shortest form"),
    (hex = "fb 47c3500000000000", fragment = "not in its shortest form"),
    (hex = "fa 7f800000", fragment = "not in its shortest form"),
    (hex = "f9 7e01", fragment = "NaN must be encoded as f97e00"),
    # a NaN with its sign bit set
    (hex = "f9 fe00", fragment = "NaN must be encoded as f97e00"),
    (hex = "fa 7fc00000", fragment = "NaN must be encoded as f97e00"),
    (hex = "fb 7ff8000000000000", fragment = "NaN must be encoded as f97e00"),
    (hex = "f7", fragment = "simple value undefined"),
    (hex = "f8 20", fragment = "simple value 32"),
    (hex = "e0", fragment = "simple value 0"),
    (hex = "1c", fragment = "reserved additional information 28"),
    (hex = "1b 8000000000000000", fragment = "exceeds the int64 domain"),
    (hex = "3b 8000000000000000", fragment = "below the int64 domain"),
    (hex = "01 01", fragment = "trailing bytes"),
    (hex = "19 03", fragment = "truncated input"),
    (hex = "82 01", fragment = "truncated input"),
    (hex = "63 6162", fragment = "truncated input"),
    (hex = "", fragment = "truncated input"),
    (hex = "5a 04000001", fragment = "exceeds the 64 MiB record cap"),
    (hex = "81"^65 * "00", fragment = "nesting deeper than 64 levels"),
    (hex = "62c328", fragment = "not well-formed UTF-8"),
    (hex = "63610062", fragment = "U+0000"),
]

@testset "decode reads the hand-written record fixture" begin
    @test isequal(CBOR.decode(hex2bytes(HAND_WRITTEN_HEX)), HAND_WRITTEN_RECORD)
end

@testset "decode reads numbers bit for bit" begin
    @testset "$(case.name)" for case in DECODED_VALUES
        @test decoded_hex(case.hex) === case.value
    end
end

@testset "decode yields the one NaN of the format" begin
    nan = decoded_hex("f97e00")
    @test nan isa Float64
    @test reinterpret(UInt64, nan) == 0x7ff8000000000000
end

@testset "decode keeps an NFC and an NFD spelling apart" begin
    nfc = decoded_hex("62c3a9")
    nfd = decoded_hex("6365cc81")
    @test nfc == "é"
    @test nfd == "é"
    @test nfc != nfd
end

@testset "decode refuses what is outside the profile" begin
    @testset "$(case.hex[1:min(end, 20)]): $(case.fragment)" for case in DECODE_REFUSALS
        @test_throws DecodeError as_shown(case.fragment) decoded_hex(case.hex)
    end
end

@testset "decode follows 64 levels of nesting" begin
    @test decoded_hex("81"^64 * "00") isa Vector{Any}
end

@testset "decode names the byte where it found the violation" begin
    err = (@test_throws DecodeError "simple value undefined" decoded_hex("8201f7")).value
    @test err.offset == 2
    @test err.detail == "simple value undefined (0xf7) is not in the format"
end

@testset "decode inverts the frozen conformance corpus" begin
    @testset "$name" for (name, value) in CBOR_CORPUS
        decoded = CBOR.decode(hex2bytes(CBOR_FROZEN_HEX[name]))
        @test isequal(decoded, value)
    end
end

@testset "decode keeps -0.0 and yields the canonical NaN, over the corpus" begin
    floats = [(name, value) for (name, value) in CBOR_CORPUS if value isa Float64]
    @testset "$name" for (name, value) in floats
        decoded = CBOR.decode(hex2bytes(CBOR_FROZEN_HEX[name]))
        @test reinterpret(UInt64, decoded) == bits_of(value)
    end
end

@testset "decode from an IO reads one item and leaves the stream after it" begin
    io = IOBuffer(hex2bytes("0102"))
    @test CBOR.decode(io) === Int64(1)
    @test CBOR.decode(io) === Int64(2)
    @test eof(io)
end

@testset "read_array_header reads a streamed array back" begin
    shape = Dict{String, Any}("key" => Any["id"])
    rows = Any[Any[1], Any[2], Any[3]]
    io = IOBuffer(CBOR.encode(Any[shape, rows]))
    @test @inferred(CBOR.read_array_header(io)) == 2
    @test isequal(CBOR.decode(io), shape)
    @test CBOR.read_array_header(io) == 3
    @test [CBOR.decode(io) for _ in 1:3] == rows
    @test eof(io)
end

@testset "read_array_header refuses an item that is not an array" begin
    io = IOBuffer(hex2bytes("a0"))
    @test_throws DecodeError "expected an array head" CBOR.read_array_header(io)
end
