using Test
using ChainTables: CBOR, Model
# The model's rules are the format's spec. The write builder and apply report them
# through two public errors, so they are tested once here, where they live.
using ChainTables.Model: Column, ModelError, Shape

include("fixtures/internal_errors.jl")

const ID = Column("id", "int64", false)
const ID_MASS = Shape([ID, Column("mass", "float64", true)], ["id"])
const ID_WIRE = Any["id", "int64", false]
const KEY_WIRE = Any["id"]
const BAD_ENTRY = Any["id", "int64", 0]

const SHAPE_REFUSALS = [
    (columns = Column[], key = String[], fragment = "table has no columns"),
    (
        columns = [Column("Id", "int64", false)], key = ["Id"],
        fragment = "column name \"Id\" is not an identifier",
    ),
    (
        columns = [Column("1a", "int64", false)], key = ["1a"],
        fragment = "column name \"1a\" is not an identifier",
    ),
    (
        columns = [Column("", "int64", false)], key = [""],
        fragment = "column name \"\" is not an identifier",
    ),
    (
        columns = [ID, Column("id", "text", false)], key = ["id"],
        fragment = "duplicate column name \"id\"",
    ),
    (
        columns = [Column("id", "Int", false)], key = ["id"],
        fragment = "unknown value type \"Int\"",
    ),
    (
        columns = [Column("id", "Int64", false)], key = ["id"],
        fragment = "unknown value type \"Int64\"",
    ),
    (columns = [ID], key = String[], fragment = "table has no primary key"),
    (
        columns = [ID], key = ["x"],
        fragment = "key column \"x\" is not a column of the table",
    ),
    (
        columns = [Column("id", "int64", true)], key = ["id"],
        fragment = "key column \"id\" is nullable",
    ),
    (columns = [ID], key = ["id", "id"], fragment = "duplicate key column \"id\""),
    # A column name starts with a letter, so `_slot` never collides with a column
    # (ADR-0032).
    (
        columns = [Column("_slot", "int64", false)], key = ["_slot"],
        fragment = "column name \"_slot\" is not an identifier " *
            "([a-z][a-z0-9_]*: a column name starts with a letter)",
    ),
    (
        columns = [ID, Column("_x", "text", true)], key = ["id"],
        fragment = "column name \"_x\" is not an identifier",
    ),
]

const SHAPE_WIRE_REFUSALS = [
    (
        name = "an unknown field",
        wire = Dict{String, Any}("columns" => Any[ID_WIRE], "key" => KEY_WIRE, "x" => 1),
        fragment = "unknown shape field \"x\"",
    ),
    (
        name = "no key", wire = Dict{String, Any}("columns" => Any[ID_WIRE]),
        fragment = "shape has no \"key\"",
    ),
    (
        name = "no columns", wire = Dict{String, Any}("key" => Any["id"]),
        fragment = "shape has no \"columns\"",
    ),
    (
        name = "columns that are not an array",
        wire = Dict{String, Any}("columns" => 1, "key" => Any["id"]),
        fragment = "shape \"columns\" is not an array",
    ),
    (
        name = "a column entry of two items",
        wire = Dict{String, Any}("columns" => Any[Any["id", "int64"]], "key" => Any["id"]),
        fragment = "column entry",
    ),
    (
        name = "a column entry whose nullable is not a bool",
        wire = Dict{String, Any}("columns" => Any[BAD_ENTRY], "key" => KEY_WIRE),
        fragment = "column entry",
    ),
    (
        name = "a key that is not an array of names",
        wire = Dict{String, Any}("columns" => Any[ID_WIRE], "key" => Any[1]),
        fragment = "shape \"key\" is not an array of names",
    ),
    (name = "a value that is not a map", wire = 1, fragment = "shape is not a map"),
]

const IDENTIFIERS = [
    (name = "a_b9", table = true, column = true),
    (name = "a_", table = true, column = true),
    # A table name may start with `_`; a column name may not.
    (name = "_", table = true, column = false),
    (name = "_slot", table = true, column = false),
    (name = "a-b", table = false, column = false),
    (name = "é", table = false, column = false),
    (name = "A", table = false, column = false),
    (name = "9a", table = false, column = false),
    # A trailing newline is outside the charset.
    (name = "t\n", table = false, column = false),
]

@testset "Column holds a name, a value type and nullability" begin
    column = @inferred Column("mass", "float64", true)
    @test (column.name, column.type, column.nullable) == ("mass", "float64", true)
end

@testset "Shape holds columns in declaration order and the key" begin
    shape = @inferred Shape([ID, Column("mass", "float64", true)], ["id"])
    @test shape.key == ["id"]
    @test Model.column_index(shape, "mass") == 2
end

@testset "Shape refuses a shape that breaks a rule" begin
    @testset "$(case.fragment)" for case in SHAPE_REFUSALS
        @test_throws ModelError as_shown(case.fragment) Shape(case.columns, case.key)
    end
end

# "key" sorts before "columns": bytewise on the encoded key, the shorter head byte wins.
@testset "Shape has one wire form, written by hand" begin
    hex = "a2 63 6b6579 81 62 6964 67 636f6c756d6e73 82 83 62 6964 65 696e743634 f4 " *
        "83 64 6d617373 67 666c6f61743634 f5"
    @test bytes2hex(CBOR.encode(Model.wire(ID_MASS))) == replace(hex, " " => "")
end

@testset "Shape reads its wire form back" begin
    wire = CBOR.decode(CBOR.encode(Model.wire(ID_MASS)))
    @test @inferred(Shape(wire)) == ID_MASS
end

@testset "Shape refuses a wire form with" begin
    @testset "$(case.name)" for case in SHAPE_WIRE_REFUSALS
        @test_throws ModelError as_shown(case.fragment) Shape(case.wire)
    end
end

@testset "Shape conforms: equal shapes are one key of a Dict and one member of a Set" begin
    twin = Shape([Column("id", "int64", false), Column("mass", "float64", true)], ["id"])
    other = Shape([ID], ["id"])
    @test (ID_MASS == twin) === true
    @test (ID_MASS == other) === false
    @test hash(ID_MASS) == hash(twin)
    @test Dict(ID_MASS => 1)[twin] == 1
    @test twin in Set([ID_MASS])
    @test length(Set([ID_MASS, twin, other])) == 2
end

@testset "column_index refuses an unknown column" begin
    @test_throws ModelError "unknown column" Model.column_index(ID_MASS, "nope")
end

@testset "is_identifier and is_column_name hold the two charsets" begin
    @testset "$(repr(case.name))" for case in IDENTIFIERS
        @test Model.is_identifier(case.name) === case.table
        @test Model.is_column_name(case.name) === case.column
    end
end

@testset "key_of gives the key in key declaration order, not column order" begin
    columns = [
        Column("b", "bytes", false), Column("n", "int64", false),
        Column("s", "text", false),
    ]
    shape = Shape(columns, ["s", "n"])
    @test Model.key_of(shape, Any[UInt8[], 1, "é"]) == ("é", 1)
end
