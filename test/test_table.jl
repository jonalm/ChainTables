using Test
# The table model is internal; its rules are the format's spec (ADR-0025), with reference
# values of their own, so they are tested here directly rather than through an API name.
using ChainTables: ChainTables, Column, ModelError, Shape, Table, append_column!,
    delete_table_rows!, has_row, insert_table_rows!, nrows, remove_column!, row_of,
    rows_in_key_order, table_hash, update_table_rows!

const SHAPE = Shape([Column("id", "int64", false), Column("v", "text", true)], ["id"])
const SIGNBIT_NAN = reinterpret(Float64, 0xfff8000000000000)

two_rows() = Table(SHAPE, [Any[1, missing], Any[2, "b"]], 1)

@testset "insert_table_rows! adds rows in key order" begin
    t = Table(SHAPE)
    @test nrows(t) == 0
    insert_table_rows!(t, [Any[1, missing], Any[2, "b"]], 1)
    @test nrows(t) == 2
    @test has_row(t, (1,))
    @test !has_row(t, (3,))
    @test isequal(row_of(t, (2,)), Any[2, "b"])
end

# The primitives take the canonical payload and never sort.
const REFUSED_INSERTS = [
    (
        name = "rows out of key order",
        rows = [Any[2, "b"], Any[1, missing]],
        message = "rows are not in primary-key order: (1,) after (2,)",
    ),
    (
        name = "a present key",
        rows = [Any[1, "x"]],
        message = "insert names a key that is present: (1,)",
    ),
    (
        name = "a duplicate key",
        rows = [Any[5, "x"], Any[5, "y"]],
        message = "duplicate key (5,) inside one op",
    ),
]

@testset "insert_table_rows! refuses $(case.name), no change" for case in REFUSED_INSERTS
    t = two_rows()
    @test_throws ModelError case.message insert_table_rows!(t, case.rows, 1)
    @test nrows(t) == 2
end

@testset "update_table_rows! sets the named columns" begin
    t = two_rows()
    update_table_rows!(t, ["v"], [Any[1, "one"]], 1)
    @test isequal(row_of(t, (1,)), Any[1, "one"])
end

const REFUSED_UPDATES = [
    (
        name = "an absent key",
        columns = ["v"],
        rows = [Any[9, "x"]],
        message = "update names a key that is absent: (9,)",
    ),
    (
        name = "a key column",
        columns = ["id"],
        rows = [Any[1, 7]],
        message = "update names key column \"id\"",
    ),
    (
        name = "no column",
        columns = String[],
        rows = [Any[1]],
        message = "update names no non-key column",
    ),
    (
        name = "a cell off its type",
        columns = ["v"],
        rows = [Any[1, 7]],
        message = "column \"v\" is text, got a value of type Int64",
    ),
    (
        name = "rows out of key order",
        columns = ["v"],
        rows = [Any[2, "x"], Any[1, "y"]],
        message = "rows are not in primary-key order: (1,) after (2,)",
    ),
    (
        name = "a duplicate key",
        columns = ["v"],
        rows = [Any[1, "x"], Any[1, "y"]],
        message = "duplicate key (1,) inside one op",
    ),
]

@testset "update_table_rows! refuses $(case.name), no change" for case in REFUSED_UPDATES
    t = two_rows()
    @test_throws ModelError case.message update_table_rows!(t, case.columns, case.rows, 1)
    @test isequal(row_of(t, (1,)), Any[1, missing])
end

@testset "delete_table_rows! removes the named rows" begin
    t = two_rows()
    delete_table_rows!(t, [(2,)])
    @test nrows(t) == 1
    @test !has_row(t, (2,))
    @test has_row(t, (1,))
end

const REFUSED_DELETES = [
    (
        name = "keys out of order",
        keys = [(2,), (1,)],
        message = "rows are not in primary-key order: (1,) after (2,)",
    ),
    (
        name = "an absent key",
        keys = [(3,)],
        message = "delete names a key that is absent: (3,)",
    ),
    (
        name = "a duplicate key",
        keys = [(1,), (1,)],
        message = "duplicate key (1,) inside one op",
    ),
]

@testset "delete_table_rows! refuses $(case.name), no change" for case in REFUSED_DELETES
    t = two_rows()
    @test_throws ModelError case.message delete_table_rows!(t, case.keys)
    @test nrows(t) == 2
