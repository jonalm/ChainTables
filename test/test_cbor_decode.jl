using Test
using ChainTables: ChainTables, CBOR

hex_bytes(hex) = hex2bytes(replace(hex, " " => ""))

const VALUE_CASES = [
    (name = "-0.0", hex = "f98000", value = -0.0),
    (name = "0.0", hex = "f90000", value = 0.0),
    (name = "Inf", hex = "f97c00", value = Inf),
    (name = "-Inf", hex = "f9fc00", value = -Inf),
    (name = "2.0 as a float", hex = "f94000", value = 2.0),
    (name = "2 as an Int64", hex = "02", value = Int64(2)),
    (name = "an int above 2^53", hex = "1b0020000000000001", value = 9007199254740993),
    (name = "int64 max", hex = "1b7fffffffffffffff", value = typemax(Int64)),
    (name = "int64 min", hex = "3b7fffffffffffffff", value = typemin(Int64)),
    (name = "1.1", hex = "fb3ff199999999999a", value = 1.1),
]

@testset "decode reads $(case.name)" for case in VALUE_CASES
    @test CBOR.decode(hex_bytes(case.hex)) === case.value
end

@testset "decode reads the one NaN as Float64 NaN" begin
    nan = CBOR.decode(hex_bytes("f97e00"))
    @test nan isa Float64
    @test reinterpret(UInt64, nan) == 0x7ff8000000000000
end

@testset "decode keeps NFC and NFD apart" begin
    nfc = CBOR.decode(CBOR.encode("é"))
    nfd = CBOR.decode(CBOR.encode("é"))
    @test nfc == "é"
    @test nfd == "é"
    @test nfc != nfd
end

@testset "decode reads nesting 64 levels deep" begin
    @test CBOR.decode(hex_bytes("81"^64 * "00")) isa Vector{Any}
end

const REJECTED_CASES = [
    (
        name = "a duplicate map key",
        hex = "a2 6161 01 6161 02",
        message = "duplicate map key \"a\"",
    ),
    (
        name = "unsorted map keys",
        hex = "a2 6162 01 6161 02",
        message = "not in RFC 8949 §4.2.1 order",
    ),
    (
        name = "keys sorted by text, not length",
        hex = "a2 626161 01 617a 02",
        message = "not in RFC 8949 §4.2.1 order",
    ),
    (name = "an integer map key", hex = "a1 01 01", message = "map key must be text"),
    (name = "an indefinite array", hex = "9f 01 ff", message = "indefinite length"),
    (name = "an indefinite map", hex = "bf ff", message = "indefinite length"),
    (name = "indefinite bytes", hex = "5f ff", message = "indefinite length"),
    (name = "indefinite text", hex = "7f ff", message = "indefinite length"),
    (name = "a lone break", hex = "ff", message = "unexpected break"),
    (name = "tag 0", hex = "c0 6161", message = "tag 0; tags are not in the format"),
    (name = "tag 32", hex = "d8 20 6161", message = "tag 32; tags are not in the format"),
    (name = "a one-byte 5", hex = "18 05", message = "not in its shortest form"),
    (name = "a two-byte 255", hex = "19 00ff", message = "not in its shortest form"),
    (name = "a four-byte 65535", hex = "1a 0000ffff", message = "not in its shortest form"),
    (
        name = "an eight-byte 2^32-1",
        hex = "1b 00000000ffffffff",
        message = "not in its shortest form",
    ),
    (name = "a one-byte -1", hex = "38 00", message = "not in its shortest form"),
    (
        name = "a one-byte length",
        hex = "58 03 010203",
        message = "not in its shortest form",
    ),
    (
        name = "1.0 as float64",
        hex = "fb 3ff0000000000000",
        message = "not in its shortest form",
    ),
    (name = "1.0 as float32", hex = "fa 3f800000", message = "not in its shortest form"),
    (
        name = "100000.0 as float64",
        hex = "fb 47c3500000000000",
        message = "not in its shortest form",
    ),
    (name = "Inf as float32", hex = "fa 7f800000", message = "not in its shortest form"),
    (name = "a payload NaN", hex = "f9 7e01", message = "NaN must be encoded as f97e00"),
    (name = "a sign-bit NaN", hex = "f9 fe00", message = "NaN must be encoded as f97e00"),
    (
        name = "a float32 NaN",
        hex = "fa 7fc00000",
        message = "NaN must be encoded as f97e00",
    ),
    (
        name = "a float64 NaN",
        hex = "fb 7ff8000000000000",
        message = "NaN must be encoded as f97e00",
    ),
    (name = "simple undefined", hex = "f7", message = "simple value undefined"),
    (name = "simple 32", hex = "f8 20", message = "simple value 32"),
    (name = "simple 0", hex = "e0", message = "simple value 0"),
    (
        name = "reserved information 28",
        hex = "1c",
        message = "reserved additional information 28",
    ),
    (
        name = "an int above int64",
        hex = "1b 8000000000000000",
        message = "exceeds the int64 domain",
    ),
    (
        name = "an int below int64",
        hex = "3b 8000000000000000",
        message = "below the int64 domain",
    ),
    (name = "trailing bytes", hex = "01 01", message = "trailing bytes"),
    (name = "a truncated argument", hex = "19 03", message = "truncated input"),
    (name = "a truncated array", hex = "82 01", message = "truncated input"),
    (name = "truncated text", hex = "63 6162", message = "truncated input"),
    (name = "no bytes", hex = "", message = "truncated input"),
    (name = "invalid UTF-8", hex = "62c328", message = "not well-formed UTF-8"),
    (name = "U+0000", hex = "63610062", message = "U+0000"),
    (
        name = "a string over the cap",
        hex = "5a 04000001",
        message = "exceeds the 64 MiB record cap",
    ),
    (
        name = "65 levels of nesting",
        hex = "81"^65 * "00",
        message = "nesting deeper than 64 levels",
    ),
]

