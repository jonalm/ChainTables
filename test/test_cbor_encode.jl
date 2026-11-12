# Over 400 lines: the 96 frozen corpus cases belong with the encoder they freeze.
using Test
using ChainTables: CBOR

# The bytes of a record-shaped map, written by hand from RFC 8949 Appendix A and the
# §4.2.1 key order: the one check against the standard rather than the encoder (ADR-0006).
const FIXTURE = Dict{String, Any}(
    "format_version" => 1,
    "chain_id" => UInt8.(0:15),
    "slot" => 0,
    "state_fingerprint" => UInt8.(0:31),
    "client" => Dict{String, Any}(
        "host" => "h", "user" => "u", "lib" => "ChainTables 0.1.0",
        "julia" => "1.12.7", "time_ms" => 1000,
    ),
    "comment" => "ü",
    "ops" => Any[
        Dict{String, Any}(
            "op" => "insert", "table" => "t",
            "rows" => Any[
                Any[1, -0.0, "水", UInt8[1, 2, 3, 4], true, missing, -1, 1.1, 100000.0],
            ],
        ),
    ],
)

# Keys sort bytewise on the encoded key, so length first: "ops" < "slot" < "client".
const FIXTURE_HEX = join(
    [
        "a7",                                       # map(7)
        "63 6f7073",                                #   "ops"
        "81",                                       #     array(1)
        "a3",                                       #       map(3)
        "62 6f70", "66 696e73657274",               #         "op": "insert"
        "64 726f7773",                              #         "rows"
        "81", "89",                                 #           [[ 9 cells ]]
        "01",                                       #             1            (App. A)
        "f9 8000",                                  #             -0.0         (App. A)
        "63 e6b0b4",                                #             "水"         (App. A)
        "44 01020304",                              #             h'01020304'  (App. A)
        "f5", "f6",                                 #             true, null   (App. A)
        "20",                                       #             -1           (App. A)
        "fb 3ff199999999999a",                      #             1.1          (App. A)
        "fa 47c35000",                              #             100000.0     (App. A)
        "65 7461626c65", "61 74",                   #         "table": "t"
        "64 736c6f74", "00",                        #   "slot": 0
        "66 636c69656e74",                          #   "client"
        "a5",                                       #     map(5)
        "63 6c6962",                                #     "lib"
        "71 436861696e5461626c657320302e312e30",    #       "ChainTables 0.1.0"
        "64 686f7374", "61 68",                     #     "host": "h"
        "64 75736572", "61 75",                     #     "user": "u"
        "65 6a756c6961", "66 312e31322e37",         #     "julia": "1.12.7"
        "67 74696d655f6d73", "19 03e8",             #     "time_ms": 1000 (App. A)
        "67 636f6d6d656e74", "62 c3bc",             #   "comment": "ü"  (App. A)
        "68 636861696e5f6964",                      #   "chain_id"
        "50 000102030405060708090a0b0c0d0e0f",      #     16 bytes
        "6e 666f726d61745f76657273696f6e", "01",    #   "format_version": 1
        "71 73746174655f66696e6765727072696e74",    #   "state_fingerprint"
        "5820 000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f",
    ]
)

hex_bytes(hex) = hex2bytes(replace(hex, " " => ""))

@testset "encode writes the hand-written fixture" begin
    @test CBOR.encode(FIXTURE) == hex_bytes(FIXTURE_HEX)
    @test isequal(CBOR.decode(hex_bytes(FIXTURE_HEX)), FIXTURE)
end

@testset "encode to a stream writes the same bytes and returns their count" begin
    io = IOBuffer()
    @test CBOR.encode(io, FIXTURE) == length(hex_bytes(FIXTURE_HEX))
    @test take!(io) == hex_bytes(FIXTURE_HEX)
end

