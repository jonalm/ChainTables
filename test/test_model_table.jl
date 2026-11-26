using Test
using ChainTables: Model
# The model's rules are the format's spec. The write builder and apply report them
# through two public errors, so they are tested once here, where they live.
using ChainTables.Model: Column, ModelError, Shape, Table

include("fixtures/internal_errors.jl")
include("fixtures/model_tables.jl")

const ID_V = Shape([Column("id", "int64", false), Column("v", "text", true)], ["id"])
const ID_V_W_N = Shape(
    [
        Column("id", "int64", false), Column("v", "text", true),
        Column("w", "float64", false), Column("n", "int64", true),
    ], ["id"]
)
const BY_FLOAT = Shape([Column("x", "float64", false), Column("l", "text", false)], ["x"])
const BY_TEXT_THEN_INT = Shape(
    [Column("b", "bytes", false), Column("n", "int64", false), Column("s", "text", false)],
    ["s", "n"]
)
const BY_BYTES = Shape([Column("k", "bytes", false)], ["k"])
const TABLE_SIGNBIT_NAN = reinterpret(Float64, 0xfff8000000000000)

two_rows() = Table(ID_V, [Any[1, missing], Any[2, "b"]], 1)
wide_row() = Table(ID_V_W_N, [Any[1, "one", 2.0, missing]], 1)

function float_keys()
    rows = [
        Any[-Inf, "neginf"], Any[-0.0, "negzero"], Any[0.0, "zero"], Any[1.0, "one"],
        Any[Inf, "inf"], Any[NaN, "nan"],
    ]
    return Table(BY_FLOAT, rows, 1)
end

const INSERT_REFUSALS = [
    (
        rows = [Any[4, "b"], Any[3, missing]],
        fragment = "rows are not in primary-key order: (3,) after (4,)",
    ),
    (rows = [Any[1, "x"]], fragment = "insert names a key that is present: (1,)"),
    (rows = [Any[5, "x"], Any[5, "y"]], fragment = "duplicate key (5,) inside one op"),
]

const UPDATE_REFUSALS = [
    (
        names = ["v"], rows = [Any[9, "x"]],
        fragment = "update names a key that is absent: (9,)",
    ),
    (names = ["id"], rows = [Any[1, 7]], fragment = "update names key column \"id\""),
    (names = String[], rows = [Any[1]], fragment = "update names no non-key column"),
    (
        names = ["v"], rows = [Any[1, 7]],
        fragment = "column \"v\" is text, got a value of type Int64",
    ),
    (
        names = ["v"], rows = [Any[1]],
        fragment = "update row has 1 cells; expected 1 key cells and 1 values",
    ),
    (
        names = ["v"], rows = [Any[2, "x"], Any[1, "y"]],
        fragment = "rows are not in primary-key order: (1,) after (2,)",
    ),
    (
        names = ["v"], rows = [Any[1, "x"], Any[1, "y"]],
        fragment = "duplicate key (1,) inside one op",
    ),
    (
        names = ["n", "w"], rows = [Any[1, 3, 3.0]],
        fragment = "update columns are not in declaration order: [\"n\", \"w\"]",
    ),
    (
        names = ["w", "w"], rows = [Any[1, 3.0, 3.0]],
        fragment = "duplicate column \"w\" in one update",
    ),
    (names = ["zz"], rows = [Any[1, "x"]], fragment = "unknown column \"zz\""),
]

const DELETE_REFUSALS = [
    (keys = [(2,), (1,)], fragment = "rows are not in primary-key order: (1,) after (2,)"),
    (keys = [(9,)], fragment = "delete rows names a key that is absent: (9,)"),
    (keys = [(1,), (1,)], fragment = "duplicate key (1,) inside one op"),
    (keys = [(1, 2)], fragment = "key (1, 2) has 2 cells; the key has 1"),
]

const ADD_COLUMN_REFUSALS = [
    (
        column = Column("w", "float64", false), fill = 2.0,
        fragment = "column \"w\" already exists",
    ),
    (
        column = Column("z", "int64", false), fill = missing,
        fragment = "column \"z\" is int64 and does not admit null",
    ),
    (
        column = Column("_x", "int64", true), fill = missing,
        fragment = "column name \"_x\" is not an identifier",
    ),
    (
        column = Column("z", "decimal", true), fill = missing,
        fragment = "unknown value type \"decimal\"",
    ),
]