@testset "decode rejects $(case.name)" for case in REJECTED_CASES
    @test_throws CBOR.DecodeError case.message CBOR.decode(hex_bytes(case.hex))
end

@testset "decode names the byte offset of a rejection" begin
    e = try
        CBOR.decode(hex_bytes("8201f7"))
    catch caught
        caught
    end
    @test e isa CBOR.DecodeError
    @test e.offset == 2
end

@testset "decode from a stream reads one item and leaves the rest" begin
    io = IOBuffer(vcat(CBOR.encode(1), CBOR.encode("a")))
    @test CBOR.decode(io) == 1
    @test CBOR.decode(io) == "a"
    @test eof(io)
end

@testset "read_array_header reads the count and leaves the items" begin
    io = IOBuffer(CBOR.encode(Any[Any[1], Any[2]]))
    @test CBOR.read_array_header(io) == 2
    @test CBOR.decode(io) == [1]
    @test CBOR.decode(io) == [2]
    @test eof(io)
end

@testset "read_array_header rejects a map head" begin
    @test_throws(
        CBOR.DecodeError, "expected an array head",
        CBOR.read_array_header(IOBuffer(hex_bytes("a0"))),
    )
end

@testset "DecodeError shows the summary, detail, offset and next move" begin
    text = sprint(showerror, CBOR.DecodeError(; offset = 2, detail = "simple value 0"))
    @test startswith(
        text,
        "DecodeError: the bytes are not the CBOR profile of the format: simple value 0.",
    )
    @test occursin("offset = 2", text)
    @test occursin("Check that the bytes were written by `CBOR.encode`", text)
end

@testset "DecodeError is a ChainTablesError" begin
    @test CBOR.DecodeError() isa ChainTables.ChainTablesError
end

@testset "DecodeError constructor infers" begin
    @test @inferred(CBOR.DecodeError(; offset = 1, detail = "x")).offset == 1
end
