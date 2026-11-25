using Test
using ChainTables: MalformedRecordError, Model, Ops
using ChainTables.Model: Column, Content, ModelError, Shape, Table
using ChainTables.Ops: AddColumn, CreateTable, Delete, DropColumn, DropTable, Insert,
    Update

include("fixtures/determinism_vector.jl")
include("fixtures/determinism_record.jl")
include("fixtures/model_tables.jl")
include("fixtures/records.jl")

const W_NULLABLE = Column("w", "float64", true)
const COLUMN_NAME_RULE = "([a-z][a-z0-9_]*: a column name starts with a letter)"
const NEXT_MOVE_AT_APPLY = "dead beyond this slot. A new chain is the recovery."

# Each case is a record at slot 2, applied to the two-row content, and the rule that its
# first bad op breaks. Every check of the write builder is run again at apply (ADR-0025).
const APPLY_REFUSALS = [
    (
        ops = [Insert("t", [Any[missing, "x"]])],
        fragment = "op 1 (insert on \"t\"): column \"id\" is int64 and does not admit null",
    ),
    (
        ops = [Insert("t", [Any[3.0, "x"]])],
        fragment = "op 1 (insert on \"t\"): column \"id\" is int64, " *
            "got a value of type Float64",
    ),
    (
        ops = [Insert("t", [Any[3]])],
        fragment = "op 1 (insert on \"t\"): row has 1 cells; the shape has 2 columns",
    ),
    (
        ops = [Insert("nope", [Any[3, "x"]])],
        fragment = "op 1 (insert on \"nope\"): unknown table \"nope\"",
    ),
    (
        ops = [Update("t", ["zz"], [Any[1, "x"]])],
        fragment = "op 1 (update on \"t\"): unknown column \"zz\"",
    ),
    (
        ops = [DropColumn("t", "id")],
        fragment = "op 1 (drop_column on \"t\"): " *
            "column \"id\" is a key column and cannot be dropped",
    ),
    (
        ops = [AddColumn("t", Column("n", "int64", false), missing)],
        fragment = "op 1 (add_column on \"t\"): " *
            "column \"n\" is int64 and does not admit null",
    ),
    (
        ops = [AddColumn("t", Column("v", "text", true), missing)],
        fragment = "op 1 (add_column on \"t\"): column \"v\" already exists",
    ),
    (
        ops = [Insert("t", [Any[3, "x"], Any[3, "y"]])],
        fragment = "op 1 (insert on \"t\"): duplicate key (3,) inside one op",
    ),
    (
        ops = [Delete("t", [Any[1], Any[1]])],
        fragment = "op 1 (delete on \"t\"): duplicate key (1,) inside one op",
    ),
    (
        ops = [Insert("t", [Any[4, "x"], Any[3, "y"]])],
        fragment = "op 1 (insert on \"t\"): " *
            "rows are not in primary-key order: (3,) after (4,)",
    ),
    (
        ops = [Update("t", ["v"], [Any[2, "x"], Any[1, "y"]])],
        fragment = "op 1 (update on \"t\"): " *
            "rows are not in primary-key order: (1,) after (2,)",
    ),
    (
        ops = [Delete("t", [Any[2], Any[1]])],
        fragment = "op 1 (delete on \"t\"): " *
            "rows are not in primary-key order: (1,) after (2,)",
    ),
    # The state gate: insert on a present key, update or delete on an absent one.
    (
        ops = [Insert("t", [Any[1, "x"]])],
        fragment = "op 1 (insert on \"t\"): insert names a key that is present: (1,)",
    ),
    (
        ops = [Update("t", ["v"], [Any[9, "x"]])],
        fragment = "op 1 (update on \"t\"): update names a key that is absent: (9,)",
    ),
    (
        ops = [Delete("t", [Any[9]])],
        fragment = "op 1 (delete on \"t\"): delete names a key that is absent: (9,)",
    ),
    (
        ops = [Update("t", ["id"], [Any[1, 5]])],
        fragment = "op 1 (update on \"t\"): update names key column \"id\"",
    ),
    (
        ops = [Update("t", ["v"], [Any[1]])],
        fragment = "op 1 (update on \"t\"): " *
            "update row has 1 cells; expected 1 key cells and 1 values",
    ),
    (
        ops = [Update("t", String[], [Any[1]])],
        fragment = "op 1 (update on \"t\"): update names no non-key column",
    ),
    (
        ops = [
            AddColumn("t", W_NULLABLE, missing),
            Update("t", ["w", "v"], [Any[1, 1.0, "x"]]),
        ],
        fragment = "op 2 (update on \"t\"): " *
            "update columns are not in declaration order: [\"w\", \"v\"]",
    ),
    (
        ops = [Delete("t", [Any[1, 2]])],
        fragment = "op 1 (delete on \"t\"): key (1, 2) has 2 cells; the key has 1",
    ),
    (
        ops = [CreateTable("t", ID_V_SHAPE)],
        fragment = "op 1 (create_table on \"t\"): table \"t\" already exists",
    ),
    (
        ops = [CreateTable("T", ID_V_SHAPE)],
        fragment = "op 1 (create_table on \"T\"): table name \"T\" is not an identifier",
    ),
    (
        ops = [AddColumn("t", Column("_slot", "int64", true), missing)],
        fragment = "op 1 (add_column on \"t\"): " *
            "column name \"_slot\" is not an identifier $COLUMN_NAME_RULE",
    ),
    # A trailing newline is outside the charset.
    (
        ops = [CreateTable("t\n", ID_V_SHAPE)],
        fragment = "op 1 (create_table on \"t\\n\"): " *
            "table name \"t\\n\" is not an identifier",
    ),
    (
        ops = [AddColumn("t", Column("c\n", "int64", true), missing)],
        fragment = "op 1 (add_column on \"t\"): column name \"c\\n\" is not an identifier",
    ),
    (
        ops = [DropTable("nope")],
        fragment = "op 1 (drop_table on \"nope\"): unknown table \"nope\"",
    ),
    (
        ops = [DropColumn("nope", "v")],
        fragment = "op 1 (drop_column on \"nope\"): unknown table \"nope\"",
    ),
]

