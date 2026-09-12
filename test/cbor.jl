# #34 step 1 — ADR-0006, ADR-0022: hand-written fixture, -0.0, NaN/±Inf, rejecting decoder, NFC/NFD, conformance corpus.
using ChainTables: CBOR

@testset "cbor" begin
    # ------------------------------------------------------------------------
    # A hand-written fixture (ADR-0006 "Required named test"): a record-shaped
    # map whose bytes are written out by hand from RFC 8949 Appendix A and the
    # §4.2.1 key order (bytewise on the *encoded* key, so "ops" < "slot" <
    # "client": the header byte 0x60+len sorts before the text). The one check
    # against the standard rather than against the encoder itself.
    # ------------------------------------------------------------------------
    @testset "hand-written fixture" begin
        fixture = Dict{String,Any}(
            "format_version" => 1,
            "chain_id" => UInt8.(0:15),
            "slot" => 0,
            "state_fingerprint" => UInt8.(0:31),
            "client" => Dict{String,Any}("host" => "h", "user" => "u", "lib" => "ChainTables 0.1.0",
                                         "julia" => "1.12.7", "time_ms" => 1000),
            "comment" => "ü",
            "ops" => Any[Dict{String,Any}("op" => "insert", "table" => "t",
                                          "rows" => Any[Any[1, -0.0, "水", UInt8[1, 2, 3, 4], true, missing, -1, 1.1, 100000.0]])],
        )
        hex = join([
            "a7",                                              # map(7)
            "63 6f7073",                                       #   "ops"
            "81",                                              #     array(1)
            "a3",                                              #       map(3)
            "62 6f70", "66 696e73657274",                      #         "op": "insert"
            "64 726f7773",                                     #         "rows"
            "81", "89",                                        #           [[ 9 cells ]]
            "01",                                              #             1            (App. A)
            "f9 8000",                                         #             -0.0         (App. A)
            "63 e6b0b4",                                       #             "水"         (App. A)
            "44 01020304",                                     #             h'01020304'  (App. A)
            "f5", "f6",                                        #             true, null   (App. A)
            "20",                                              #             -1           (App. A)
            "fb 3ff199999999999a",                             #             1.1          (App. A)
            "fa 47c35000",                                     #             100000.0     (App. A)
            "65 7461626c65", "61 74",                          #         "table": "t"
            "64 736c6f74", "00",                               #   "slot": 0
            "66 636c69656e74",                                 #   "client"
            "a5",                                              #     map(5)
            "63 6c6962", "71 436861696e5461626c657320302e312e30",  # "lib": "ChainTables 0.1.0"
            "64 686f7374", "61 68",                            #     "host": "h"
            "64 75736572", "61 75",                            #     "user": "u"
            "65 6a756c6961", "66 312e31322e37",                #     "julia": "1.12.7"
            "67 74696d655f6d73", "19 03e8",                    #     "time_ms": 1000 (App. A)
            "67 636f6d6d656e74", "62 c3bc",                    #   "comment": "ü"  (App. A)
            "68 636861696e5f6964", "50 000102030405060708090a0b0c0d0e0f",  # "chain_id": 16 bytes
            "6e 666f726d61745f76657273696f6e", "01",           #   "format_version": 1
            "71 73746174655f66696e6765727072696e74",           #   "state_fingerprint"
            "5820 000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f",
        ])
        hex = replace(hex, " " => "")
        @test bytes2hex(CBOR.encode(fixture)) == hex
        @test isequal(CBOR.decode(hex2bytes(hex)), fixture)
        # the streaming form writes the same bytes
        io = IOBuffer()
        @test CBOR.encode(io, fixture) == length(hex) ÷ 2
        @test bytes2hex(take!(io)) == hex
    end

    # ------------------------------------------------------------------------
    # Floats and integers (ADR-0006 profile, ADR-0025 float64 domain)
    # ------------------------------------------------------------------------
    @testset "-0.0 survives float shortening" begin
        @test bytes2hex(CBOR.encode(-0.0)) == "f98000"
        @test bytes2hex(CBOR.encode(0.0)) == "f90000"
        @test CBOR.decode(hex2bytes("f98000")) === -0.0
        @test CBOR.decode(hex2bytes("f90000")) === 0.0
    end

    @testset "NaN canonicalised to f97e00; ±Inf encoded" begin
        @test bytes2hex(CBOR.encode(NaN)) == "f97e00"
        signbit_nan = reinterpret(Float64, 0xfff8000000000000)
        @test signbit(signbit_nan) && isnan(signbit_nan)
        @test bytes2hex(CBOR.encode(signbit_nan)) == "f97e00"
        payload_nan = reinterpret(Float64, 0x7ff8000000000001)
        @test bytes2hex(CBOR.encode(payload_nan)) == "f97e00"
        @test bytes2hex(CBOR.encode(NaN32)) == "f97e00"
        nan = CBOR.decode(hex2bytes("f97e00"))
        @test nan isa Float64 && isnan(nan)
        @test reinterpret(UInt64, nan) == 0x7ff8000000000000
        @test bytes2hex(CBOR.encode(Inf)) == "f97c00"
        @test bytes2hex(CBOR.encode(-Inf)) == "f9fc00"
        @test CBOR.decode(hex2bytes("f97c00")) === Inf
        @test CBOR.decode(hex2bytes("f9fc00")) === -Inf
    end

    @testset "float64 2.0 stays a float; ints above 2^53 exact; int64 at 2^63-1" begin
        @test bytes2hex(CBOR.encode(2.0)) == "f94000"
        @test CBOR.decode(hex2bytes("f94000")) === 2.0
        @test bytes2hex(CBOR.encode(2)) == "02"
        @test CBOR.decode(hex2bytes("02")) === Int64(2)
        @test bytes2hex(CBOR.encode(2^53 + 1)) == "1b0020000000000001"
        @test CBOR.decode(hex2bytes("1b0020000000000001")) === 9007199254740993
        @test bytes2hex(CBOR.encode(typemax(Int64))) == "1b7fffffffffffffff"
        @test CBOR.decode(hex2bytes("1b7fffffffffffffff")) === typemax(Int64)
        @test bytes2hex(CBOR.encode(typemin(Int64))) == "3b7fffffffffffffff"
        @test CBOR.decode(hex2bytes("3b7fffffffffffffff")) === typemin(Int64)
        # preferred float representation picks the shortest exact form
        @test bytes2hex(CBOR.encode(1.1)) == "fb3ff199999999999a"
        @test bytes2hex(CBOR.encode(100000.0)) == "fa47c35000"
        @test bytes2hex(CBOR.encode(5.960464477539063e-8)) == "f90001"   # smallest float16 subnormal
        @test CBOR.decode(hex2bytes("fb3ff199999999999a")) === 1.1
    end

    @testset "widening and refusals on the encoder side" begin
        @test bytes2hex(CBOR.encode(Int32(5))) == "05"
        @test bytes2hex(CBOR.encode(Int8(-1))) == "20"
        @test bytes2hex(CBOR.encode(Float32(1.5))) == "f93e00"
        @test bytes2hex(CBOR.encode(true)) == "f5"
        @test bytes2hex(CBOR.encode(false)) == "f4"
        @test bytes2hex(CBOR.encode(missing)) == "f6"
        @test_throws "outside the int64 domain" CBOR.encode(UInt64(2)^63)
        @test_throws "outside the int64 domain" CBOR.encode(big(2)^64)
        @test_throws "not exactly representable as Float64" CBOR.encode(big"0.1")
        @test_throws "null is spelled missing" CBOR.encode(nothing)
        @test_throws "cannot encode a value of type Rational" CBOR.encode(1 // 2)
        @test_throws "map keys are text" CBOR.encode(Dict(1 => 2))
    end

    @testset "containers: arrays, tuples, maps, streaming" begin
        @test bytes2hex(CBOR.encode(Any[])) == "80"
        @test bytes2hex(CBOR.encode((1, "a", missing))) == "83016161f6"
        @test bytes2hex(CBOR.encode(Dict{String,Any}())) == "a0"
        @test bytes2hex(CBOR.encode((b = 2, a = 1))) == "a2616101616202"
        @test bytes2hex(CBOR.encode(Dict("z" => 1, "aa" => 2, "a" => 3))) == "a3616103617a0162616102"
        # a Vector{UInt8} is bytes, a vector of integers that is not UInt8-typed is an array
        @test bytes2hex(CBOR.encode(UInt8[1, 2])) == "420102"
        @test bytes2hex(CBOR.encode(Any[0x01, 0x02])) == "820102"
        # streaming a table-file-shaped [shape, rows] row by row gives the same bytes
        shape = Dict{String,Any}("columns" => Any[Any["id", "int64", false]], "key" => Any["id"])
        rows = Any[Any[1], Any[2], Any[3]]
        io = IOBuffer()
        n = CBOR.write_array_header(io, 2) + CBOR.encode(io, shape) + CBOR.write_array_header(io, length(rows))
        for row in rows
            n += CBOR.encode(io, row)
        end
        bytes = take!(io)
        @test n == length(bytes)
        @test bytes == CBOR.encode(Any[shape, rows])
        io = IOBuffer(bytes)
        @test CBOR.read_array_header(io) == 2
        @test isequal(CBOR.decode(io), shape)
        @test CBOR.read_array_header(io) == 3
        @test [CBOR.decode(io) for _ in 1:3] == rows
        @test eof(io)
        @test_throws "expected an array head" CBOR.read_array_header(IOBuffer(hex2bytes("a0")))
    end

    # ------------------------------------------------------------------------
    # Text (ADR-0006: no normalization; ADR-0025: well-formed UTF-8, no U+0000)
    # ------------------------------------------------------------------------
    @testset "NFC and NFD are different values; invalid UTF-8 and U+0000 refused" begin
        nfc = "é"
        nfd = "é"
        @test bytes2hex(CBOR.encode(nfc)) == "62c3a9"
        @test bytes2hex(CBOR.encode(nfd)) == "6365cc81"
        @test CBOR.decode(CBOR.encode(nfc)) == nfc
        @test CBOR.decode(CBOR.encode(nfd)) == nfd
        @test CBOR.decode(CBOR.encode(nfc)) != CBOR.decode(CBOR.encode(nfd))
        bad = String(UInt8[0xc3, 0x28])
        @test_throws "not well-formed UTF-8" CBOR.encode(bad)
        @test_throws "not well-formed UTF-8" CBOR.decode(hex2bytes("62c328"))
        @test_throws "U+0000" CBOR.encode("a\0b")
        @test_throws "U+0000" CBOR.decode(hex2bytes("63610062"))
        @test CBOR.decode(CBOR.encode(SubString("xyz", 2))) == "yz"
    end

    # ------------------------------------------------------------------------
    # The rejecting decoder (ADR-0006: canonicality is unenforceable without one)
    # ------------------------------------------------------------------------
    @testset "rejecting decoder" begin
        rejects(hex, msg) = @test_throws msg CBOR.decode(hex2bytes(replace(hex, " " => "")))
        rejects("a2 6161 01 6161 02", "duplicate map key \"a\"")
        rejects("a2 6162 01 6161 02", "not in RFC 8949 §4.2.1 order")
        rejects("a2 626161 01 617a 02", "not in RFC 8949 §4.2.1 order")   # length-first: "z" < "aa"
        rejects("a1 01 01", "map key must be text")
        rejects("9f 01 ff", "indefinite length")
        rejects("bf ff", "indefinite length")
        rejects("5f ff", "indefinite length")
        rejects("7f ff", "indefinite length")
        rejects("ff", "unexpected break")
        rejects("c0 6161", "tag 0; tags are not in the format")
        rejects("d8 20 6161", "tag 32; tags are not in the format")
        rejects("18 05", "not in its shortest form")
        rejects("19 00ff", "not in its shortest form")
        rejects("1a 0000ffff", "not in its shortest form")
        rejects("1b 00000000ffffffff", "not in its shortest form")
        rejects("38 00", "not in its shortest form")
        rejects("58 03 010203", "not in its shortest form")   # a length is a head argument too
        rejects("fb 3ff0000000000000", "not in its shortest form")   # 1.0 as float64
        rejects("fa 3f800000", "not in its shortest form")           # 1.0 as float32
        rejects("fb 47c3500000000000", "not in its shortest form")   # 100000.0 as float64
        rejects("fa 7f800000", "not in its shortest form")           # Inf as float32
        rejects("f9 7e01", "NaN must be encoded as f97e00")
        rejects("f9 fe00", "NaN must be encoded as f97e00")          # sign-bit-set NaN
        rejects("fa 7fc00000", "NaN must be encoded as f97e00")
        rejects("fb 7ff8000000000000", "NaN must be encoded as f97e00")
        rejects("f7", "simple value undefined")
        rejects("f8 20", "simple value 32")
        rejects("e0", "simple value 0")
        rejects("1c", "reserved additional information 28")
        rejects("1b 8000000000000000", "exceeds the int64 domain")
        rejects("3b 8000000000000000", "below the int64 domain")
        rejects("01 01", "trailing bytes")
        rejects("19 03", "truncated input")
        rejects("82 01", "truncated input")
        rejects("63 6162", "truncated input")
        rejects("", "truncated input")
        rejects("5a 04000001", "exceeds the 64 MiB record cap")
        rejects("81"^65 * "00", "nesting deeper than 64 levels")
        @test CBOR.decode(hex2bytes("81"^64 * "00")) isa Vector{Any}
        # the offset names the byte the violation was found at
        e = try CBOR.decode(hex2bytes("8201f7")); nothing catch e; e end
        @test e isa CBOR.DecodeError && e.offset == 2
        @test sprint(showerror, e) == "CBOR decode error at byte 2: simple value undefined (0xf7) is not in the format"
    end

    # ------------------------------------------------------------------------
    # Frozen conformance corpus (ADR-0006). The hex literals were produced once
    # by a three-way differential run — this encoder, cbor2 6.1.4 with
    # canonical=True, and fxamacker/cbor v2.9.3 with CoreDetEncOptions() — on
    # 2026-09-13 and agreed byte for byte; see test/conformance/README.md. They
    # are frozen: a change here is a chain break and needs an ADR.
    # ------------------------------------------------------------------------
    @testset "frozen conformance corpus" begin
    corpus = [
        # integers: every head width boundary, both signs, the int64 ends
        "int_0" => 0, "int_1" => 1, "int_10" => 10, "int_23" => 23, "int_24" => 24, "int_25" => 25,
        "int_100" => 100, "int_255" => 255, "int_256" => 256, "int_1000" => 1000,
        "int_65535" => 65535, "int_65536" => 65536, "int_1000000" => 1000000,
        "int_4294967295" => 4294967295, "int_4294967296" => 4294967296,
        "int_1000000000000" => 1000000000000, "int_2p53" => 2^53, "int_2p53_plus_1" => 2^53 + 1,
        "int_max" => typemax(Int64),
        "int_m1" => -1, "int_m10" => -10, "int_m24" => -24, "int_m25" => -25, "int_m100" => -100,
        "int_m256" => -256, "int_m257" => -257, "int_m1000" => -1000, "int_m65537" => -65537,
        "int_m4294967297" => -4294967297, "int_min" => typemin(Int64),
        # floats: shortening at every width, the sign of zero, subnormals, infinities, NaN
        "float_0" => 0.0, "float_m0" => -0.0, "float_1" => 1.0, "float_1_5" => 1.5, "float_m1_5" => -1.5,
        "float_2" => 2.0, "float_m4" => -4.0, "float_m4_1" => -4.1, "float_65504" => 65504.0,
        "float_65505" => 65505.0, "float_100000" => 100000.0, "float_f32_max" => 3.4028234663852886e38,
        "float_1e300" => 1.0e300, "float_0_1" => 0.1, "float_1_1" => 1.1,
        "float_f16_min_subnormal" => 5.960464477539063e-8, "float_f16_min_normal" => 6.103515625e-5,
        "float_f16_below_min_subnormal" => 2.9802322387695312e-8, "float_f32_min_subnormal" => 1.401298464324817e-45,
        "float_2p53" => 9007199254740992.0, "float_2p53_plus_2" => 9007199254740994.0,
        "float_m1e300" => -1.0e300, "float_pi" => 3.141592653589793,
        "float_inf" => Inf, "float_m_inf" => -Inf, "float_nan" => NaN,
        "float_nan_signbit" => reinterpret(Float64, 0xfff8000000000000),
        "float_nan_payload" => reinterpret(Float64, 0x7ff8000000000001),
        # text: length boundaries, non-ASCII, NFC vs NFD, astral plane
        "text_empty" => "", "text_a" => "a", "text_ietf" => "IETF", "text_quote_backslash" => "\"\\",
        "text_u_umlaut" => "ü", "text_water" => "水", "text_astral" => "𐅑",
        "text_nfc_e_acute" => "é", "text_nfd_e_acute" => "é",
        "text_23" => "a"^23, "text_24" => "a"^24, "text_255" => "b"^255, "text_256" => "c"^256,
        "text_65536" => "d"^65536,
        # bytes: length boundaries
        "bytes_empty" => UInt8[], "bytes_01020304" => UInt8[1, 2, 3, 4], "bytes_23" => UInt8.(0:22),
        "bytes_24" => UInt8.(0:23), "bytes_255" => UInt8.(0:254), "bytes_256" => UInt8.(0:255),
        # bool, null
        "true" => true, "false" => false, "null" => missing,
        # arrays
        "array_empty" => Any[], "array_123" => Any[1, 2, 3], "array_nested" => Any[1, Any[2, 3], Any[4, 5]],
        "array_25" => Any[1:25...], "array_mixed" => Any[1, -1, 1.5, "a", UInt8[0xff], true, false, missing, Any[], Dict{String,Any}()],
        "array_of_floats" => Any[0.0, -0.0, Inf, -Inf, NaN, 1.0e300],
        # maps: the §4.2.1 key order (bytewise on the encoded key), length boundaries in keys
        "map_empty" => Dict{String,Any}(),
        "map_a1_b23" => Dict{String,Any}("a" => 1, "b" => Any[2, 3]),
        "map_abcde" => Dict{String,Any}("a" => "A", "b" => "B", "c" => "C", "d" => "D", "e" => "E"),
        "map_key_order" => Dict{String,Any}("z" => 1, "aa" => 2, "a" => 3, "b" => 4, "ab" => 5, "ba" => 6),
        "map_key_lengths_23_24_25" => Dict{String,Any}("k"^25 => 25, "k"^23 => 23, "k"^24 => 24),
        "map_key_nonascii" => Dict{String,Any}("é" => 1, "z" => 2, "zz" => 3, "水" => 4, "ab" => 5),
        "map_nested" => Dict{String,Any}("outer" => Dict{String,Any}("inner" => Any[Dict{String,Any}("k" => missing)])),
        # a record-shaped and a table-file-shaped value (ADR-0006, ADR-0025)
        "record_shaped" => Dict{String,Any}(
            "format_version" => 1, "chain_id" => UInt8.(0:15), "slot" => 7, "prev_hash" => UInt8.(32:63),
            "state_fingerprint" => UInt8.(0:31),
            "client" => Dict{String,Any}("host" => "box", "user" => "jon", "lib" => "ChainTables 0.1.0", "julia" => "1.12.7", "time_ms" => 1757779200000),
            "comment" => "first commit",
            "ops" => Any[
                Dict{String,Any}("op" => "create_table", "table" => "t",
                    "shape" => Dict{String,Any}("columns" => Any[Any["id", "int64", false], Any["x", "float64", true], Any["name", "text", false], Any["blob", "bytes", true]], "key" => Any["id"])),
                Dict{String,Any}("op" => "insert", "table" => "t", "rows" => Any[Any[1, -0.0, "å", UInt8[0]], Any[2, missing, "z", missing]]),
                Dict{String,Any}("op" => "add_column", "table" => "t", "column" => Any["y", "float64", false], "fill" => NaN),
                Dict{String,Any}("op" => "update", "table" => "t", "columns" => Any["x"], "rows" => Any[Any[1, Inf]]),
                Dict{String,Any}("op" => "delete", "table" => "t", "keys" => Any[Any[2]]),
                Dict{String,Any}("op" => "drop_column", "table" => "t", "column" => "blob"),
                Dict{String,Any}("op" => "drop_table", "table" => "t"),
            ]),
        "table_file_shaped" => Any[
            Dict{String,Any}("columns" => Any[Any["id", "int64", false], Any["x", "float64", true]], "key" => Any["id"]),
            Any[Any[typemin(Int64), -0.0], Any[0, 0.0], Any[typemax(Int64), missing]]],
    ]
    frozen = Dict(
        "int_0" => "00",
        "int_1" => "01",
        "int_10" => "0a",
        "int_23" => "17",
        "int_24" => "1818",
        "int_25" => "1819",
        "int_100" => "1864",
        "int_255" => "18ff",
        "int_256" => "190100",
        "int_1000" => "1903e8",
        "int_65535" => "19ffff",
        "int_65536" => "1a00010000",
        "int_1000000" => "1a000f4240",
        "int_4294967295" => "1affffffff",
        "int_4294967296" => "1b0000000100000000",
        "int_1000000000000" => "1b000000e8d4a51000",
        "int_2p53" => "1b0020000000000000",
        "int_2p53_plus_1" => "1b0020000000000001",
        "int_max" => "1b7fffffffffffffff",
        "int_m1" => "20",
        "int_m10" => "29",
        "int_m24" => "37",
        "int_m25" => "3818",
        "int_m100" => "3863",
        "int_m256" => "38ff",
        "int_m257" => "390100",
        "int_m1000" => "3903e7",
        "int_m65537" => "3a00010000",
        "int_m4294967297" => "3b0000000100000000",
        "int_min" => "3b7fffffffffffffff",
        "float_0" => "f90000",
        "float_m0" => "f98000",
        "float_1" => "f93c00",
        "float_1_5" => "f93e00",
        "float_m1_5" => "f9be00",
        "float_2" => "f94000",
        "float_m4" => "f9c400",
        "float_m4_1" => "fbc010666666666666",
        "float_65504" => "f97bff",
        "float_65505" => "fa477fe100",
        "float_100000" => "fa47c35000",
        "float_f32_max" => "fa7f7fffff",
        "float_1e300" => "fb7e37e43c8800759c",
        "float_0_1" => "fb3fb999999999999a",
        "float_1_1" => "fb3ff199999999999a",
        "float_f16_min_subnormal" => "f90001",
        "float_f16_min_normal" => "f90400",
        "float_f16_below_min_subnormal" => "fa33000000",
        "float_f32_min_subnormal" => "fa00000001",
        "float_2p53" => "fa5a000000",
        "float_2p53_plus_2" => "fb4340000000000001",
        "float_m1e300" => "fbfe37e43c8800759c",
        "float_pi" => "fb400921fb54442d18",
        "float_inf" => "f97c00",
        "float_m_inf" => "f9fc00",
        "float_nan" => "f97e00",
        "float_nan_signbit" => "f97e00",
        "float_nan_payload" => "f97e00",
        "text_empty" => "60",
        "text_a" => "6161",
        "text_ietf" => "6449455446",
        "text_quote_backslash" => "62225c",
        "text_u_umlaut" => "62c3bc",
        "text_water" => "63e6b0b4",
        "text_astral" => "64f0908591",
        "text_nfc_e_acute" => "62c3a9",
        "text_nfd_e_acute" => "6365cc81",
        "text_23" => "776161616161616161616161616161616161616161616161",
        "text_24" => "7818616161616161616161616161616161616161616161616161",
        "text_255" => "78ff626262626262626262626262626262626262626262626262626262626262626262626262626262626262626262626262626262626262626262626262626262626262626262626262626262626262626262626262626262626262626262626262626262626262626262626262626262626262626262626262626262626262626262626262626262626262626262626262626262626262626262626262626262626262626262626262626262626262626262626262626262626262626262626262626262626262626262626262626262626262626262626262626262626262626262626262626262626262626262626262626262626262626262626262626262",
        "text_256" => "79010063636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363",
        "text_65536" => "7a00010000" * "64"^65536,
        "bytes_empty" => "40",
        "bytes_01020304" => "4401020304",
        "bytes_23" => "57000102030405060708090a0b0c0d0e0f10111213141516",
        "bytes_24" => "5818000102030405060708090a0b0c0d0e0f1011121314151617",
        "bytes_255" => "58ff000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f404142434445464748494a4b4c4d4e4f505152535455565758595a5b5c5d5e5f606162636465666768696a6b6c6d6e6f707172737475767778797a7b7c7d7e7f808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9fa0a1a2a3a4a5a6a7a8a9aaabacadaeafb0b1b2b3b4b5b6b7b8b9babbbcbdbebfc0c1c2c3c4c5c6c7c8c9cacbcccdcecfd0d1d2d3d4d5d6d7d8d9dadbdcdddedfe0e1e2e3e4e5e6e7e8e9eaebecedeeeff0f1f2f3f4f5f6f7f8f9fafbfcfdfe",
        "bytes_256" => "590100000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f404142434445464748494a4b4c4d4e4f505152535455565758595a5b5c5d5e5f606162636465666768696a6b6c6d6e6f707172737475767778797a7b7c7d7e7f808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9fa0a1a2a3a4a5a6a7a8a9aaabacadaeafb0b1b2b3b4b5b6b7b8b9babbbcbdbebfc0c1c2c3c4c5c6c7c8c9cacbcccdcecfd0d1d2d3d4d5d6d7d8d9dadbdcdddedfe0e1e2e3e4e5e6e7e8e9eaebecedeeeff0f1f2f3f4f5f6f7f8f9fafbfcfdfeff",
        "true" => "f5",
        "false" => "f4",
        "null" => "f6",
        "array_empty" => "80",
        "array_123" => "83010203",
        "array_nested" => "8301820203820405",
        "array_25" => "98190102030405060708090a0b0c0d0e0f101112131415161718181819",
        "array_mixed" => "8a0120f93e00616141fff5f4f680a0",
        "array_of_floats" => "86f90000f98000f97c00f9fc00f97e00fb7e37e43c8800759c",
        "map_empty" => "a0",
        "map_a1_b23" => "a26161016162820203",
        "map_abcde" => "a56161614161626142616361436164614461656145",
        "map_key_order" => "a6616103616204617a01626161026261620562626106",
        "map_key_lengths_23_24_25" => "a3776b6b6b6b6b6b6b6b6b6b6b6b6b6b6b6b6b6b6b6b6b6b6b1778186b6b6b6b6b6b6b6b6b6b6b6b6b6b6b6b6b6b6b6b6b6b6b6b181878196b6b6b6b6b6b6b6b6b6b6b6b6b6b6b6b6b6b6b6b6b6b6b6b6b1819",
        "map_key_nonascii" => "a5617a0262616205627a7a0362c3a90163e6b0b404",
        "map_nested" => "a1656f75746572a165696e6e657281a1616bf6",
        "record_shaped" => "a8636f707387a3626f706c6372656174655f7461626c65657368617065a2636b65798162696467636f6c756d6e73848362696465696e743634f483617867666c6f61743634f583646e616d656474657874f48364626c6f62656279746573f5657461626c656174a3626f7066696e7365727464726f7773828401f9800062c3a541008402f6617af6657461626c656174a4626f706a6164645f636f6c756d6e6466696c6cf97e00657461626c65617466636f6c756d6e83617967666c6f61743634f4a4626f706675706461746564726f7773818201f97c00657461626c65617467636f6c756d6e73816178a3626f706664656c657465646b657973818102657461626c656174a3626f706b64726f705f636f6c756d6e657461626c65617466636f6c756d6e64626c6f62a2626f706a64726f705f7461626c65657461626c65617464736c6f740766636c69656e74a5636c696271436861696e5461626c657320302e312e3064686f737463626f786475736572636a6f6e656a756c696166312e31322e376774696d655f6d731b0000019943ce080067636f6d6d656e746c666972737420636f6d6d697468636861696e5f696450000102030405060708090a0b0c0d0e0f69707265765f686173685820202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f6e666f726d61745f76657273696f6e017173746174655f66696e6765727072696e745820000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f",
        "table_file_shaped" => "82a2636b65798162696467636f6c756d6e73828362696465696e743634f483617867666c6f61743634f583823b7ffffffffffffffff980008200f90000821b7ffffffffffffffff6",
    )
    @test length(corpus) == length(frozen) == 96
    for (name, value) in corpus
        hex = frozen[name]
        @test bytes2hex(CBOR.encode(value)) == hex
        decoded = CBOR.decode(hex2bytes(hex))
        @test isequal(decoded, value)
        # -0.0 and NaN are checked bitwise: the decoder yields the canonical NaN
        if value isa Float64
            expected = isnan(value) ? NaN : value
            @test reinterpret(UInt64, decoded) == reinterpret(UInt64, expected)
        end
    end
    end
end
