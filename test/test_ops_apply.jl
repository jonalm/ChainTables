using Test
using ChainTables: ChainTables, CBOR, Column, Content, MalformedRecordError, ModelError,
    Shape, Table, key_of, row_of, state_fingerprint
# Apply is internal to the local copy; its checks are the format's spec (ADR-0025), with a
# frozen reference value, so it is tested here directly.
using ChainTables.Ops: AddColumn, Client, CreateTable, Delete, DropColumn, DropTable,
    Insert, Op, Record, Update, apply!, decode_record, encode_record, sort_rows,
    transaction_hash

const CHAIN_ID = UInt8.(0:15)
const FINGERPRINT = fill(0xaa, 32)
const PREV = fill(0xbb, 32)
const CLIENT = Client(nothing, nothing, "L", "J", 1)
const SHAPE = Shape([Column("id", "int64", false), Column("v", "text", true)], ["id"])

# A record as a second client meets it: through its bytes.
function second(slot, ops)
    record = Record(CHAIN_ID, slot, PREV, FINGERPRINT, CLIENT, nothing, ops)
    return decode_record(encode_record(record); slot)
end

function fresh()
    c = Content()
    apply!(
        c,
        second(1, [CreateTable("t", SHAPE), Insert("t", [Any[1, "a"], Any[2, missing]])]),
    )
    return c
end

function malformed(c, record)
    try
        apply!(c, record)
    catch e
        e isa MalformedRecordError || rethrow()
        return e
    end
    return nothing
end

@testset "apply! of a record creates and fills a table" begin
    c = fresh()
    @test collect(keys(c)) == ["t"]
    @test isequal(row_of(c["t"], (2,)), Any[2, missing])
    expected = Content("t" => Table(SHAPE, [Any[1, "a"], Any[2, missing]], 1))
    @test state_fingerprint(c) == state_fingerprint(expected)
end

const EVERY_OP = Op[
    Update("t", ["v"], [Any[2, "b"]]),
    Delete("t", [Any[1]]),
    AddColumn("t", Column("w", "float64", false), 0.5),
    AddColumn("t", Column("n", "int64", true), missing),
    DropColumn("t", "v"),
    CreateTable("u", Shape([Column("k", "bytes", false)], ["k"])),
    Insert("u", [Any[UInt8[]], Any[UInt8[1]]]),
    DropTable("u"),
]

@testset "apply! runs every op kind of a record in order" begin
    c = fresh()
    @test apply!(c, second(2, EVERY_OP)) === nothing
    @test collect(keys(c)) == ["t"]
    @test isequal(row_of(c["t"], (2,)), Any[2, 0.5, missing])
    expected = Shape(
        [
            Column("id", "int64", false), Column("w", "float64", false),
            Column("n", "int64", true),
        ],
        ["id"],
    )
    @test c["t"].shape == expected
    apply!(c, second(3, [DropTable("t")]))
    @test isempty(c)
end

# The named test: a float64 in an int64 column, met by a second client.
const FLOAT_IN_INT = [DropColumn("t", "v"), Insert("t", [Any[3.0]])]

@testset "apply! names the slot, op and rule of a malformed record" begin
    e = malformed(fresh(), second(2, FLOAT_IN_INT))
    @test e.slot == 2
    @test e.op == 2
    @test e.chain_id == "AAAQEAYEAUDAOCAJBIFQYDIOB4"
    @test e.detail == "insert on \"t\": column \"id\" is int64, got a value of type Float64"
    @test occursin("The chain cannot be read beyond this slot", sprint(showerror, e))
end