end

@testset "append_column! fills every row" begin
    t = Table(SHAPE, [Any[1, "one"]], 1)
    append_column!(t, Column("w", "float64", false), 2.0, 1)
    @test isequal(row_of(t, (1,)), Any[1, "one", 2.0])
    append_column!(t, Column("n", "int64", true), missing, 1)
    @test isequal(row_of(t, (1,)), Any[1, "one", 2.0, missing])
end

const REFUSED_COLUMNS = [
    (
        name = "an existing column",
        column = Column("v", "float64", false),
        fill = 2.0,
        message = "column \"v\" already exists",
    ),
    (
        name = "null in a non-nullable column",
        column = Column("n", "int64", false),
        fill = missing,
        message = "column \"n\" is int64 and does not admit null",
    ),
    (
        name = "a name starting with _",
        column = Column("_x", "int64", true),
        fill = missing,
        message = "column name \"_x\" is not an identifier",
    ),
]

@testset "append_column! refuses $(case.name)" for case in REFUSED_COLUMNS
    t = Table(SHAPE, [Any[1, "one"]], 1)
    @test_throws ModelError case.message append_column!(t, case.column, case.fill, 1)
    @test t.shape == SHAPE
end

@testset "update_table_rows! names columns in declaration order" begin
    t = Table(SHAPE, [Any[1, "one"]], 1)
    append_column!(t, Column("w", "float64", false), 2.0, 1)
    append_column!(t, Column("n", "int64", true), missing, 1)
    @test_throws(
        ModelError, "update columns are not in declaration order: [\"n\", \"w\"]",
        update_table_rows!(t, ["n", "w"], [Any[1, 3, 3.0]], 1),
    )
    @test_throws(
        ModelError, "duplicate column \"w\" in one update",
        update_table_rows!(t, ["w", "w"], [Any[1, 3.0, 3.0]], 1),
    )
    @test isequal(row_of(t, (1,)), Any[1, "one", 2.0, missing])
end

@testset "remove_column! drops a non-key column only" begin
    t = Table(SHAPE, [Any[1, "one"]], 1)
    append_column!(t, Column("w", "float64", false), 2.0, 1)
    @test_throws(
        ModelError, "column \"id\" is a key column and cannot be dropped",
        remove_column!(t, "id", 1),
    )
    @test_throws ModelError "unknown column \"zz\"" remove_column!(t, "zz", 1)
    remove_column!(t, "v", 1)
    @test isequal(row_of(t, (1,)), Any[1, 2.0])
end

# The same shape reached by ops or declared outright gives one table file (ADR-0025).
@testset "a shape reached by ops hashes as the shape declared" begin
    t = Table(SHAPE, [Any[1, "one"]], 1)
    append_column!(t, Column("w", "float64", false), 2.0, 1)
    remove_column!(t, "v", 1)
    declared = Shape([Column("id", "int64", false), Column("w", "float64", false)], ["id"])
    @test t.shape == declared
    @test table_hash(t) == table_hash(Table(declared, [Any[1, 2.0]], 1))
end

@testset "Table refuses rows the way an insert does" begin
    @test_throws(
        ModelError, "duplicate key (1,) inside one op",
        Table(SHAPE, [Any[1, "a"], Any[1, "b"]], 1),
    )
    @test_throws(
        ModelError, "column \"id\" is int64 and does not admit null",
        Table(SHAPE, [Any[missing, "a"]], 1),
    )
end

@testset "the primitives stamp the row slot" begin
    t = Table(SHAPE, [Any[1, "a"], Any[2, "b"]], 1)
    update_table_rows!(t, ["v"], [Any[2, "c"]], 5)
    @test t.slots == [1, 5]
    append_column!(t, Column("w", "float64", true), missing, 7)
    @test t.slots == [7, 7]
end

const FLOAT_SHAPE = Shape(
    [Column("x", "float64", false), Column("l", "text", false)], ["x"],
)

float_table() = Table(
    FLOAT_SHAPE, [
        Any[-Inf, "neginf"], Any[-0.0, "negzero"], Any[0.0, "zero"], Any[1.0, "one"],
        Any[Inf, "inf"], Any[NaN, "nan"],
    ], 1
)

