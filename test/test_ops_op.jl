using Test
using ChainTables: CBOR, Model, Ops
# How strictly a wire op is read is the format's spec. A record reports it through
# `MalformedRecordError`, so it is tested once here, where it lives.
using ChainTables.Model: Column, ModelError, Shape
using ChainTables.Ops: AddColumn, CreateTable, Delete, DropColumn, DropTable, Insert,
    Update

include("fixtures/internal_errors.jl")

const OP_SHAPE = Shape([Column("id", "int64", false), Column("v", "text", true)], ["id"])
const N_COLUMN = Column("n", "int64", true)
const W_COLUMN = Column("w", "float64", true)

const EVERY_OP = [
    (name = "create_table", op = CreateTable("t", OP_SHAPE)),
    (name = "add_column", op = AddColumn("t", Column("w", "float64", false), 2.0)),
    (name = "add_column with a null fill", op = AddColumn("t", N_COLUMN, missing)),
    (name = "add_column with a NaN fill", op = AddColumn("t", W_COLUMN, NaN)),
    (name = "drop_column", op = DropColumn("t", "v")),
    (name = "drop_table", op = DropTable("t")),
    (name = "insert", op = Insert("t", [Any[1, "a"], Any[2, missing]])),
    (name = "update", op = Update("t", ["v"], [Any[1, "b"]])),
    (name = "delete", op = Delete("t", [Any[1], Any[2]])),
]

const WIRE_OP_REFUSALS = [
    (
        wire = Dict{String, Any}("op" => "rename_table", "table" => "t"),
        fragment = "unknown op \"rename_table\"",
    ),
    (
        wire = Dict{String, Any}("op" => missing, "table" => "t"),
        fragment = "unknown op missing",
    ),
    (wire = Dict{String, Any}("table" => "t"), fragment = "op has no \"op\" field"),
    (
        wire = Dict{String, Any}("op" => "drop_table"),
        fragment = "op has no \"table\" field",
    ),
    (
        wire = Dict{String, Any}("op" => "drop_table", "table" => "t", "extra" => 1),
        fragment = "unknown field \"extra\" on a drop_table op",
    ),
    (
        wire = Dict{String, Any}("op" => "insert", "table" => "t"),
        fragment = "insert op has no \"rows\" field",
    ),
    (
        wire = Dict{String, Any}("op" => "insert", "table" => 1, "rows" => Any[]),
        fragment = "\"table\" of an insert op is not text",
    ),
    (
        wire = Dict{String, Any}("op" => "insert", "table" => "t", "rows" => Any[1]),
        fragment = "\"rows\" of an insert op is not an array of arrays",
    ),
    (
        wire = Dict{String, Any}("op" => "delete", "table" => "t", "keys" => 1),
        fragment = "\"keys\" of a delete op is not an array of arrays",
    ),
    (
        wire = Dict{String, Any}(
            "op" => "update", "table" => "t", "columns" => Any[1], "rows" => Any[]
        ),
        fragment = "\"columns\" of an update op is not an array of names",
    ),
    (
        wire = Dict{String, Any}("op" => "drop_column", "table" => "t", "column" => 1),
        fragment = "\"column\" of a drop_column op is not text",
    ),
    (
        wire = Dict{String, Any}(
            "op" => "add_column", "table" => "t", "column" => Any["n", "int64"], "fill" => 1
        ),
        fragment = "column entry",
    ),
    (
        wire = Dict{String, Any}(
            "op" => "add_column", "table" => "t", "column" => Any["n", "int64", true]
        ),
        fragment = "add_column op has no \"fill\" field",
    ),
    (
        wire = Dict{String, Any}("op" => "create_table", "table" => "t", "shape" => 1),
        fragment = "shape is not a map",
    ),
    (wire = 1, fragment = "op is not a map"),
    # A cell is a typed value or null: a bool, an array or a map is none of them.
    (
        wire = Dict{String, Any}(
            "op" => "insert", "table" => "t", "rows" => Any[Any[true]]
        ),
        fragment = "\"rows\" of an insert op holds a value of type Bool, " *
            "which is not a typed value",
    ),
    (
        wire = Dict{String, Any}(
            "op" => "delete", "table" => "t", "keys" => Any[Any[Any[]]]
        ),
        fragment = "\"keys\" of a delete op holds a value of type Vector{Any}, " *
            "which is not a typed value",
    ),
    (
        wire = Dict{String, Any}(
            "op" => "add_column", "table" => "t", "column" => Any["n", "int64", true],
            "fill" => false
        ),
        fragment = "\"fill\" of an add_column op holds a value of type Bool, " *
            "which is not a typed value",
    ),
]

