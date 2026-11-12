using Test
using ChainTables: ChainTables, CBOR, Column, ModelError, Shape, shape_wire
# The ops are internal to the write builder and apply; their wire forms are the format's
# spec (ADR-0025), so they are tested here directly.
using ChainTables.Ops: AddColumn, CreateTable, Delete, DropColumn, DropTable, Insert,
    Update, op_from_wire, op_name, wire

const SHAPE = Shape([Column("id", "int64", false), Column("v", "text", true)], ["id"])

const OPS = [
    (name = "create_table", op = CreateTable("t", SHAPE)),
    (
        name = "add_column with a fill",
        op = AddColumn("t", Column("w", "float64", false), 2.0),
    ),
    (
        name = "add_column with null",
        op = AddColumn("t", Column("n", "int64", true), missing),
    ),
    (name = "drop_column", op = DropColumn("t", "v")),
    (name = "drop_table", op = DropTable("t")),
    (name = "insert", op = Insert("t", [Any[1, "a"], Any[2, missing]])),
    (name = "update", op = Update("t", ["v"], [Any[1, "b"]])),
    (name = "delete", op = Delete("t", [Any[1], Any[2]])),
    (name = "insert with NaN", op = Insert("t", [Any[NaN, "a"]])),
]

roundtrip(op) = op_from_wire(CBOR.decode(CBOR.encode(wire(op))))

@testset "op_from_wire reads back the wire form of $(case.name)" for case in OPS
    @test roundtrip(case.op) == case.op
end

@testset "$(case.name) equals its copy and round-trips through a Set" for case in OPS
    copy_of_op = roundtrip(case.op)
    @test hash(copy_of_op) == hash(case.op)
    @test copy_of_op in Set([case.op])
    @test (copy_of_op == case.op) isa Bool
end

@testset "ops of different kinds are not equal" begin
    @test DropTable("t") != DropColumn("t", "v")
    @test Insert("t", [Any[1, "a"]]) != Insert("t", [Any[2, "a"]])
end

# Keys sort bytewise on their encoding: "op" (2 chars) before "table" (5).
const WIRE_HEX = [
    (
        name = "drop_table",
        op = DropTable("t"),
        hex = "a2 62 6f70 6a 64726f705f7461626c65 65 7461626c65 61 74",
    ),
    (
        name = "drop_column",
        op = DropColumn("t", "v"),
        hex = "a3 62 6f70 6b 64726f705f636f6c756d6e 65 7461626c65 61 74 66 636f6c756d6e " *
            "61 76",
    ),
]

@testset "wire of $(case.name) encodes as written by hand" for case in WIRE_HEX
    @test bytes2hex(CBOR.encode(wire(case.op))) == replace(case.hex, " " => "")
end

@testset "wire of add_column always carries the fill" begin
    w = wire(AddColumn("t", Column("n", "int64", true), missing))
    @test w["fill"] === missing
    @test w["column"] == Any["n", "int64", true]
end

@testset "wire carries the shape, rows, columns and keys" begin
    @test wire(CreateTable("t", SHAPE))["shape"] == shape_wire(SHAPE)
    @test wire(Insert("t", [Any[1, "a"]]))["rows"] == Any[Any[1, "a"]]
    @test wire(Update("t", ["v"], [Any[1, "b"]]))["columns"] == Any["v"]
    @test wire(Delete("t", [Any[1]]))["keys"] == Any[Any[1]]
end

op_wire(pairs...) = Dict{String, Any}(pairs...)

const REFUSED_WIRES = [
    (
        name = "an unknown op",
        wire = op_wire("op" => "rename_table", "table" => "t"),
        message = "unknown op \"rename_table\"",
    ),
    (
        name = "no op field",
        wire = op_wire("table" => "t"),
        message = "op has no \"op\" field",
    ),
    (
        name = "no table field",
        wire = op_wire("op" => "drop_table"),
        message = "op has no \"table\" field",
    ),
    (
        name = "an unknown field",
        wire = op_wire("op" => "drop_table", "table" => "t", "extra" => 1),
        message = "unknown field \"extra\" on a drop_table op",
    ),
    (
        name = "no rows",
        wire = op_wire("op" => "insert", "table" => "t"),
        message = "insert op has no \"rows\" field",
    ),
    (
        name = "a table that is no text",
        wire = op_wire("op" => "insert", "table" => 1, "rows" => Any[]),
        message = "\"table\" of an insert op is not text",
    ),
    (
        name = "rows that are no arrays",
        wire = op_wire("op" => "insert", "table" => "t", "rows" => Any[1]),
        message = "\"rows\" of an insert op is not an array of arrays",
    ),
    (
        name = "keys that are no array",
        wire = op_wire("op" => "delete", "table" => "t", "keys" => 1),
        message = "\"keys\" of a delete op is not an array of arrays",
    ),
    (
        name = "columns that are no names",
        wire = op_wire(
            "op" => "update", "table" => "t", "columns" => Any[1], "rows" => Any[],
        ),
        message = "\"columns\" of an update op is not an array of names",
    ),
    (
        name = "a column that is no text",
        wire = op_wire("op" => "drop_column", "table" => "t", "column" => 1),
        message = "\"column\" of a drop_column op is not text",
    ),
    (
        name = "a short column entry",
        wire = op_wire(
            "op" => "add_column", "table" => "t", "column" => Any["n", "int64"],
            "fill" => 1,
        ),
        message = "column entry",
    ),
    (
        name = "no fill",
        wire = op_wire(
            "op" => "add_column", "table" => "t", "column" => Any["n", "int64", true],
        ),
        message = "add_column op has no \"fill\" field",
    ),
    (
        name = "a shape that is no map",
        wire = op_wire("op" => "create_table", "table" => "t", "shape" => 1),
        message = "shape is not a map",
    ),
    (
        name = "a Bool cell",
        wire = op_wire("op" => "insert", "table" => "t", "rows" => Any[Any[true]]),
        message = "\"rows\" holds a Bool, which is not a typed value",
    ),
    (
        name = "a Bool fill",
        wire = op_wire(
            "op" => "add_column", "table" => "t", "column" => Any["n", "int64", true],
            "fill" => true,
        ),
        message = "\"fill\" holds a Bool, which is not a typed value",
    ),
    (name = "a value that is no map", wire = 1, message = "op is not a map"),
]

@testset "op_from_wire refuses $(case.name)" for case in REFUSED_WIRES
    @test_throws ModelError case.message op_from_wire(case.wire)
end

@testset "op_name is the wire discriminator" begin
    @test op_name(CreateTable("t", SHAPE)) == "create_table"
    @test op_name(Insert("t", Vector{Any}[])) == "insert"
end