const NUMBER_CASES = [
    (name = "-0.0 survives float shortening", value = -0.0, hex = "f98000"),
    (name = "0.0", value = 0.0, hex = "f90000"),
    (name = "NaN is f97e00", value = NaN, hex = "f97e00"),
    (
        name = "sign-bit NaN",
        value = reinterpret(Float64, 0xfff8000000000000),
        hex = "f97e00",
    ),
    (
        name = "payload NaN",
        value = reinterpret(Float64, 0x7ff8000000000001),
        hex = "f97e00",
    ),
    (name = "NaN32", value = NaN32, hex = "f97e00"),
    (name = "Inf", value = Inf, hex = "f97c00"),
    (name = "-Inf", value = -Inf, hex = "f9fc00"),
    (name = "float64 2.0 stays a float", value = 2.0, hex = "f94000"),
    (name = "int 2", value = 2, hex = "02"),
    (name = "int above 2^53 is exact", value = 2^53 + 1, hex = "1b0020000000000001"),
    (name = "int64 max", value = typemax(Int64), hex = "1b7fffffffffffffff"),
    (name = "int64 min", value = typemin(Int64), hex = "3b7fffffffffffffff"),
    (name = "1.1 needs float64", value = 1.1, hex = "fb3ff199999999999a"),
    (name = "100000.0 fits float32", value = 100000.0, hex = "fa47c35000"),
    (name = "smallest float16 subnormal", value = 5.960464477539063e-8, hex = "f90001"),
    (name = "Int32 widens", value = Int32(5), hex = "05"),
    (name = "Int8 widens", value = Int8(-1), hex = "20"),
    (name = "Float32 widens", value = Float32(1.5), hex = "f93e00"),
    (name = "true", value = true, hex = "f5"),
    (name = "false", value = false, hex = "f4"),
    (name = "missing is null", value = missing, hex = "f6"),
]

@testset "encode writes $(case.name)" for case in NUMBER_CASES
    @test bytes2hex(CBOR.encode(case.value)) == case.hex
end