# Each structural check (ADR-0025), refused at the op that breaks it.
const BROKEN_OPS = [
    (
        name = "null in a key",
        ops = [Insert("t", [Any[missing, "x"]])],
        detail = "insert on \"t\": column \"id\" is int64 and does not admit null",
    ),
    (
        name = "a short row",
        ops = [Insert("t", [Any[3]])],
        detail = "insert on \"t\": row has 1 cells; the shape has 2 columns",
    ),
    (
        name = "an unknown table",
        ops = [Insert("nope", [Any[3, "x"]])],
        detail = "insert on \"nope\": unknown table \"nope\"",
    ),
    (
        name = "an unknown column",
        ops = [Update("t", ["zz"], [Any[1, "x"]])],
        detail = "update on \"t\": unknown column \"zz\"",
    ),
    (
        name = "dropping a key column",
        ops = [DropColumn("t", "id")],
        detail = "drop_column on \"t\": column \"id\" is a key column and cannot be " *
            "dropped",
    ),
    (
        name = "a null fill",
        ops = [AddColumn("t", Column("n", "int64", false), missing)],
        detail = "add_column on \"t\": column \"n\" is int64 and does not admit null",
    ),
    (
        name = "an existing column",
        ops = [AddColumn("t", Column("v", "text", true), missing)],
        detail = "add_column on \"t\": column \"v\" already exists",
    ),
    (
        name = "a duplicate insert key",
        ops = [Insert("t", [Any[3, "x"], Any[3, "y"]])],
        detail = "insert on \"t\": duplicate key (3,) inside one op",
    ),
    (
        name = "a duplicate delete key",
        ops = [Delete("t", [Any[1], Any[1]])],
        detail = "delete on \"t\": duplicate key (1,) inside one op",
    ),
    (
        name = "insert rows out of order",
        ops = [Insert("t", [Any[4, "x"], Any[3, "y"]])],
        detail = "insert on \"t\": rows are not in primary-key order: (3,) after (4,)",
    ),
    (
        name = "update rows out of order",
        ops = [Update("t", ["v"], [Any[2, "x"], Any[1, "y"]])],
        detail = "update on \"t\": rows are not in primary-key order: (1,) after (2,)",
    ),
    (
        name = "delete keys out of order",
        ops = [Delete("t", [Any[2], Any[1]])],
        detail = "delete on \"t\": rows are not in primary-key order: (1,) after (2,)",
    ),
    (
        name = "insert on a present key",
        ops = [Insert("t", [Any[1, "x"]])],
        detail = "insert on \"t\": insert names a key that is present: (1,)",
    ),
    (
        name = "update on an absent key",
        ops = [Update("t", ["v"], [Any[9, "x"]])],
        detail = "update on \"t\": update names a key that is absent: (9,)",
    ),
    (
        name = "delete on an absent key",
        ops = [Delete("t", [Any[9]])],
        detail = "delete on \"t\": delete names a key that is absent: (9,)",
    ),
    (
        name = "update of a key column",
        ops = [Update("t", ["id"], [Any[1, 5]])],
        detail = "update on \"t\": update names key column \"id\"; a key never changes " *
            "(delete then insert)",
    ),
    (
        name = "a short update row",
        ops = [Update("t", ["v"], [Any[1]])],
        detail = "update on \"t\": update row has 1 cells; expected 1 key cells and 1 " *
            "values",
    ),
    (
        name = "an update of no column",
        ops = [Update("t", String[], [Any[1]])],
        detail = "update on \"t\": update names no non-key column",
    ),
    (
        name = "a long delete key",
        ops = [Delete("t", [Any[1, 2]])],
        detail = "delete on \"t\": key (1, 2) has 2 cells; the key has 1",
    ),
    (
        name = "a second create",
        ops = [CreateTable("t", SHAPE)],
        detail = "create_table on \"t\": table \"t\" already exists",
    ),
    (
        name = "an upper-case table name",
        ops = [CreateTable("T", SHAPE)],
        detail = "create_table on \"T\": table name \"T\" is not an identifier " *
            "([a-z_][a-z0-9_]*)",
    ),
    (
        name = "a table name with a newline",
        ops = [CreateTable("t\n", SHAPE)],
        detail = "create_table on \"t\\n\": table name \"t\\n\" is not an identifier " *
            "([a-z_][a-z0-9_]*)",
    ),
    (
        name = "a column named _slot",
        ops = [AddColumn("t", Column("_slot", "int64", true), missing)],
        detail = "add_column on \"t\": column name \"_slot\" is not an identifier " *
            "([a-z][a-z0-9_]*: a column name starts with a letter)",
    ),
    (
        name = "a column name with a newline",
        ops = [AddColumn("t", Column("c\n", "int64", true), missing)],
        detail = "add_column on \"t\": column name \"c\\n\" is not an identifier " *
            "([a-z][a-z0-9_]*: a column name starts with a letter)",
    ),
    (
        name = "dropping an unknown table",
        ops = [DropTable("nope")],
        detail = "drop_table on \"nope\": unknown table \"nope\"",
    ),
    (
        name = "a column of an unknown table",
        ops = [DropColumn("nope", "v")],
        detail = "drop_column on \"nope\": unknown table \"nope\"",
    ),
]

@testset "apply! refuses $(case.name)" for case in BROKEN_OPS
    e = malformed(fresh(), second(2, case.ops))
    @test e.detail == case.detail
    @test e.op == 1
end

@testset "apply! refuses columns of an update out of declaration order" begin
    ops = [
        AddColumn("t", Column("w", "float64", true), missing),
        Update("t", ["w", "v"], [Any[1, 1.0, "x"]]),
    ]
    e = malformed(fresh(), second(2, ops))
    @test e.op == 2
    order = "update columns are not in declaration order: [\"w\", \"v\"]"
    @test e.detail == "update on \"t\": $order"
end

@testset "apply! applies the ops before the failing one and none after" begin
    c = fresh()
    ops = [DropColumn("t", "v"), Insert("t", [Any[1]]), CreateTable("u", SHAPE)]
    @test_throws MalformedRecordError apply!(c, second(2, ops))
    @test collect(keys(c)) == ["t"]
    @test length(c["t"].shape.columns) == 1
end

@testset "apply! of one op raises the model's error unfolded" begin
    c = fresh()
    @test apply!(c, Delete("t", [Any[1]]), 2) === nothing
    @test_throws(
        ModelError, "delete names a key that is absent: (1,)",
        apply!(c, Delete("t", [Any[1]]), 2),
    )
