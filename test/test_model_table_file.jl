using Test
using ChainTables: CBOR, Model
# The model's rules are the format's spec. The write builder and apply report them
# through two public errors, so they are tested once here, where they live.
using ChainTables.CBOR: DecodeError
using ChainTables.Model: Column, ModelError, Shape, Table
using SHA: sha256

include("fixtures/internal_errors.jl")
include("fixtures/model_tables.jl")

const SEPARATOR_HEX = bytes2hex(codeunits("chaintables/v1/fp-table"))
const FILE_KEY_ONLY = Shape([Column("id", "int64", false)], ["id"])
const KEY_ONLY_SHAPE_HEX = replace(
    "a2 63 6b6579 81 62 6964 67 636f6c756d6e73 81 83 62 6964 65 696e743634 f4", " " => ""
)
const WITH_NULLS = Shape(
    [
        Column("id", "int64", false), Column("x", "float64", true),
        Column("b", "bytes", false),
    ], ["id"]
)
const FILE_SIGNBIT_NAN = reinterpret(Float64, 0xfff8000000000000)

# A table file of the key-only shape: the separator, array(2), the shape, the rows.
const FILE_HEAD_HEX = SEPARATOR_HEX * "82" * KEY_ONLY_SHAPE_HEX
file_hex(rows_hex) = FILE_HEAD_HEX * replace(rows_hex, " " => "")
file_of(rows) = IOBuffer(vcat(hex2bytes(FILE_HEAD_HEX), CBOR.encode(rows)))
after_separator(hex) = IOBuffer(hex2bytes(SEPARATOR_HEX * hex))

# Two inserts, key 2 at slot 1 and then key 1 at slot 2.
function arrived_out_of_order()
    table = Table(FILE_KEY_ONLY)
    Model.insert_rows!(table, [Any[2]], 1)
    Model.insert_rows!(table, [Any[1]], 2)
    return table
end

function with_nulls()
    rows = [
        Any[1, -0.0, UInt8[]], Any[2, missing, UInt8[0xff]],
        Any[3, FILE_SIGNBIT_NAN, UInt8[]],
    ]
    return Table(WITH_NULLS, rows, 1)
end

const FILE_REFUSALS = [
    (
        name = "a wrong separator",
        io = () -> IOBuffer(vcat(b"chaintables/v1/fp-tabl", hex2bytes("82a0"))),
        fragment = "not a table file",
    ),
    (name = "no bytes", io = () -> IOBuffer(UInt8[]), fragment = "not a table file"),
    (
        name = "a shape that is not a map", io = () -> after_separator("820180"),
        fragment = "shape is not a map, got a value of type Int64",
    ),
    (
        name = "an outer array of three", io = () -> after_separator("83"),
        fragment = "expected [shape, rows], got an array of 3",
    ),
    (
        name = "rows out of key order", io = () -> file_of(Any[Any[2, 1], Any[1, 1]]),
        fragment = "rows are not in primary-key order: (1,) after (2,)",
    ),
    (
        name = "a key twice", io = () -> file_of(Any[Any[1, 1], Any[1, 1]]),
        fragment = "duplicate key (1,) in a table file",
    ),
    (
        name = "a cell off its value type", io = () -> file_of(Any[Any[1.5, 1]]),
        fragment = "column \"id\" is int64, got a value of type Float64",
    ),
    (
        name = "a row without its slot", io = () -> file_of(Any[Any[1]]),
        fragment = "row 1 has 1 entries; a table file row is [cells…, slot], " *
            "1 cells and its row slot",
    ),
    (
        name = "a row with a cell too many",
        io = () -> file_of(Any[Any[1, 1], Any[2, 1, 1]]),
        fragment = "row 2 has 3 entries; a table file row is [cells…, slot], " *
            "1 cells and its row slot",
    ),
    (
        name = "a row that is not an array", io = () -> file_of(Any[1]),
        fragment = "row 1 is not an array",
    ),
    (
        name = "a float slot", io = () -> file_of(Any[Any[1, 1.0]]),
        fragment = "row 1's slot is not an int64, got a value of type Float64",
    ),
    (
        name = "a null slot", io = () -> file_of(Any[Any[1, missing]]),
        fragment = "row 1's slot is not an int64, got a value of type Missing",
    ),
    # Slot 0 carries no ops, so no row is ever stamped 0 (ADR-0032).
    (
        name = "slot 0", io = () -> file_of(Any[Any[1, 0]]),
        fragment = "row 1's slot is 0; a row slot is at least 1",
    ),
    (
        name = "a negative slot", io = () -> file_of(Any[Any[1, -1]]),
        fragment = "row 1's slot is -1; a row slot is at least 1",
    ),
]