const REFUSED_CASES = [
    (
        name = "UInt64 above int64",
        value = UInt64(2)^63,
        message = "outside the int64 domain",
    ),
    (name = "BigInt above int64", value = big(2)^64, message = "outside the int64 domain"),
    (name = "BigFloat", value = big"0.1", message = "not exactly representable as Float64"),
    (name = "nothing", value = nothing, message = "null is spelled missing"),
    (name = "Rational", value = 1 // 2, message = "cannot encode a value of type Rational"),
    (name = "an integer map key", value = Dict(1 => 2), message = "map keys are text"),
    (
        name = "invalid UTF-8",
        value = String(UInt8[0xc3, 0x28]),
        message = "not well-formed UTF-8",
    ),
    (name = "U+0000", value = "a\0b", message = "U+0000"),
    (
        name = "a key given as text and Symbol",
        value = Dict("a" => 1, :a => 2),
        message = "duplicate map key \"a\"",
    ),
]

@testset "encode refuses $(case.name)" for case in REFUSED_CASES
    @test_throws ArgumentError case.message CBOR.encode(case.value)
end

const CONTAINER_CASES = [
    (name = "empty array", value = Any[], hex = "80"),
    (name = "tuple", value = (1, "a", missing), hex = "83016161f6"),
    (name = "empty map", value = Dict{String, Any}(), hex = "a0"),
    (name = "NamedTuple", value = (b = 2, a = 1), hex = "a2616101616202"),
    (
        name = "keys length first",
        value = Dict("z" => 1, "aa" => 2, "a" => 3),
        hex = "a3616103617a0162616102",
    ),
    (name = "Vector{UInt8} is bytes", value = UInt8[1, 2], hex = "420102"),
    (name = "other integer vectors are arrays", value = Any[0x01, 0x02], hex = "820102"),
    (name = "NFC é", value = "é", hex = "62c3a9"),
    (name = "NFD é, another value", value = "e\u0301", hex = "6365cc81"),
]

@testset "encode writes $(case.name)" for case in CONTAINER_CASES
    @test bytes2hex(CBOR.encode(case.value)) == case.hex
end

@testset "encode of a SubString writes its text" begin
    @test CBOR.decode(CBOR.encode(SubString("xyz", 2))) == "yz"
end

@testset "encode streams a table-file-shaped value item by item" begin
    shape = Dict{String, Any}(
        "columns" => Any[Any["id", "int64", false]], "key" => Any["id"],
    )
    rows = Any[Any[1], Any[2], Any[3]]
    io = IOBuffer()
    n = CBOR.write_array_header(io, 2) + CBOR.encode(io, shape)
    n += CBOR.write_array_header(io, length(rows))
    n += sum([CBOR.encode(io, row) for row in rows])
    bytes = take!(io)
    @test n == length(bytes)
    @test bytes == CBOR.encode(Any[shape, rows])
end

@testset "encode infers" begin
    @test @inferred(CBOR.encode(1)) == [0x01]
    @test @inferred(CBOR.encode(IOBuffer(), "a")) == 2
end

corpus_hex(name, hex) = (; name, hex)

# The frozen conformance corpus: values, and the hex a three-way differential run (this
# encoder, cbor2 6.1.4 canonical, fxamacker/cbor v2.9.3 CoreDetEncOptions) agreed on byte
# for byte on 2026-09-13 (test/data/cbor_corpus). A changed byte is a chain break.
const CORPUS_VALUES = Dict{String, Any}(
    "int_0" => 0,
    "int_1" => 1,
    "int_10" => 10,
    "int_23" => 23,
    "int_24" => 24,
    "int_25" => 25,
    "int_100" => 100,
    "int_255" => 255,
    "int_256" => 256,
    "int_1000" => 1000,
    "int_65535" => 65535,
    "int_65536" => 65536,
    "int_1000000" => 1000000,
    "int_4294967295" => 4294967295,
    "int_4294967296" => 4294967296,
    "int_1000000000000" => 1000000000000,
    "int_2p53" => 2^53,
    "int_2p53_plus_1" => 2^53 + 1,
    "int_max" => typemax(Int64),
    "int_m1" => -1,
    "int_m10" => -10,
    "int_m24" => -24,
    "int_m25" => -25,
    "int_m100" => -100,
    "int_m256" => -256,
    "int_m257" => -257,
    "int_m1000" => -1000,
    "int_m65537" => -65537,
    "int_m4294967297" => -4294967297,
    "int_min" => typemin(Int64),
    "float_0" => 0.0,
    "float_m0" => -0.0,
    "float_1" => 1.0,
    "float_1_5" => 1.5,
    "float_m1_5" => -1.5,
    "float_2" => 2.0,
    "float_m4" => -4.0,
    "float_m4_1" => -4.1,
    "float_65504" => 65504.0,
    "float_65505" => 65505.0,
    "float_100000" => 100000.0,
    "float_f32_max" => 3.4028234663852886e38,
    "float_1e300" => 1.0e300,
    "float_0_1" => 0.1,
    "float_1_1" => 1.1,
    "float_f16_min_subnormal" => 5.960464477539063e-8,
    "float_f16_min_normal" => 6.103515625e-5,
    "float_f16_below_min_subnormal" => 2.9802322387695312e-8,
    "float_f32_min_subnormal" => 1.401298464324817e-45,
    "float_2p53" => 9007199254740992.0,
    "float_2p53_plus_2" => 9007199254740994.0,
    "float_m1e300" => -1.0e300,
    "float_pi" => 3.141592653589793,
    "float_inf" => Inf,
    "float_m_inf" => -Inf,
    "float_nan" => NaN,
    "float_nan_signbit" => reinterpret(Float64, 0xfff8000000000000),
    "float_nan_payload" => reinterpret(Float64, 0x7ff8000000000001),
    "text_empty" => "",
    "text_a" => "a",
    "text_ietf" => "IETF",
    "text_quote_backslash" => "\"\\",
    "text_u_umlaut" => "ü",
    "text_water" => "水",
    "text_astral" => "𐅑",
    "text_nfc_e_acute" => "é",
    "text_nfd_e_acute" => "é",
    "text_23" => "a"^23,
    "text_24" => "a"^24,
    "text_255" => "b"^255,
    "text_256" => "c"^256,
    "text_65536" => "d"^65536,
    "bytes_empty" => UInt8[],
    "bytes_01020304" => UInt8[1, 2, 3, 4],
    "bytes_23" => UInt8.(0:22),
    "bytes_24" => UInt8.(0:23),
    "bytes_255" => UInt8.(0:254),
    "bytes_256" => UInt8.(0:255),
    "true" => true,
    "false" => false,
    "null" => missing,
    "array_empty" => Any[],
    "array_123" => Any[1, 2, 3],
    "array_nested" => Any[1, Any[2, 3], Any[4, 5]],
    "array_25" => Any[1:25...],
    "array_of_floats" => Any[0.0, -0.0, Inf, -Inf, NaN, 1.0e300],
    "map_empty" => Dict{String, Any}(),
    "map_a1_b23" => Dict{String, Any}("a" => 1, "b" => Any[2, 3]),
    "array_mixed" => Any[
        1, -1, 1.5, "a", UInt8[0xff], true, false, missing, Any[], Dict{String, Any}(),
    ],
    "map_abcde" => Dict{String, Any}(
        "a" => "A", "b" => "B", "c" => "C", "d" => "D", "e" => "E",
    ),
    "map_key_order" => Dict{String, Any}(
        "z" => 1, "aa" => 2, "a" => 3, "b" => 4, "ab" => 5, "ba" => 6,
    ),
    "map_key_lengths_23_24_25" => Dict{String, Any}(
        "k"^25 => 25, "k"^23 => 23, "k"^24 => 24,
    ),
    "map_key_nonascii" => Dict{String, Any}(
        "é" => 1, "z" => 2, "zz" => 3, "水" => 4, "ab" => 5,
    ),
    "map_nested" => Dict{String, Any}(
        "outer" => Dict{String, Any}("inner" => Any[Dict{String, Any}("k" => missing)]),
    ),
    "record_shaped" => Dict{String, Any}(
        "format_version" => 1, "chain_id" => UInt8.(0:15), "slot" => 7,
        "prev_hash" => UInt8.(32:63), "state_fingerprint" => UInt8.(0:31),
        "client" => Dict{String, Any}(
            "host" => "box", "user" => "jon", "lib" => "ChainTables 0.1.0",
            "julia" => "1.12.7", "time_ms" => 1757779200000,
        ),
        "comment" => "first commit",
        "ops" => Any[
            Dict{String, Any}(
                "op" => "create_table", "table" => "t",
                "shape" => Dict{String, Any}(
                    "columns" => Any[
                        Any["id", "int64", false], Any["x", "float64", true],
                        Any["name", "text", false], Any["blob", "bytes", true],
                    ],
                    "key" => Any["id"],
                ),
            ),
            Dict{String, Any}(
                "op" => "insert", "table" => "t",
                "rows" => Any[Any[1, -0.0, "å", UInt8[0]], Any[2, missing, "z", missing]],
            ),
            Dict{String, Any}(
                "op" => "add_column", "table" => "t",
                "column" => Any["y", "float64", false], "fill" => NaN,
            ),
            Dict{String, Any}(
                "op" => "update", "table" => "t", "columns" => Any["x"],
                "rows" => Any[Any[1, Inf]],
            ),
            Dict{String, Any}("op" => "delete", "table" => "t", "keys" => Any[Any[2]]),
            Dict{String, Any}("op" => "drop_column", "table" => "t", "column" => "blob"),
            Dict{String, Any}("op" => "drop_table", "table" => "t"),
        ],
    ),
    "table_file_shaped" => Any[
        Dict{String, Any}(
            "columns" => Any[Any["id", "int64", false], Any["x", "float64", true]],
            "key" => Any["id"],
        ),
        Any[Any[typemin(Int64), -0.0], Any[0, 0.0], Any[typemax(Int64), missing]],
    ],
)

const FROZEN_CORPUS = [
    corpus_hex("int_0", "00"),
    corpus_hex("int_1", "01"),
    corpus_hex("int_10", "0a"),
    corpus_hex("int_23", "17"),
    corpus_hex("int_24", "1818"),
    corpus_hex("int_25", "1819"),
    corpus_hex("int_100", "1864"),
    corpus_hex("int_255", "18ff"),
    corpus_hex("int_256", "190100"),
    corpus_hex("int_1000", "1903e8"),
    corpus_hex("int_65535", "19ffff"),
    corpus_hex("int_65536", "1a00010000"),
    corpus_hex("int_1000000", "1a000f4240"),
    corpus_hex("int_4294967295", "1affffffff"),
    corpus_hex("int_4294967296", "1b0000000100000000"),
    corpus_hex("int_1000000000000", "1b000000e8d4a51000"),
    corpus_hex("int_2p53", "1b0020000000000000"),
    corpus_hex("int_2p53_plus_1", "1b0020000000000001"),
    corpus_hex("int_max", "1b7fffffffffffffff"),
    corpus_hex("int_m1", "20"),
    corpus_hex("int_m10", "29"),
    corpus_hex("int_m24", "37"),
    corpus_hex("int_m25", "3818"),
    corpus_hex("int_m100", "3863"),
    corpus_hex("int_m256", "38ff"),
    corpus_hex("int_m257", "390100"),
    corpus_hex("int_m1000", "3903e7"),
    corpus_hex("int_m65537", "3a00010000"),
    corpus_hex("int_m4294967297", "3b0000000100000000"),
    corpus_hex("int_min", "3b7fffffffffffffff"),
    corpus_hex("float_0", "f90000"),
    corpus_hex("float_m0", "f98000"),
    corpus_hex("float_1", "f93c00"),
    corpus_hex("float_1_5", "f93e00"),
    corpus_hex("float_m1_5", "f9be00"),
    corpus_hex("float_2", "f94000"),
    corpus_hex("float_m4", "f9c400"),
    corpus_hex("float_m4_1", "fbc010666666666666"),
    corpus_hex("float_65504", "f97bff"),
    corpus_hex("float_65505", "fa477fe100"),
    corpus_hex("float_100000", "fa47c35000"),
    corpus_hex("float_f32_max", "fa7f7fffff"),
    corpus_hex("float_1e300", "fb7e37e43c8800759c"),
    corpus_hex("float_0_1", "fb3fb999999999999a"),
    corpus_hex("float_1_1", "fb3ff199999999999a"),
    corpus_hex("float_f16_min_subnormal", "f90001"),
    corpus_hex("float_f16_min_normal", "f90400"),
    corpus_hex("float_f16_below_min_subnormal", "fa33000000"),
    corpus_hex("float_f32_min_subnormal", "fa00000001"),
    corpus_hex("float_2p53", "fa5a000000"),
    corpus_hex("float_2p53_plus_2", "fb4340000000000001"),
    corpus_hex("float_m1e300", "fbfe37e43c8800759c"),
    corpus_hex("float_pi", "fb400921fb54442d18"),
    corpus_hex("float_inf", "f97c00"),
    corpus_hex("float_m_inf", "f9fc00"),
    corpus_hex("float_nan", "f97e00"),
    corpus_hex("float_nan_signbit", "f97e00"),
    corpus_hex("float_nan_payload", "f97e00"),
    corpus_hex("text_empty", "60"),
    corpus_hex("text_a", "6161"),
    corpus_hex("text_ietf", "6449455446"),
    corpus_hex("text_quote_backslash", "62225c"),
    corpus_hex("text_u_umlaut", "62c3bc"),
    corpus_hex("text_water", "63e6b0b4"),
    corpus_hex("text_astral", "64f0908591"),
    corpus_hex("text_nfc_e_acute", "62c3a9"),
    corpus_hex("text_nfd_e_acute", "6365cc81"),
    corpus_hex("text_23", "776161616161616161616161616161616161616161616161"),
    corpus_hex("text_24", "7818616161616161616161616161616161616161616161616161"),
    corpus_hex(
        "text_255",
        "78ff626262626262626262626262626262626262626262626262626262626262626262626262626262626262626262626262626262626262626262626262626262626262626262626262626262626262626262626262626262626262626262626262626262626262626262626262626262626262626262626262626262626262626262626262626262626262626262626262626262626262626262626262626262626262626262626262626262626262626262626262626262626262626262626262626262626262626262626262626262626262626262626262626262626262626262626262626262626262626262626262626262626262626262626262626262",
    ),
    corpus_hex(
        "text_256",
        "79010063636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363",
    ),
    corpus_hex("text_65536", "7a00010000" * "64"^65536),
    corpus_hex("bytes_empty", "40"),
    corpus_hex("bytes_01020304", "4401020304"),
    corpus_hex("bytes_23", "57000102030405060708090a0b0c0d0e0f10111213141516"),
    corpus_hex("bytes_24", "5818000102030405060708090a0b0c0d0e0f1011121314151617"),
    corpus_hex(
        "bytes_255",
        "58ff000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f404142434445464748494a4b4c4d4e4f505152535455565758595a5b5c5d5e5f606162636465666768696a6b6c6d6e6f707172737475767778797a7b7c7d7e7f808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9fa0a1a2a3a4a5a6a7a8a9aaabacadaeafb0b1b2b3b4b5b6b7b8b9babbbcbdbebfc0c1c2c3c4c5c6c7c8c9cacbcccdcecfd0d1d2d3d4d5d6d7d8d9dadbdcdddedfe0e1e2e3e4e5e6e7e8e9eaebecedeeeff0f1f2f3f4f5f6f7f8f9fafbfcfdfe",
    ),
    corpus_hex(
        "bytes_256",
        "590100000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f404142434445464748494a4b4c4d4e4f505152535455565758595a5b5c5d5e5f606162636465666768696a6b6c6d6e6f707172737475767778797a7b7c7d7e7f808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9fa0a1a2a3a4a5a6a7a8a9aaabacadaeafb0b1b2b3b4b5b6b7b8b9babbbcbdbebfc0c1c2c3c4c5c6c7c8c9cacbcccdcecfd0d1d2d3d4d5d6d7d8d9dadbdcdddedfe0e1e2e3e4e5e6e7e8e9eaebecedeeeff0f1f2f3f4f5f6f7f8f9fafbfcfdfeff",
    ),
    corpus_hex("true", "f5"),
    corpus_hex("false", "f4"),
    corpus_hex("null", "f6"),
    corpus_hex("array_empty", "80"),
    corpus_hex("array_123", "83010203"),
    corpus_hex("array_nested", "8301820203820405"),
    corpus_hex("array_25", "98190102030405060708090a0b0c0d0e0f101112131415161718181819"),
    corpus_hex("array_mixed", "8a0120f93e00616141fff5f4f680a0"),
    corpus_hex("array_of_floats", "86f90000f98000f97c00f9fc00f97e00fb7e37e43c8800759c"),
    corpus_hex("map_empty", "a0"),
    corpus_hex("map_a1_b23", "a26161016162820203"),
    corpus_hex("map_abcde", "a56161614161626142616361436164614461656145"),
    corpus_hex("map_key_order", "a6616103616204617a01626161026261620562626106"),
    corpus_hex(
        "map_key_lengths_23_24_25",
        "a3776b6b6b6b6b6b6b6b6b6b6b6b6b6b6b6b6b6b6b6b6b6b6b1778186b6b6b6b6b6b6b6b6b6b6b6b6b6b6b6b6b6b6b6b6b6b6b6b181878196b6b6b6b6b6b6b6b6b6b6b6b6b6b6b6b6b6b6b6b6b6b6b6b6b1819",
    ),
    corpus_hex("map_key_nonascii", "a5617a0262616205627a7a0362c3a90163e6b0b404"),
    corpus_hex("map_nested", "a1656f75746572a165696e6e657281a1616bf6"),
    corpus_hex(
        "record_shaped",
        "a8636f707387a3626f706c6372656174655f7461626c65657368617065a2636b65798162696467636f6c756d6e73848362696465696e743634f483617867666c6f61743634f583646e616d656474657874f48364626c6f62656279746573f5657461626c656174a3626f7066696e7365727464726f7773828401f9800062c3a541008402f6617af6657461626c656174a4626f706a6164645f636f6c756d6e6466696c6cf97e00657461626c65617466636f6c756d6e83617967666c6f61743634f4a4626f706675706461746564726f7773818201f97c00657461626c65617467636f6c756d6e73816178a3626f706664656c657465646b657973818102657461626c656174a3626f706b64726f705f636f6c756d6e657461626c65617466636f6c756d6e64626c6f62a2626f706a64726f705f7461626c65657461626c65617464736c6f740766636c69656e74a5636c696271436861696e5461626c657320302e312e3064686f737463626f786475736572636a6f6e656a756c696166312e31322e376774696d655f6d731b0000019943ce080067636f6d6d656e746c666972737420636f6d6d697468636861696e5f696450000102030405060708090a0b0c0d0e0f69707265765f686173685820202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f6e666f726d61745f76657273696f6e017173746174655f66696e6765727072696e745820000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f",
    ),
    corpus_hex(
        "table_file_shaped",
        "82a2636b65798162696467636f6c756d6e73828362696465696e743634f483617867666c6f61743634f583823b7ffffffffffffffff980008200f90000821b7ffffffffffffffff6",
    ),
]

@testset "the frozen corpus has 96 cases" begin
    @test length(FROZEN_CORPUS) == length(CORPUS_VALUES) == 96
end

@testset "encode writes the frozen corpus case $(case.name)" for case in FROZEN_CORPUS
    @test bytes2hex(CBOR.encode(CORPUS_VALUES[case.name])) == case.hex
end

@testset "decode reads the frozen corpus case $(case.name)" for case in FROZEN_CORPUS
    @test isequal(CBOR.decode(hex2bytes(case.hex)), CORPUS_VALUES[case.name])
end

# -0.0 and NaN are checked bitwise: the decoder yields the canonical NaN.
const FLOAT_CORPUS = [
    case for case in FROZEN_CORPUS if CORPUS_VALUES[case.name] isa Float64
]

@testset "decode reads the frozen float $(case.name) bitwise" for case in FLOAT_CORPUS
    value = CORPUS_VALUES[case.name]
    expected = isnan(value) ? NaN : value
    @test reinterpret(UInt64, CBOR.decode(hex2bytes(case.hex))) == reinterpret(
        UInt64, expected,
    )
end
