using Test
# The table model is internal; its rules are the format's spec (ADR-0025), with reference
# values of their own, so they are tested here directly rather than through an API name.
using ChainTables: ChainTables, CBOR, Column, ModelError, Shape, column_index,
    is_column_name, is_identifier, key_of, shape_wire, value_type

const SHAPE = Shape([Column("id", "int64", false), Column("mass", "float64", true)], ["id"])

@testset "Shape keeps columns and key in declaration order" begin
    @test SHAPE.key == ["id"]
    @test column_index(SHAPE, "mass") == 2
    @test_throws ModelError "unknown column \"nope\"" column_index(SHAPE, "nope")
end

# "key" sorts before "columns": bytewise on the encoded key, the shorter head byte wins.
const SHAPE_HEX = "a2 63 6b6579 81 62 6964 67 636f6c756d6e73 82 83 62 6964 65 696e743634 " *
    "f4 83 64 6d617373 67 666c6f61743634 f5"

@testset "shape_wire encodes as written by hand" begin
    @test bytes2hex(CBOR.encode(shape_wire(SHAPE))) == replace(SHAPE_HEX, " " => "")
end

@testset "Shape reads its wire form back" begin
    @test Shape(CBOR.decode(CBOR.encode(shape_wire(SHAPE)))) == SHAPE
end

const ID_ENTRY = Any["id", "int64", false]

const WIRE_REFUSALS = [
    (
        name = "an unknown field",
        message = "unknown shape field \"extra\"",
        wire = Dict{String, Any}(
            "columns" => Any[ID_ENTRY], "key" => Any["id"], "extra" => 1,
        ),
    ),
    (
        name = "no key",
        message = "shape has no \"key\"",
        wire = Dict{String, Any}("columns" => Any[ID_ENTRY]),
    ),
    (
        name = "no columns",
        message = "shape has no \"columns\"",
        wire = Dict{String, Any}("key" => Any["id"]),
    ),
    (
        name = "a short column entry",
        message = "column entry",
        wire = Dict{String, Any}("columns" => Any[Any["id", "int64"]], "key" => Any["id"]),
    ),
    (
        name = "a non-Bool nullable",
        message = "column entry",
        wire = Dict{String, Any}(
            "columns" => Any[Any["id", "int64", 0]], "key" => Any["id"],
        ),
    ),
    (
        name = "columns not an array",
        message = "shape \"columns\" is not an array",
        wire = Dict{String, Any}("columns" => 1, "key" => Any["id"]),
    ),
    (
        name = "a key of non-names",
        message = "shape \"key\" is not an array of names",
        wire = Dict{String, Any}("columns" => Any[ID_ENTRY], "key" => Any[1]),
    ),
    (
        name = "not a map",
        message = "shape is not a map, got a value of type Int64",
        wire = 1,
    ),
]

@testset "Shape refuses a wire form with $(case.name)" for case in WIRE_REFUSALS
    @test_throws ModelError case.message Shape(case.wire)
end

const SHAPE_REFUSALS = [
    (
        name = "no columns",
        message = "table has no columns",
        columns = Column[],
        key = String[],
    ),
    (
        name = "an upper-case name",
        message = "column name \"Id\" is not an identifier",
        columns = [Column("Id", "int64", false)],
        key = ["Id"],
    ),
    (
        name = "a name starting with a digit",
        message = "column name \"1a\" is not an identifier",
        columns = [Column("1a", "int64", false)],
        key = ["1a"],
    ),
    (
        name = "an empty name",
        message = "column name \"\" is not an identifier",
        columns = [Column("", "int64", false)],
        key = [""],
    ),
    (
        name = "a duplicate column",
        message = "duplicate column name \"id\"",
        columns = [Column("id", "int64", false), Column("id", "text", false)],
        key = ["id"],
    ),
    (
        name = "the value type Int",
        message = "unknown value type \"Int\"",
        columns = [Column("id", "Int", false)],
        key = ["id"],
    ),
    (
        name = "the value type Int64",
        message = "unknown value type \"Int64\"",
        columns = [Column("id", "Int64", false)],
        key = ["id"],
    ),
    (
        name = "no key",
        message = "table has no primary key",
        columns = [Column("id", "int64", false)],
        key = String[],
    ),
    (
        name = "a key that is no column",
        message = "key column \"x\" is not a column of the table",
        columns = [Column("id", "int64", false)],
        key = ["x"],
    ),
    (
        name = "a nullable key",
        message = "key column \"id\" is nullable",
        columns = [Column("id", "int64", true)],
        key = ["id"],
    ),
    (
        name = "a duplicate key column",
        message = "duplicate key column \"id\"",
        columns = [Column("id", "int64", false)],
        key = ["id", "id"],
    ),
    (
        name = "_slot as a column",
        message = "column name \"_slot\" is not an identifier ([a-z][a-z0-9_]*: a column " *
            "name starts with a letter)",
        columns = [Column("_slot", "int64", false)],
        key = ["_slot"],
    ),
    (
        name = "a non-key column starting with _",
        message = "column name \"_x\" is not an identifier",
        columns = [Column("id", "int64", false), Column("_x", "text", true)],
        key = ["id"],
    ),
]

@testset "Shape refuses $(case.name)" for case in SHAPE_REFUSALS
    @test_throws ModelError case.message Shape(case.columns, case.key)
end

@testset "Shape equality ignores identity and round-trips through a Set" begin
    twin = Shape([Column("id", "int64", false), Column("mass", "float64", true)], ["id"])
    @test twin == SHAPE
    @test hash(twin) == hash(SHAPE)
    @test twin in Set([SHAPE])
    @test (twin == SHAPE) isa Bool
end

const IDENTIFIERS = [
    (name = "a_b9", table = true, column = true),
    (name = "_", table = true, column = false),
    (name = "a_", table = true, column = true),
    (name = "_slot", table = true, column = false),
    (name = "a-b", table = false, column = false),
    (name = "é", table = false, column = false),
    (name = "A", table = false, column = false),
    (name = "9a", table = false, column = false),
]

# A column name starts with a letter, so `_slot` never collides with a column; a table
# name may start with `_`.
@testset "identifier rules for $(repr(case.name))" for case in IDENTIFIERS
    @test is_identifier(case.name) === case.table
    @test is_column_name(case.name) === case.column
end

const CARRIERS = [
    (name = "Int64", value = 1, value_type = "int64"),
    (name = "Float64", value = 1.0, value_type = "float64"),
    (name = "String", value = "s", value_type = "text"),
    (name = "Vector{UInt8}", value = UInt8[], value_type = "bytes"),
    (name = "Bool", value = true, value_type = nothing),
    (name = "missing", value = missing, value_type = nothing),
    (name = "Int32", value = Int32(1), value_type = nothing),
    (name = "SubString", value = SubString("ab", 1, 1), value_type = nothing),
]

@testset "value_type of $(case.name)" for case in CARRIERS
    @test value_type(case.value) == case.value_type
end

@testset "key_of reads the key in key declaration order" begin
    s = Shape(
        [
            Column("b", "bytes", false), Column("n", "int64", false),
            Column("s", "text", false),
        ],
        ["s", "n"],
    )
    @test key_of(s, Any[UInt8[], 1, "é"]) == ("é", 1)
end