const TABLE_REFUSALS = [
    (
        shape = ID_V, rows = [Any[1, "a"], Any[1, "b"]],
        fragment = "duplicate key (1,) inside one op",
    ),
    (
        shape = ID_V, rows = [Any[missing, "a"]],
        fragment = "column \"id\" is int64 and does not admit null",
    ),
    # The typed key order: NaN sorts after +Inf and equals itself, -0.0 sorts before 0.0.
    (
        shape = BY_FLOAT, rows = [Any[NaN, "nan"], Any[Inf, "inf"]],
        fragment = "rows are not in primary-key order: (Inf,) after (NaN,)",
    ),
    (
        shape = BY_FLOAT, rows = [Any[0.0, "zero"], Any[-0.0, "negzero"]],
        fragment = "rows are not in primary-key order: (-0.0,) after (0.0,)",
    ),
    (
        shape = BY_FLOAT, rows = [Any[NaN, "nan"], Any[TABLE_SIGNBIT_NAN, "nan again"]],
        fragment = "duplicate key (NaN,) inside one op",
    ),
    (
        shape = BY_TEXT_THEN_INT, rows = [Any[UInt8[], 2, "z"], Any[UInt8[], -1, "z"]],
        fragment = "rows are not in primary-key order: (\"z\", -1) after (\"z\", 2)",
    ),
    (
        shape = BY_TEXT_THEN_INT, rows = [Any[UInt8[], 1, "é"], Any[UInt8[], 0, "a"]],
        fragment = "rows are not in primary-key order: (\"a\", 0) after (\"é\", 1)",
    ),
    (
        shape = BY_BYTES, rows = [Any[UInt8[1, 2]], Any[UInt8[1]]],
        fragment = "rows are not in primary-key order: " *
            "(UInt8[0x01],) after (UInt8[0x01, 0x02],)",
    ),
]

@testset "Table(shape) is the empty table" begin
    table = @inferred Table(ID_V)
    @test Model.n_rows(table) == 0
end

@testset "Table(shape, rows, slot) holds the rows, each stamped with the slot" begin
    table = @inferred Table(ID_V, [Any[1, missing], Any[2, "b"]], 7)
    @test Model.n_rows(table) == 2
    @test isequal(row_of(table, (2,)), Any[2, "b"])
    @test table.slots == [7, 7]
end

@testset "Table refuses rows that break a rule" begin
    @testset "$(case.fragment)" for case in TABLE_REFUSALS
        @test_throws ModelError as_shown(case.fragment) Table(case.shape, case.rows, 1)
    end
end

@testset "insert_rows! adds rows and indexes them by key" begin
    table = two_rows()
    Model.insert_rows!(table, [Any[3, "c"]], 4)
    @test Model.n_rows(table) == 3
    @test haskey(table.index, (3,))
    @test table.slots == [1, 1, 4]
end

@testset "insert_rows! refuses, and changes nothing" begin
    @testset "$(case.fragment)" for case in INSERT_REFUSALS
        table = two_rows()
        @test_throws(
            ModelError, as_shown(case.fragment), Model.insert_rows!(table, case.rows, 1)
        )
        @test isequal(rows_in_key_order(table), [Any[1, missing], Any[2, "b"]])
    end
end

@testset "update_rows! sets the named columns and stamps the row" begin
    table = two_rows()
    Model.update_rows!(table, ["v"], [Any[1, "one"]], 5)
    @test isequal(row_of(table, (1,)), Any[1, "one"])
    @test table.slots == [5, 1]
end

@testset "update_rows! refuses, and changes nothing" begin
    @testset "$(case.fragment)" for case in UPDATE_REFUSALS
        table = wide_row()
        @test_throws(
            ModelError, as_shown(case.fragment),
            Model.update_rows!(table, case.names, case.rows, 1)
        )
        @test isequal(row_of(table, (1,)), Any[1, "one", 2.0, missing])
    end
end

@testset "delete_rows! removes the rows and their keys" begin
    table = two_rows()
    Model.delete_rows!(table, [(2,)])
    @test Model.n_rows(table) == 1
    @test collect(keys(table.index)) == [(1,)]
end

@testset "delete_rows! refuses, and changes nothing" begin
    @testset "$(case.fragment)" for case in DELETE_REFUSALS
        table = two_rows()
        @test_throws ModelError as_shown(case.fragment) Model.delete_rows!(table, case.keys)
        @test Model.n_rows(table) == 2
    end
end

@testset "add_column! gives every row the fill and stamps every row" begin
    table = two_rows()
    Model.add_column!(table, Column("w", "float64", false), 2.0, 3)
    Model.add_column!(table, Column("n", "int64", true), missing, 4)
    @test isequal(row_of(table, (2,)), Any[2, "b", 2.0, missing])
    @test table.slots == [4, 4]