@testset "apply! runs a record's ops in order" begin
    content = two_row_content()
    @test collect(keys(content)) == ["t"]
    @test isequal(row_of(content["t"], (2,)), Any[2, missing])
    declared = Content("t" => Table(ID_V_SHAPE, [Any[1, "a"], Any[2, missing]], 1))
    @test Model.state_fingerprint(content) == Model.state_fingerprint(declared)
end

@testset "apply! runs every kind of op" begin
    content = two_row_content()
    ops = [
        Update("t", ["v"], [Any[2, "b"]]),
        Delete("t", [Any[1]]),
        AddColumn("t", Column("w", "float64", false), 0.5),
        AddColumn("t", Column("n", "int64", true), missing),
        DropColumn("t", "v"),
        CreateTable("u", Shape([Column("k", "bytes", false)], ["k"])),
        Insert("u", [Any[UInt8[]], Any[UInt8[1]]]),
        DropTable("u"),
    ]
    Ops.apply!(content, as_read(2, ops))
    @test collect(keys(content)) == ["t"]
    @test isequal(row_of(content["t"], (2,)), Any[2, 0.5, missing])
    columns = [
        Column("id", "int64", false), Column("w", "float64", false),
        Column("n", "int64", true),
    ]
    @test content["t"].shape == Shape(columns, ["id"])
end

@testset "apply! returns nothing" begin
    content = two_row_content()
    @test @inferred(Ops.apply!(content, as_read(2, [DropTable("t")]))) === nothing
    @test isempty(content)
end

@testset "apply! stamps the rows an op changes with the record's slot" begin
    content = two_row_content()
    Ops.apply!(content, as_read(5, [Update("t", ["v"], [Any[2, "b"]])]))
    @test content["t"].slots == [1, 5]
end

@testset "apply! refuses a record whose op breaks a rule" begin
    @testset "$(case.fragment)" for case in APPLY_REFUSALS
        record = as_read(2, case.ops)
        content = two_row_content()
        @test_throws MalformedRecordError case.fragment Ops.apply!(content, record)
    end
end

@testset "apply! names the chain, the slot and the op, and gives the next move" begin
    record = as_read(2, [DropColumn("t", "v"), Insert("t", [Any[3.0]])])
    err = (
        @test_throws MalformedRecordError "op 2 (insert on \"t\")" Ops.apply!(
            two_row_content(), record
        )
    ).value
    @test (err.chain_id, err.slot, err.op) == ("AAAQEAYEAUDAOCAJBIFQYDIOB4", 2, 2)
    @test endswith(sprint(showerror, err), NEXT_MOVE_AT_APPLY)
end

@testset "apply! applies the ops before the bad one, and none after it" begin
    content = two_row_content()
    ops = [DropColumn("t", "v"), Insert("t", [Any[1]]), CreateTable("u", ID_V_SHAPE)]
    @test_throws MalformedRecordError "op 2" Ops.apply!(content, as_read(2, ops))
    @test collect(keys(content)) == ["t"]
    @test length(content["t"].shape.columns) == 1
end

@testset "apply! of one op applies it" begin
    content = two_row_content()
    @test @inferred(Ops.apply!(content, Delete("t", [Any[1]]), 2)) === nothing
    @test collect(keys(content["t"].index)) == [(2,)]
end

# The write builder translates the model's error itself, so the op form lets it through.
@testset "apply! of one op throws the model's own error" begin
    content = two_row_content()
    Ops.apply!(content, Delete("t", [Any[1]]), 2)
    @test_throws(
        ModelError, "delete names a key that is absent: (1,)",
        Ops.apply!(content, Delete("t", [Any[1]]), 2)
    )
end

@testset "sort_rows sorts by the typed key order: -0.0 before 0.0, NaN last" begin
    by_first(row) = (row[1],)
    rows = [Any[0.0, 1], Any[-0.0, 2], Any[Inf, 3], Any[NaN, 4]]
    sorted = [Any[-0.0, 2], Any[0.0, 1], Any[Inf, 3], Any[NaN, 4]]
    @test isequal(Ops.sort_rows(rows, by_first), sorted)
end

@testset "determinism vector: the ops reach the frozen state_fingerprint" begin
    content = Content()
    Ops.apply!(content, determinism_record())
    @test bytes2hex(Model.state_fingerprint(content)) == VECTOR_STATE_FINGERPRINT
end

@testset "determinism vector: transaction_hash" begin
    bytes = Ops.encode_record(determinism_record())
    @test length(bytes) == VECTOR_RECORD_SIZE
    @test bytes2hex(Ops.transaction_hash(bytes)) == VECTOR_TRANSACTION_HASH
end

@testset "determinism vector: a second client reads what the first wrote" begin
    vector = determinism_record()
    bytes = Ops.encode_record(vector)
    back = Ops.decode_record(bytes; slot = 2^32)
    @test back == vector
    @test Ops.encode_record(back) == bytes
    content = Content()
    Ops.apply!(content, back)
    @test bytes2hex(Model.state_fingerprint(content)) == VECTOR_STATE_FINGERPRINT
end