@testset "a NaN key matches every NaN" begin
    t = float_table()
    @test nrows(t) == 6
    @test has_row(t, (NaN,))
    @test has_row(t, (SIGNBIT_NAN,))
    @test row_of(t, (NaN,))[2] == "nan"
    @test_throws(
        ModelError, "insert names a key that is present: (NaN,)",
        insert_table_rows!(t, [Any[SIGNBIT_NAN, "again"]], 1),
    )
end

@testset "-0.0 and 0.0 are two keys" begin
    t = float_table()
    @test row_of(t, (-0.0,))[2] == "negzero"
    @test row_of(t, (0.0,))[2] == "zero"
    delete_table_rows!(t, [(-0.0,)])
    @test !has_row(t, (-0.0,))
    @test has_row(t, (0.0,))
end

@testset "rows_in_key_order puts NaN after +Inf" begin
    t = float_table()
    @test [r[2] for r in rows_in_key_order(t)] == [
        "neginf", "negzero", "zero", "one", "inf", "nan",
    ]
    update_table_rows!(t, ["l"], [Any[NaN, "still nan"]], 1)
    delete_table_rows!(t, [(-0.0,)])
    @test [r[2] for r in rows_in_key_order(t)] == [
        "neginf", "zero", "one", "inf", "still nan",
    ]
end

const FLOAT_ORDER_REFUSALS = [
    (
        name = "Inf after NaN",
        rows = [Any[NaN, "nan"], Any[Inf, "inf"]],
        message = "rows are not in primary-key order: (Inf,) after (NaN,)",
    ),
    (
        name = "-0.0 after 0.0",
        rows = [Any[0.0, "zero"], Any[-0.0, "negzero"]],
        message = "rows are not in primary-key order: (-0.0,) after (0.0,)",
    ),
    (
        name = "two NaNs",
        rows = [Any[NaN, "nan"], Any[SIGNBIT_NAN, "nan again"]],
        message = "duplicate key (NaN,) inside one op",
    ),
]

@testset "the typed key order refuses $(case.name)" for case in FLOAT_ORDER_REFUSALS
    @test_throws ModelError case.message Table(FLOAT_SHAPE, case.rows, 1)
end

# Composite keys order lexicographically in key declaration order, text by UTF-8 bytes.
const COMPOSITE = Shape(
    [Column("b", "bytes", false), Column("n", "int64", false), Column("s", "text", false)],
    ["s", "n"],
)

@testset "a composite key orders by the declared key" begin
    t = Table(
        COMPOSITE,
        [
            Any[UInt8[], 0, "a"], Any[UInt8[], -1, "z"], Any[UInt8[], 2, "z"],
            Any[UInt8[], 1, "é"],
        ],
        1,
    )
    @test [(r[3], r[2]) for r in rows_in_key_order(t)] == [
        ("a", 0), ("z", -1), ("z", 2), ("é", 1),
    ]
    @test_throws(
        ModelError, "rows are not in primary-key order: (\"z\", -1) after (\"z\", 2)",
        Table(COMPOSITE, [Any[UInt8[], 2, "z"], Any[UInt8[], -1, "z"]], 1),
    )
    @test_throws(
        ModelError, "rows are not in primary-key order: (\"a\", 0) after (\"é\", 1)",
        Table(COMPOSITE, [Any[UInt8[], 1, "é"], Any[UInt8[], 0, "a"]], 1),
    )
end

const BYTES_SHAPE = Shape([Column("k", "bytes", false)], ["k"])

@testset "a bytes key orders bytewise" begin
    t = Table(
        BYTES_SHAPE, [Any[UInt8[]], Any[UInt8[1]], Any[UInt8[1, 2]], Any[UInt8[2]]], 1,
    )
    @test [r[1] for r in rows_in_key_order(t)] == [UInt8[], UInt8[1], UInt8[1, 2], UInt8[2]]
    @test_throws(
        ModelError,
        "rows are not in primary-key order: (UInt8[0x01],) after (UInt8[0x01, " *
            "0x02],)",
        Table(BYTES_SHAPE, [Any[UInt8[1, 2]], Any[UInt8[1]]], 1),
    )
end

@testset "a bytes cell is copied in" begin
    cell = UInt8[1]
    t = Table(BYTES_SHAPE, [Any[cell]], 1)
    cell[1] = 0x09
    @test has_row(t, (UInt8[1],))
end
