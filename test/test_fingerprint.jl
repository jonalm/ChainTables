using Test
# The state fingerprint is internal; its frozen reference values are the format's spec
# (ADR-0007, ADR-0022), so it is tested here directly.
using ChainTables: ChainTables, CBOR, Column, Content, ModelError, Shape, Table,
    add_table!, append_column!, delete_table_rows!, insert_table_rows!, read_table,
    remove_column!, remove_table!, state_fingerprint, table_hash, update_table_rows!,
    write_table
using SHA: sha256

const SEPARATOR = codeunits("chaintables/v1/fp")
const HASH_A = sha256(b"a")
const HASH_B = sha256(b"b")
const NO_TABLES = Pair{String, Vector{UInt8}}[]

@testset "state_fingerprint of no table hashes an empty array" begin
    @test state_fingerprint(NO_TABLES) == sha256(vcat(SEPARATOR, hex2bytes("80")))
    @test state_fingerprint(Content()) == state_fingerprint(NO_TABLES)
end

@testset "state_fingerprint sorts the tables by name" begin
    expected = sha256(vcat(SEPARATOR, CBOR.encode(Any[Any["a", HASH_A], Any["b", HASH_B]])))
    @test state_fingerprint(["b" => HASH_B, "a" => HASH_A]) == expected
    @test state_fingerprint(["a" => HASH_A, "b" => HASH_B]) == expected
    @test state_fingerprint(["a" => HASH_A]) != expected
end

@testset "state_fingerprint refuses a duplicate name or a short hash" begin
    @test_throws(
        ModelError, "duplicate table name \"a\"",
        state_fingerprint(["a" => HASH_A, "a" => HASH_B]),
    )
    @test_throws(
        ModelError, "table_hash of \"a\" is 1 bytes",
        state_fingerprint(["a" => UInt8[0]]),
    )
end

@testset "state_fingerprint of a content hashes every table" begin
    c = Content()
    add_table!(c, "b", Shape([Column("k", "int64", false)], ["k"]))
    add_table!(c, "a", Shape([Column("k", "text", false)], ["k"]))
    pairs = ["a" => table_hash(c["a"]), "b" => table_hash(c["b"])]
    @test state_fingerprint(c) == state_fingerprint(pairs)
    @test length(state_fingerprint(c)) == 32
end

const SIGNBIT_NAN = reinterpret(Float64, 0xfff8000000000000)
const SLOT = 2^32

const MEASUREMENTS = Shape(
    [
        Column("sample", "text", false), Column("run", "int64", false),
        Column("value", "float64", true), Column("payload", "bytes", false),
    ], ["sample", "run"]
)
const POINTS = Shape([Column("x", "float64", false), Column("label", "text", true)], ["x"])

# One fixed op sequence: -0.0, 2^63-1, typemin, a non-ASCII text key, a sign-bit NaN,
# ±Inf, null, an empty table, a key-only table, a dropped table, add and drop column,
# update and delete. Every row is stamped with slot 2^32, CBOR's widest integer form.
function determinism_content()
    c = Content()
    add_table!(c, "measurements", MEASUREMENTS)
    # Text keys by UTF-8 bytes: a < z < ß < água < 水.
    insert_table_rows!(
        c["measurements"], [
            Any["a", typemin(Int64), -Inf, UInt8[0]],
            Any["z", -1, 0.1 + 0.2, UInt8[]],
            Any["z", 0, missing, UInt8[]],
            Any["ß", typemax(Int64), Inf, UInt8[1, 2, 3]],
            Any["água", 2, SIGNBIT_NAN, UInt8[0x00, 0xff]],
            Any["水", 1, -0.0, UInt8[]],
        ], SLOT
    )
    add_points!(c)
    add_table!(
        c, "empty", Shape([Column("k", "int64", false), Column("v", "text", true)], ["k"]),
    )
    add_table!(c, "set", Shape([Column("k", "bytes", false)], ["k"]))
    insert_table_rows!(
        c["set"], [Any[UInt8[]], Any[UInt8[1]], Any[UInt8[1, 2]], Any[UInt8[2]]], SLOT,
    )
    add_table!(c, "gone", Shape([Column("k", "int64", false)], ["k"]))
    insert_table_rows!(c["gone"], [Any[1]], SLOT)
    remove_table!(c, "gone")
    return c
end

function add_points!(c)
    add_table!(c, "points", POINTS)
    points = c["points"]
    insert_table_rows!(
        points, [
            Any[-Inf, "-inf"], Any[-0.0, "negative zero"], Any[0.0, "zero"],
            Any[5.0e-324, "denormal"], Any[1.5, "one and a half"], Any[2.0, missing],
            Any[1.0e300, "big"], Any[Inf, "inf"], Any[NaN, "nan"],
        ], SLOT
    )
    append_column!(points, Column("weight", "float64", false), 2.0, SLOT)
    append_column!(points, Column("tag", "text", true), missing, SLOT)
    rows = [Any[-0.0, missing, -1.0], Any[NaN, "not a number", 0.5]]
    update_table_rows!(points, ["label", "weight"], rows, SLOT)
    delete_table_rows!(points, [(1.5,), (Inf,)])
    remove_column!(points, "tag", SLOT)
    return nothing
end

# Frozen: a changed literal is a chain break and needs an ADR. The same sequence as one
# record, with its frozen transaction hash, is in test/test_ops_apply.jl.
const FROZEN_TABLE_HASHES = [
    (
        name = "empty",
        hex = "f78d134fe73b9403444695cf955c149e2e961f4ae02b7496162f557782d9b8d1",
    ),
    (
        name = "measurements",
        hex = "ef00f339a20238c902377ee313e01430812356fb6f1ee3f6849ff69ae6fa6577",
    ),
    (
        name = "points",
        hex = "5ba50802dfba19a558d25385543040bae02b23bf8f13968959685915cd7ddf11",
    ),
    (
        name = "set",
        hex = "3bda277249c76f61778ec932434d6b7084966ada520702842c88966c518bfdf8",
    ),
]
const FROZEN_FINGERPRINT =
    "331e990a50abbbb3415e34eed0feb7fdc6549530bad76d3c8579c7ee086054df"

const DETERMINISM_CONTENT = determinism_content()

@testset "the determinism vector leaves four tables" begin
    @test sort(collect(keys(DETERMINISM_CONTENT))) == [
        "empty", "measurements", "points", "set",
    ]
end

@testset "the determinism vector table $(case.name) hash" for case in FROZEN_TABLE_HASHES
    @test bytes2hex(table_hash(DETERMINISM_CONTENT[case.name])) == case.hex
end

@testset "the determinism vector's state_fingerprint is the frozen literal" begin
    @test bytes2hex(state_fingerprint(DETERMINISM_CONTENT)) == FROZEN_FINGERPRINT
end

function from_table_files(c)
    return Content(name => read_table(IOBuffer(sprint(write_table, t))) for (name, t) in c)
end

@testset "the determinism vector read from its table files keeps its fingerprint" begin
    read_back = from_table_files(DETERMINISM_CONTENT)
    @test bytes2hex(state_fingerprint(read_back)) == FROZEN_FINGERPRINT
end