end

@testset "sort_rows sorts by the typed key order" begin
    rows = [Any[2, "b"], Any[1, "a"], Any[NaN, "n"]]
    @test isequal(sort_rows(rows, r -> (r[1],)), [Any[1, "a"], Any[2, "b"], Any[NaN, "n"]])
    floats = [Any[0.0, 1], Any[-0.0, 2], Any[Inf, 3], Any[NaN, 4]]
    @test isequal(
        sort_rows(floats, r -> (r[1],)),
        [Any[-0.0, 2], Any[0.0, 1], Any[Inf, 3], Any[NaN, 4]],
    )
end

const SIGNBIT_NAN = reinterpret(Float64, 0xfff8000000000000)
const MEASUREMENTS = Shape(
    [
        Column("sample", "text", false), Column("run", "int64", false),
        Column("value", "float64", true), Column("payload", "bytes", false),
    ], ["sample", "run"]
)
const POINTS = Shape([Column("x", "float64", false), Column("label", "text", true)], ["x"])
by_first(r) = (r[1],)

const MEASUREMENT_ROWS = [
    Any["水", 1, -0.0, UInt8[]],
    Any["água", 2, SIGNBIT_NAN, UInt8[0x00, 0xff]],
    Any["ß", typemax(Int64), Inf, UInt8[1, 2, 3]],
    Any["a", typemin(Int64), -Inf, UInt8[0]],
    Any["z", 0, missing, UInt8[]],
    Any["z", -1, 0.1 + 0.2, UInt8[]],
]

const POINT_ROWS = [
    Any[-0.0, "negative zero"], Any[0.0, "zero"], Any[NaN, "nan"], Any[Inf, "inf"],
    Any[-Inf, "-inf"], Any[1.5, "one and a half"], Any[1.0e300, "big"],
    Any[5.0e-324, "denormal"], Any[2.0, missing],
]

# The determinism vector of test/test_fingerprint.jl as one record at slot 2^32 with a
# parent. The client fields are literals, not this machine's.
const VECTOR_OPS = Op[
    CreateTable("measurements", MEASUREMENTS),
    Insert("measurements", sort_rows(MEASUREMENT_ROWS, r -> key_of(MEASUREMENTS, r))),
    CreateTable("points", POINTS),
    Insert("points", sort_rows(POINT_ROWS, r -> key_of(POINTS, r))),
    AddColumn("points", Column("weight", "float64", false), 2.0),
    AddColumn("points", Column("tag", "text", true), missing),
    Update(
        "points", ["label", "weight"],
        sort_rows([Any[NaN, "not a number", 0.5], Any[-0.0, missing, -1.0]], by_first),
    ),
    Delete("points", sort_rows([Any[1.5], Any[Inf]], by_first)),
    DropColumn("points", "tag"),
    CreateTable(
        "empty", Shape([Column("k", "int64", false), Column("v", "text", true)], ["k"]),
    ),
    CreateTable("set", Shape([Column("k", "bytes", false)], ["k"])),
    Insert(
        "set",
        sort_rows([Any[UInt8[2]], Any[UInt8[1, 2]], Any[UInt8[1]], Any[UInt8[]]], by_first),
    ),
    CreateTable("gone", Shape([Column("k", "int64", false)], ["k"])),
    Insert("gone", [Any[1]]),
    DropTable("gone"),
]

# Frozen: a changed literal is a chain break and needs an ADR.
const FROZEN_FINGERPRINT = hex2bytes(
    "331e990a50abbbb3415e34eed0feb7fdc6549530bad76d3c8579c7ee086054df",
)
const FROZEN_TRANSACTION_HASH =
    "ba70e47ecaf045d61d56bd2f937e80356e4850331a59add52d49e5771dbce16a"
const VECTOR_CLIENT = Client("ci", "ci", "ChainTables 0.1.0", "1.10.0", 1_700_000_000_000)
const VECTOR = Record(
    UInt8.(0:15), 2^32, UInt8.(0:31), FROZEN_FINGERPRINT, VECTOR_CLIENT,
    "determinism vector", VECTOR_OPS,
)

@testset "the determinism record reproduces the frozen state fingerprint" begin
    c = Content()
    apply!(c, VECTOR)
    @test state_fingerprint(c) == FROZEN_FINGERPRINT
end

@testset "the determinism record's bytes hash to the frozen transaction hash" begin
    bytes = encode_record(VECTOR)
    @test length(bytes) == 1278
    @test bytes2hex(transaction_hash(bytes)) == FROZEN_TRANSACTION_HASH
end

@testset "a second client reads the determinism record exactly as written" begin
    bytes = encode_record(VECTOR)
    back = decode_record(bytes; slot = 2^32)
    @test back == VECTOR
    @test encode_record(back) == bytes
    c = Content()
    apply!(c, back)
    @test state_fingerprint(c) == FROZEN_FINGERPRINT
end
