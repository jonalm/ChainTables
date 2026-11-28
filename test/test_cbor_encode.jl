using Test
using ChainTables: CBOR

include("fixtures/cbor_corpus.jl")
include("fixtures/cbor_hand_written.jl")

const SIGNBIT_NAN = reinterpret(Float64, 0xfff8000000000000)
const PAYLOAD_NAN = reinterpret(Float64, 0x7ff8000000000001)

const ENCODED_NUMBERS = [
    (name = "-0.0 survives float shortening", value = -0.0, hex = "f98000"),
    (name = "0.0", value = 0.0, hex = "f90000"),
    (name = "NaN", value = NaN, hex = "f97e00"),
    (name = "a NaN with its sign bit set", value = SIGNBIT_NAN, hex = "f97e00"),
    (name = "a NaN with a payload", value = PAYLOAD_NAN, hex = "f97e00"),
    (name = "a Float32 NaN", value = NaN32, hex = "f97e00"),
    (name = "Inf", value = Inf, hex = "f97c00"),
    (name = "-Inf", value = -Inf, hex = "f9fc00"),
    (name = "a float64 2.0 stays a float", value = 2.0, hex = "f94000"),
    (name = "an integer 2", value = 2, hex = "02"),
    (name = "an integer above 2^53 is exact", value = 2^53 + 1, hex = "1b0020000000000001"),
    (name = "the largest int64", value = typemax(Int64), hex = "1b7fffffffffffffff"),
    (name = "the smallest int64", value = typemin(Int64), hex = "3b7fffffffffffffff"),
    (name = "1.1 needs float64", value = 1.1, hex = "fb3ff199999999999a"),
    (name = "100000.0 fits float32", value = 100000.0, hex = "fa47c35000"),
    (name = "the smallest float16 subnormal", value = 5.960464477539063e-8, hex = "f90001"),
    (name = "an Int32 widens", value = Int32(5), hex = "05"),
    (name = "an Int8 widens", value = Int8(-1), hex = "20"),
    (name = "a Float32 widens", value = Float32(1.5), hex = "f93e00"),
    (name = "true", value = true, hex = "f5"),
    (name = "false", value = false, hex = "f4"),
    (name = "missing is null", value = missing, hex = "f6"),
]

const ENCODED_CONTAINERS = [
    (name = "an empty array", value = Any[], hex = "80"),
    (name = "a tuple is an array", value = (1, "a", missing), hex = "83016161f6"),
    (name = "an empty map", value = Dict{String, Any}(), hex = "a0"),
    (name = "a NamedTuple is a map", value = (b = 2, a = 1), hex = "a2616101616202"),
    (
        name = "map keys sort by length first",
        value = Dict("z" => 1, "aa" => 2, "a" => 3), hex = "a3616103617a0162616102",
    ),
    (name = "a Vector{UInt8} is bytes", value = UInt8[1, 2], hex = "420102"),
    (name = "other vectors of bytes are arrays", value = Any[0x01, 0x02], hex = "820102"),
    (name = "an NFC é", value = "é", hex = "62c3a9"),
    (name = "an NFD é is another value", value = "é", hex = "6365cc81"),
    (name = "a SubString is text", value = SubString("xyz", 2), hex = "62797a"),
]

const ENCODE_REFUSALS = [
    (name = "a UInt64 above int64", value = UInt64(2)^63, fragment = "outside the int64"),
    (name = "a BigInt above int64", value = big(2)^64, fragment = "outside the int64"),
    (
        name = "a float that is not a Float64", value = big"0.1",
        fragment = "not exactly representable as Float64",
    ),
    (name = "nothing", value = nothing, fragment = "null is spelled missing"),
    (
        name = "a type the format cannot carry", value = 1 // 2,
        fragment = "cannot encode a value of type Rational",
    ),
    (name = "a key that is not text", value = Dict(1 => 2), fragment = "map keys are text"),
    (
        name = "text that is not UTF-8", value = String(UInt8[0xc3, 0x28]),
        fragment = "not well-formed UTF-8",
    ),
    (name = "text holding U+0000", value = "a\0b", fragment = "U+0000"),
    (
        name = "one map key spelt as text and as a Symbol",
        value = Dict{Any, Any}("a" => 1, :a => 2), fragment = "duplicate map key \"a\"",
    ),
]

@testset "encode writes the hand-written record fixture" begin
    @test @inferred(CBOR.encode(HAND_WRITTEN_RECORD)) == hex2bytes(HAND_WRITTEN_HEX)
end

@testset "encode to an IO writes the same bytes and returns their count" begin
    io = IOBuffer()
    @test @inferred(CBOR.encode(io, HAND_WRITTEN_RECORD)) == length(HAND_WRITTEN_HEX) ÷ 2
    @test bytes2hex(take!(io)) == HAND_WRITTEN_HEX
end

@testset "encode writes numbers, bools and null" begin
    @testset "$(case.name)" for case in ENCODED_NUMBERS
        @test bytes2hex(CBOR.encode(case.value)) == case.hex
    end
end

@testset "encode writes containers and text" begin
    @testset "$(case.name)" for case in ENCODED_CONTAINERS
        @test bytes2hex(CBOR.encode(case.value)) == case.hex
    end
end

@testset "encode refuses what the format cannot carry" begin
    @testset "$(case.name)" for case in ENCODE_REFUSALS
        @test_throws ArgumentError case.fragment CBOR.encode(case.value)
    end
end

@testset "encode matches the frozen conformance corpus" begin
    @test length(CBOR_CORPUS) == 96
    @testset "$name" for (name, value) in CBOR_CORPUS
        @test bytes2hex(CBOR.encode(value)) == CBOR_FROZEN_HEX[name]
    end
end

@testset "write_array_header streams an array row by row" begin
    shape = Dict{String, Any}("key" => Any["id"])
    rows = Any[Any[1], Any[2], Any[3]]
    io = IOBuffer()
    n = @inferred(CBOR.write_array_header(io, 2)) + CBOR.encode(io, shape)
    n += CBOR.write_array_header(io, length(rows)) + sum(row -> CBOR.encode(io, row), rows)
    bytes = take!(io)
    @test n == length(bytes)
    @test bytes == CBOR.encode(Any[shape, rows])
end

@testset "write_array_header refuses a negative count" begin
    @test_throws ArgumentError "cannot be negative" CBOR.write_array_header(IOBuffer(), -1)
end
