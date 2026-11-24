using Test
using ChainTables: Model
# The model's rules are the format's spec. The write builder and apply report them
# through two public errors, so they are tested once here, where they live.
using ChainTables.Model: Column, ModelError, Shape

include("fixtures/internal_errors.jl")

const TYPED = Shape(
    [
        Column("id", "int64", false), Column("x", "float64", true),
        Column("s", "text", false), Column("b", "bytes", false),
    ], ["id"]
)

const ROW_REFUSALS = [
    (row = Any[1, 2.0, "a"], fragment = "row has 3 cells; the shape has 4 columns"),
    (
        row = Any[missing, 1.0, "a", UInt8[]],
        fragment = "column \"id\" is int64 and does not admit null",
    ),
    (
        row = Any[1.0, 1.0, "a", UInt8[]],
        fragment = "column \"id\" is int64, got a value of type Float64",
    ),
    (
        row = Any[Int32(1), 1.0, "a", UInt8[]],
        fragment = "column \"id\" is int64, got a value of type Int32",
    ),
    (
        row = Any[true, 1.0, "a", UInt8[]],
        fragment = "column \"id\" is int64, got a value of type Bool",
    ),
    (
        row = Any[1, 1, "a", UInt8[]],
        fragment = "column \"x\" is float64, got a value of type Int64",
    ),
    (
        row = Any[1, 1.0, SubString("ab", 1, 1), UInt8[]],
        fragment = "column \"s\" is text, got a value of type SubString{String}",
    ),
    (
        row = Any[1, 1.0, "a", "b"],
        fragment = "column \"b\" is bytes, got a value of type String",
    ),
]

const KEY_ORDER_REFUSALS = [
    (
        keys = [(UInt8[2],), (UInt8[1],)], context = "inside one op",
        fragment = "rows are not in primary-key order: (UInt8[0x01],) after (UInt8[0x02],)",
    ),
    (
        keys = [(UInt8[1],), (UInt8[1],)], context = "inside one op",
        fragment = "duplicate key (UInt8[0x01],) inside one op",
    ),
    (
        keys = [(1,), (1,)], context = "in a table file",
        fragment = "duplicate key (1,) in a table file",
    ),
]

@testset "check_row accepts the four carriers, and null where the column allows it" begin
    @test Model.check_row(TYPED, Any[1, missing, "a", UInt8[]]) === nothing
    @test Model.check_row(TYPED, Any[1, NaN, "a", UInt8[1]]) === nothing
end

@testset "check_row refuses" begin
    @testset "$(case.fragment)" for case in ROW_REFUSALS
        @test_throws ModelError as_shown(case.fragment) Model.check_row(TYPED, case.row)
    end
end

@testset "check_key_order accepts keys that strictly increase" begin
    @test Model.check_key_order([(UInt8[1],), (UInt8[2],)]) === nothing
    @test Model.check_key_order(()) === nothing
    @test Model.check_key_order([(1,)]) === nothing
end

@testset "check_key_order refuses" begin
    @testset "$(case.fragment)" for case in KEY_ORDER_REFUSALS
        @test_throws(
            ModelError, as_shown(case.fragment),
            Model.check_key_order(case.keys; context = case.context)
        )
    end
end

@testset "check_update returns the declaration positions of the columns" begin
    columns = [
        Column("id", "int64", false), Column("w", "float64", false),
        Column("n", "int64", true),
    ]
    shape = Shape(columns, ["id"])
    @test Model.check_update(shape, ["w", "n"], [Any[1, 3.0, 3]]) == [2, 3]
end
