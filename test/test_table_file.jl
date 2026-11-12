using Test
# The table model is internal; its byte stream is the format's spec (ADR-0007, ADR-0023),
# with reference values of its own, so it is tested here directly.
using ChainTables: ChainTables, CBOR, Column, ModelError, Shape, Table,
    insert_table_rows!, read_table, row_of, rows_in_key_order, table_hash, write_table
using SHA: sha256

const SEPARATOR = codeunits("chaintables/v1/fp-table")
const KEY_ONLY = Shape([Column("id", "int64", false)], ["id"])
const KEY_ONLY_SHAPE_HEX = "a2 63 6b6579 81 62 6964 67 636f6c756d6e73 81 83 62 6964 " *
    "65 696e743634 f4"
const SIGNBIT_NAN = reinterpret(Float64, 0xfff8000000000000)

hex_bytes(hex) = hex2bytes(replace(hex, " " => ""))

function table_stream(t)
    io = IOBuffer()
    write_table(io, t)
    return take!(io)
end

table_file(rows_hex) = vcat(SEPARATOR, hex_bytes("82 $KEY_ONLY_SHAPE_HEX $rows_hex"))
table_file_of(rows) = vcat(
    SEPARATOR, hex_bytes("82 $KEY_ONLY_SHAPE_HEX"), CBOR.encode(rows),
)

# Rows arrive as 2 at slot 1, then 1 at slot 2; the file holds them in key order.
function two_inserts()
    t = Table(KEY_ONLY)
    insert_table_rows!(t, [Any[2]], 1)
    insert_table_rows!(t, [Any[1]], 2)
    return t
end

@testset "write_table streams an empty table as written by hand" begin
    @test table_stream(Table(KEY_ONLY)) == table_file("80")
    @test table_hash(Table(KEY_ONLY)) == sha256(table_file("80"))
end

@testset "write_table ends each row with its row slot, rows in key order" begin
    t = two_inserts()
    @test table_stream(t) == table_file("82 82 01 02 82 02 01")
    @test table_hash(t) == sha256(table_stream(t))
end

@testset "write_table writes a slot of 2^32 with an 8-byte argument" begin
    @test table_stream(Table(KEY_ONLY, [Any[1]], 2^32)) == table_file(
        "81 82 01 1b0000000100000000",
    )
end

@testset "write_table returns the hash and writes to any IO" begin
    t = two_inserts()
    io = IOBuffer()
    @test write_table(io, t) == table_hash(t)
    @test take!(io) == table_stream(t)
    @test length(table_hash(t)) == 32
end

@testset "table_hash covers the shape and the row slots" begin
    t = two_inserts()
    t_one_slot = Table(KEY_ONLY)
    insert_table_rows!(t_one_slot, [Any[1], Any[2]], 2)
    @test table_hash(Table(KEY_ONLY, [Any[1], Any[2]], 1)) != table_hash(t)
    @test table_hash(t_one_slot) != table_hash(t)
    @test table_hash(Table(Shape([Column("k", "int64", false)], ["k"]))) != table_hash(
        Table(KEY_ONLY),
    )
end

const MIXED = Shape(
    [
        Column("id", "int64", false), Column("x", "float64", true),
        Column("b", "bytes", false),
    ],
    ["id"],
)
const MIXED_TABLE = Table(
    MIXED,
    [Any[1, -0.0, UInt8[]], Any[2, missing, UInt8[0xff]], Any[3, SIGNBIT_NAN, UInt8[]]], 1,
)

@testset "write_table passes null, NaN and -0.0 through untransformed" begin
    rows_hex = "83 84 01 f98000 40 01 84 02 f6 41ff 01 84 03 f97e00 40 01"
    @test endswith(bytes2hex(table_stream(MIXED_TABLE)), replace(rows_hex, " " => ""))
end

@testset "read_table inverts write_table" begin
    back = read_table(IOBuffer(table_stream(MIXED_TABLE)))
    @test back.shape == MIXED
    @test isequal(collect(rows_in_key_order(back)), collect(rows_in_key_order(MIXED_TABLE)))
    @test row_of(back, (1,))[2] === -0.0
    @test table_hash(back) == table_hash(MIXED_TABLE)
    @test read_table(IOBuffer(table_stream(Table(KEY_ONLY)))).shape == KEY_ONLY
end

@testset "read_table keeps the row slots" begin
    t = two_inserts()
    @test table_stream(read_table(IOBuffer(table_stream(t)))) == table_stream(t)
    @test read_table(IOBuffer(table_file_of(Any[Any[1, 1], Any[2, 9]]))).slots == [1, 9]
end

# Rows out of order or duplicated are refused, not sorted: the rule an op is held to.
const REFUSED_FILES = [
    (
        name = "a short separator",
        bytes = vcat(b"chaintables/v1/fp-tabl", hex_bytes("82a0")),
        message = "not a table file",
    ),
    (name = "no bytes", bytes = UInt8[], message = "not a table file"),
    (
        name = "a shape that is no map",
        bytes = vcat(SEPARATOR, hex_bytes("820180")),
        message = "shape is not a map, got a value of type Int64",
    ),
    (
        name = "three items",
        bytes = vcat(SEPARATOR, hex_bytes("83")),
        message = "expected [shape, rows], got an array of 3",
    ),
    (
        name = "rows out of order",
        bytes = table_file_of(Any[Any[2, 1], Any[1, 1]]),
        message = "rows are not in primary-key order: (1,) after (2,)",
    ),
    (
        name = "a duplicate row",
        bytes = table_file_of(Any[Any[1, 1], Any[1, 1]]),
        message = "duplicate key (1,) in a table file",
    ),
    (
        name = "a cell off its type",
        bytes = table_file_of(Any[Any[1.5, 1]]),
        message = "column \"id\" is int64, got a value of type Float64",
    ),
    (
        name = "a row without slot",
        bytes = table_file_of(Any[Any[1]]),
        message = "row 1 has 1 entries; a table file row is [cells…, slot], 1 cells and " *
            "its row slot",
    ),
    (
        name = "a row too long",
        bytes = table_file_of(Any[Any[1, 1], Any[2, 1, 1]]),
        message = "row 2 has 3 entries; a table file row is [cells…, slot], 1 cells and " *
            "its row slot",
    ),
    (
        name = "a float slot",
        bytes = table_file_of(Any[Any[1, 1.0]]),
        message = "row 1's slot is not an int64, got a value of type Float64",
    ),
    (
        name = "a null slot",
        bytes = table_file_of(Any[Any[1, missing]]),
        message = "row 1's slot is not an int64, got a value of type Missing",
    ),
    (
        name = "slot 0",
        bytes = table_file_of(Any[Any[1, 0]]),
        message = "row 1's slot is 0; a row slot is at least 1",
    ),
    (
        name = "a negative slot",
        bytes = table_file_of(Any[Any[1, -1]]),
        message = "row 1's slot is -1; a row slot is at least 1",
    ),
    (
        name = "a row that is no array",
        bytes = table_file_of(Any[1]),
        message = "row 1 is not an array",
    ),
]

@testset "read_table refuses $(case.name)" for case in REFUSED_FILES
    @test_throws ModelError case.message read_table(IOBuffer(case.bytes))
end

@testset "read_table refuses malformed CBOR with a DecodeError" begin
    @test_throws(
        CBOR.DecodeError, "truncated input",
        read_table(IOBuffer(vcat(SEPARATOR, hex_bytes("82a2")))),
    )
end