through_the_wire(op) = Ops.op_from_wire(CBOR.decode(CBOR.encode(Ops.wire(op))))
wire_hex(op) = bytes2hex(CBOR.encode(Ops.wire(op)))

@testset "the op constructors infer" begin
    @test @inferred(CreateTable("t", OP_SHAPE)).table == "t"
    @test @inferred(AddColumn("t", N_COLUMN, missing)).fill === missing
    @test @inferred(DropColumn("t", "v")).column == "v"
    @test @inferred(DropTable("t")).table == "t"
    @test @inferred(Insert("t", [Any[1, "a"]])).rows == [Any[1, "a"]]
    @test @inferred(Update("t", ["v"], [Any[1, "b"]])).columns == ["v"]
    @test @inferred(Delete("t", [Any[1]])).keys == [Any[1]]
end

@testset "an op comes back from its wire form" begin
    @testset "$(case.name)" for case in EVERY_OP
        @test through_the_wire(case.op) == case.op
    end
end

# Keys sort bytewise on their encoding, so "op" comes before "table".
@testset "DropTable has its wire form, written by hand" begin
    hex = "a2 62 6f70 6a 64726f705f7461626c65 65 7461626c65 61 74"
    @test wire_hex(DropTable("t")) == replace(hex, " " => "")
end

@testset "DropColumn has its wire form, written by hand" begin
    hex = "a3 62 6f70 6b 64726f705f636f6c756d6e 65 7461626c65 61 74 66 636f6c756d6e 61 76"
    @test wire_hex(DropColumn("t", "v")) == replace(hex, " " => "")
end

@testset "AddColumn always carries its fill, a null fill as null" begin
    wire = Ops.wire(AddColumn("t", N_COLUMN, missing))
    @test wire["fill"] === missing
    @test wire["column"] == Any["n", "int64", true]
end

@testset "CreateTable carries the shape in its one encoding" begin
    @test Ops.wire(CreateTable("t", OP_SHAPE))["shape"] == Model.wire(OP_SHAPE)
end

@testset "Insert, Update and Delete carry rows as arrays" begin
    @test Ops.wire(Insert("t", [Any[1, "a"]]))["rows"] == Any[Any[1, "a"]]
    @test Ops.wire(Update("t", ["v"], [Any[1, "b"]]))["columns"] == Any["v"]
    @test Ops.wire(Delete("t", [Any[1]]))["keys"] == Any[Any[1]]
end

@testset "op_from_wire refuses" begin
    @testset "$(case.fragment)" for case in WIRE_OP_REFUSALS
        @test_throws ModelError as_shown(case.fragment) Ops.op_from_wire(case.wire)
    end
end

@testset "op_name is the wire discriminator" begin
    @test Ops.op_name(CreateTable("t", OP_SHAPE)) == "create_table"
    @test Ops.op_name(Insert("t", Vector{Any}[])) == "insert"
end

@testset "an op conforms: equal ops are one key of a Dict and one member of a Set" begin
    op = Insert("t", [Any[1, NaN], Any[2, missing]])
    twin = Insert("t", [Any[1, NaN], Any[2, missing]])
    other = Insert("t", [Any[1, 0.0]])
    @test (op == twin) === true
    @test (op == other) === false
    @test (op == Delete("t", [Any[1, NaN], Any[2, missing]])) === false
    @test hash(op) == hash(twin)
    @test Dict(op => 1)[twin] == 1
    @test length(Set([op, twin, other])) == 2
end
