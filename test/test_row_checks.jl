using Test
# The table model is internal; its rules are the format's spec (ADR-0025), with reference
# values of their own, so they are tested here directly rather than through an API name.
using ChainTables: ChainTables, Column, ModelError, Shape, check_key_order, check_row,
    check_update

const SHAPE = Shape(
    [
        Column("id", "int64", false), Column("x", "float64", true),
        Column("s", "text", false), Column("b", "bytes", false),
    ], ["id"]
)

const ACCEPTED_ROWS = [
    (name = "null where nullable", row = Any[1, missing, "a", UInt8[]]),
    (name = "NaN", row = Any[1, NaN, "a", UInt8[1]]),
]

@testset "check_row accepts $(case.name)" for case in ACCEPTED_ROWS
    @test check_row(SHAPE, case.row) === nothing
end

const REFUSED_ROWS = [
    (
        name = "a short row",
        row = Any[1, 2.0, "a"],
        message = "row has 3 cells; the shape has 4 columns",
    ),
    (
        name = "null in a key",
        row = Any[missing, 1.0, "a", UInt8[]],
        message = "column \"id\" is int64 and does not admit null",
    ),
    (
        name = "a Float64 int",
        row = Any[1.0, 1.0, "a", UInt8[]],
        message = "column \"id\" is int64, got a value of type Float64",
    ),
    (
        name = "an Int32",
        row = Any[Int32(1), 1.0, "a", UInt8[]],
        message = "column \"id\" is int64, got a value of type Int32",
    ),
    (
        name = "a Bool",
        row = Any[true, 1.0, "a", UInt8[]],
        message = "column \"id\" is int64, got a value of type Bool",
    ),
    (
        name = "an Int64 float",
        row = Any[1, 1, "a", UInt8[]],
        message = "column \"x\" is float64, got a value of type Int64",
    ),
    (
        name = "a SubString",
        row = Any[1, 1.0, SubString("ab", 1, 1), UInt8[]],
        message = "column \"s\" is text, got a value of type SubString{String}",
    ),
    (
        name = "text as bytes",
        row = Any[1, 1.0, "a", "b"],
        message = "column \"b\" is bytes, got a value of type String",
    ),
]

@testset "check_row refuses $(case.name)" for case in REFUSED_ROWS
    @test_throws ModelError case.message check_row(SHAPE, case.row)
end

const ORDERED_KEYS = [
    (name = "bytes", keys = [(UInt8[1],), (UInt8[2],)]),
    (name = "none", keys = ()),
    (name = "one", keys = [(1,)]),
]

@testset "check_key_order accepts $(case.name)" for case in ORDERED_KEYS
    @test check_key_order(case.keys) === nothing
end

@testset "check_key_order refuses keys out of order" begin
    @test_throws(
        ModelError,
        "rows are not in primary-key order: (UInt8[0x01],) after " *
            "(UInt8[0x02],)",
        check_key_order([(UInt8[2],), (UInt8[1],)]),
    )
end

@testset "check_key_order names a duplicate with its context" begin
    @test_throws(
        ModelError, "duplicate key (UInt8[0x01],) inside one op",
        check_key_order([(UInt8[1],), (UInt8[1],)]),
    )
    @test_throws(
        ModelError, "duplicate key (1,) in a table file",
        check_key_order([(1,), (1,)]; context = "in a table file"),
    )
end

@testset "check_update returns the declaration positions of the columns" begin
    s = Shape(
        [
            Column("id", "int64", false), Column("v", "text", true),
            Column("w", "float64", false), Column("n", "int64", true),
        ],
        ["id"],
    )
    @test check_update(s, ["w", "n"], [Any[1, 3.0, 3]]) == [3, 4]
end
