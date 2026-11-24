using ChainTables: Model, Ops
using ChainTables.Model: Column, Shape
using ChainTables.Ops: AddColumn, Client, CreateTable, Delete, DropColumn, DropTable,
    Insert, Record, Update

# The determinism vector as one record (ADR-0022): the sequence of determinism_vector.jl
# as ops, at slot 2^32 with a prev_hash, since genesis carries no ops (ADR-0032). The
# client fields are literals, not this machine's. The transaction hash was minted from
# the first green run and is frozen: a change to it is a chain break and needs an ADR.

const VECTOR_TRANSACTION_HASH =
    "ba70e47ecaf045d61d56bd2f937e80356e4850331a59add52d49e5771dbce16a"
const VECTOR_RECORD_SIZE = 1278

by_key(shape) = row -> Model.key_of(shape, row)
first_cell(row) = (row[1],)
sorted_by(rows, keyof) = sort(rows; by = keyof)

function determinism_record()
    measurements = Shape(
        [
            Column("sample", "text", false),
            Column("run", "int64", false),
            Column("value", "float64", true),
            Column("payload", "bytes", false),
        ],
        ["sample", "run"],
    )
    points = Shape([Column("x", "float64", false), Column("label", "text", true)], ["x"])
    ops = Ops.Op[
        CreateTable("measurements", measurements),
        Insert(
            "measurements",
            sorted_by(
                [
                    Any["水", 1, -0.0, UInt8[]],
                    Any["água", 2, VECTOR_SIGNBIT_NAN, UInt8[0x00, 0xff]],
                    Any["ß", typemax(Int64), Inf, UInt8[1, 2, 3]],
                    Any["a", typemin(Int64), -Inf, UInt8[0]],
                    Any["z", 0, missing, UInt8[]],
                    Any["z", -1, 0.1 + 0.2, UInt8[]],
                ],
                by_key(measurements),
            ),
        ),
        CreateTable("points", points),
        Insert(
            "points",
            sorted_by(
                [
                    Any[-0.0, "negative zero"],
                    Any[0.0, "zero"],
                    Any[NaN, "nan"],
                    Any[Inf, "inf"],
                    Any[-Inf, "-inf"],
                    Any[1.5, "one and a half"],
                    Any[1.0e300, "big"],
                    Any[5.0e-324, "denormal"],
                    Any[2.0, missing],
                ],
                by_key(points),
            ),
        ),
        AddColumn("points", Column("weight", "float64", false), 2.0),
        AddColumn("points", Column("tag", "text", true), missing),
        Update(
            "points",
            ["label", "weight"],
            sorted_by(
                [Any[NaN, "not a number", 0.5], Any[-0.0, missing, -1.0]],
                first_cell,
            ),
        ),
        Delete("points", sorted_by([Any[1.5], Any[Inf]], first_cell)),
        DropColumn("points", "tag"),
        CreateTable(
            "empty",
            Shape([Column("k", "int64", false), Column("v", "text", true)], ["k"]),
        ),
        CreateTable("set", Shape([Column("k", "bytes", false)], ["k"])),
        Insert(
            "set",
            sorted_by(
                [Any[UInt8[2]], Any[UInt8[1, 2]], Any[UInt8[1]], Any[UInt8[]]],
                first_cell,
            ),
        ),
        CreateTable("gone", Shape([Column("k", "int64", false)], ["k"])),
        Insert("gone", [Any[1]]),
        DropTable("gone"),
    ]
    frozen_fp = hex2bytes(VECTOR_STATE_FINGERPRINT)
    vector = Record(
        UInt8.(0:15),
        2^32,
        UInt8.(0:31),
        frozen_fp,
        Client("ci", "ci", "ChainTables 0.1.0", "1.10.0", 1700000000000),
        "determinism vector",
        ops,
    )
    return vector
end