@testset "write_table streams a table with no rows: separator, shape, empty array" begin
    table = Table(FILE_KEY_ONLY)
    @test bytes2hex(table_bytes(table)) == file_hex("80")
    @test Model.table_hash(table) == sha256(hex2bytes(file_hex("80")))
end

# The row slot is the row's trailing entry (ADR-0032).
@testset "write_table streams rows as [cells…, slot] in key order" begin
    table = arrived_out_of_order()
    @test bytes2hex(table_bytes(table)) == file_hex("82 82 01 02 82 02 01")
end

@testset "write_table writes a slot of 2^32 in the 8-byte integer form" begin
    table = Table(FILE_KEY_ONLY, [Any[1]], 2^32)
    @test bytes2hex(table_bytes(table)) == file_hex("81 82 01 1b0000000100000000")
end

@testset "write_table passes null, NaN and -0.0 to the encoder as they are" begin
    rows_hex = "83 84 01 f98000 40 01 84 02 f6 41ff 01 84 03 f97e00 40 01"
    @test endswith(bytes2hex(table_bytes(with_nulls())), replace(rows_hex, " " => ""))
end

@testset "write_table returns the table hash and writes the same bytes to any IO" begin
    table = arrived_out_of_order()
    io = IOBuffer()
    @test @inferred(Model.write_table(io, table)) == Model.table_hash(table)
    @test take!(io) == table_bytes(table)
end

@testset "table_hash is the SHA-256 of the table file, 32 bytes" begin
    table = arrived_out_of_order()
    @test @inferred(Model.table_hash(table)) == sha256(table_bytes(table))
    @test length(Model.table_hash(table)) == 32
end

@testset "table_hash is one hash for one content" begin
    twin = Table(Shape([Column("id", "int64", false)], ["id"]))
    @test Model.table_hash(twin) == Model.table_hash(Table(FILE_KEY_ONLY))
end

@testset "table_hash differs with the shape, and with the row slots" begin
    other_shape = Table(Shape([Column("k", "int64", false)], ["k"]))
    @test Model.table_hash(other_shape) != Model.table_hash(Table(FILE_KEY_ONLY))
    hash = Model.table_hash(arrived_out_of_order())
    @test Model.table_hash(Table(FILE_KEY_ONLY, [Any[1], Any[2]], 1)) != hash
    @test Model.table_hash(Table(FILE_KEY_ONLY, [Any[1], Any[2]], 2)) != hash
end

@testset "read_table inverts write_table" begin
    table = with_nulls()
    back = @inferred Model.read_table(IOBuffer(table_bytes(table)))
    @test back.shape == WITH_NULLS
    @test isequal(rows_in_key_order(back), rows_in_key_order(table))
    @test row_of(back, (1,))[2] === -0.0
    @test Model.table_hash(back) == Model.table_hash(table)
end

@testset "read_table reads a table with no rows" begin
    empty = Table(FILE_KEY_ONLY)
    @test Model.read_table(IOBuffer(table_bytes(empty))).shape == FILE_KEY_ONLY
end

@testset "read_table reads each row's slot back" begin
    @test Model.read_table(file_of(Any[Any[1, 1], Any[2, 9]])).slots == [1, 9]
    table = arrived_out_of_order()
    @test table_bytes(Model.read_table(IOBuffer(table_bytes(table)))) == table_bytes(table)
end

@testset "read_table refuses" begin
    @testset "$(case.name)" for case in FILE_REFUSALS
        @test_throws ModelError as_shown(case.fragment) Model.read_table(case.io())
    end
end

@testset "read_table lets the decoder's error through for malformed CBOR" begin
    @test_throws DecodeError "truncated input" Model.read_table(after_separator("82a2"))
end