end

@testset "add_column! refuses, and changes nothing" begin
    @testset "$(case.fragment)" for case in ADD_COLUMN_REFUSALS
        table = wide_row()
        @test_throws(
            ModelError, as_shown(case.fragment),
            Model.add_column!(table, case.column, case.fill, 1)
        )
        @test table.shape == ID_V_W_N
    end
end

@testset "drop_column! removes a non-key column and stamps every row" begin
    table = wide_row()
    Model.drop_column!(table, "v", 6)
    @test isequal(row_of(table, (1,)), Any[1, 2.0, missing])
    @test table.slots == [6]
end

# One encoding of a shape (ADR-0025): the table file is the same bytes either way.
@testset "drop_column! reaches the shape that is declared outright" begin
    table = wide_row()
    Model.drop_column!(table, "v", 1)
    columns = [
        Column("id", "int64", false), Column("w", "float64", false),
        Column("n", "int64", true),
    ]
    declared = Shape(columns, ["id"])
    @test table.shape == declared
    outright = Table(declared, [Any[1, 2.0, missing]], 1)
    @test Model.table_hash(table) == Model.table_hash(outright)
end

@testset "drop_column! refuses a key column" begin
    @test_throws ModelError "is a key column" Model.drop_column!(wide_row(), "id", 1)
end

@testset "drop_column! refuses an unknown column" begin
    @test_throws ModelError "unknown column" Model.drop_column!(wide_row(), "zz", 1)
end

@testset "Table keys a float key by NaN, and holds -0.0 and 0.0 as two rows" begin
    table = float_keys()
    @test Model.n_rows(table) == 6
    @test haskey(table.index, (NaN,))
    @test haskey(table.index, (TABLE_SIGNBIT_NAN,))
    @test row_of(table, (NaN,))[2] == "nan"
    @test row_of(table, (-0.0,))[2] == "negzero"
    @test row_of(table, (0.0,))[2] == "zero"
end

@testset "Table orders float keys in typed key order, NaN after +Inf" begin
    labels = [row[2] for row in rows_in_key_order(float_keys())]
    @test labels == ["neginf", "negzero", "zero", "one", "inf", "nan"]
end

@testset "insert_rows! takes a NaN of another bit pattern for the NaN key present" begin
    @test_throws(
        ModelError, "insert names a key that is present: (NaN,)",
        Model.insert_rows!(float_keys(), [Any[TABLE_SIGNBIT_NAN, "again"]], 1)
    )
end

@testset "update_rows! finds a NaN key" begin
    table = float_keys()
    Model.update_rows!(table, ["l"], [Any[NaN, "still nan"]], 1)
    @test row_of(table, (NaN,))[2] == "still nan"
end

@testset "delete_rows! tells a key of -0.0 from one of 0.0" begin
    table = float_keys()
    Model.delete_rows!(table, [(-0.0,)])
    @test haskey(table.index, (0.0,))
    labels = [row[2] for row in rows_in_key_order(table)]
    @test labels == ["neginf", "zero", "one", "inf", "nan"]
end

# Text compares by UTF-8 bytes, so "z" sorts before "é".
@testset "Table orders a composite key by its columns in key declaration order" begin
    rows = [
        Any[UInt8[], 0, "a"], Any[UInt8[], -1, "z"], Any[UInt8[], 2, "z"],
        Any[UInt8[], 1, "é"],
    ]
    table = Table(BY_TEXT_THEN_INT, rows, 1)
    keys = [(row[3], row[2]) for row in rows_in_key_order(table)]
    @test keys == [("a", 0), ("z", -1), ("z", 2), ("é", 1)]
end

@testset "Table orders rows of a bytes key bytewise" begin
    rows = [Any[UInt8[]], Any[UInt8[1]], Any[UInt8[1, 2]], Any[UInt8[2]]]
    table = Table(BY_BYTES, rows, 1)
    keys = [only(row) for row in rows_in_key_order(table)]
    @test keys == [UInt8[], UInt8[1], UInt8[1, 2], UInt8[2]]
end

@testset "Table copies a bytes cell in, so a caller's alias cannot change the content" begin
    bytes = UInt8[1, 2]
    table = Table(BY_BYTES, [Any[bytes]], 1)
    bytes[1] = 0xff
    @test only(row_of(table, (UInt8[1, 2],))) == UInt8[1, 2]
end
