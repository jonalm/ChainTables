using ChainTables: Model
using ChainTables.Model: Column, Content, Shape

# The determinism vector (ADR-0022): one fixed sequence of the model's primitives, and
# the literal hashes it gives in every cell of the CI matrix. The literals were minted
# from the first green run and are frozen: a change to one is a chain break and needs
# an ADR. Every row carries the row slot 2^32, so the slot takes CBOR's widest integer
# form (ADR-0032). The sequence covers -0.0, 2^63-1, typemin, a non-ASCII text key, a
# NaN with its sign bit set, ±Inf, null, an empty table, a key-only table, a dropped
# table, added and dropped columns, an update and a delete. The rows are in typed key
# order: text keys by UTF-8 bytes, a < z < ß < água < 水.

const VECTOR_SIGNBIT_NAN = reinterpret(Float64, 0xfff8000000000000)

const VECTOR_TABLE_HASHES = [
    "empty" => "f78d134fe73b9403444695cf955c149e2e961f4ae02b7496162f557782d9b8d1",
    "measurements" => "ef00f339a20238c902377ee313e01430812356fb6f1ee3f6849ff69ae6fa6577",
    "points" => "5ba50802dfba19a558d25385543040bae02b23bf8f13968959685915cd7ddf11",
    "set" => "3bda277249c76f61778ec932434d6b7084966ada520702842c88966c518bfdf8",
]

const VECTOR_STATE_FINGERPRINT =
    "331e990a50abbbb3415e34eed0feb7fdc6549530bad76d3c8579c7ee086054df"

function determinism_content()
    c = Content()
    Model.create_table!(
        c,
        "measurements",
        Shape(
            [
                Column("sample", "text", false),
                Column("run", "int64", false),
                Column("value", "float64", true),
                Column("payload", "bytes", false),
            ],
            ["sample", "run"],
        ),
    )
    Model.insert_rows!(
        c["measurements"],
        [
            Any["a", typemin(Int64), -Inf, UInt8[0]],
            Any["z", -1, 0.1 + 0.2, UInt8[]],
            Any["z", 0, missing, UInt8[]],
            Any["ß", typemax(Int64), Inf, UInt8[1, 2, 3]],
            Any["água", 2, VECTOR_SIGNBIT_NAN, UInt8[0x00, 0xff]],
            Any["水", 1, -0.0, UInt8[]],
        ],
        2^32,
    )
    Model.create_table!(
        c,
        "points",
        Shape([Column("x", "float64", false), Column("label", "text", true)], ["x"]),
    )
    Model.insert_rows!(
        c["points"],
        [
            Any[-Inf, "-inf"],
            Any[-0.0, "negative zero"],
            Any[0.0, "zero"],
            Any[5.0e-324, "denormal"],
            Any[1.5, "one and a half"],
            Any[2.0, missing],
            Any[1.0e300, "big"],
            Any[Inf, "inf"],
            Any[NaN, "nan"],
        ],
        2^32,
    )
    Model.add_column!(c["points"], Column("weight", "float64", false), 2.0, 2^32)
    Model.add_column!(c["points"], Column("tag", "text", true), missing, 2^32)
    Model.update_rows!(
        c["points"],
        ["label", "weight"],
        [Any[-0.0, missing, -1.0], Any[NaN, "not a number", 0.5]],
        2^32,
    )
    Model.delete_rows!(c["points"], [(1.5,), (Inf,)])
    Model.drop_column!(c["points"], "tag", 2^32)
    Model.create_table!(
        c,
        "empty",
        Shape([Column("k", "int64", false), Column("v", "text", true)], ["k"]),
    )
    Model.create_table!(c, "set", Shape([Column("k", "bytes", false)], ["k"]))
    Model.insert_rows!(
        c["set"],
        [Any[UInt8[]], Any[UInt8[1]], Any[UInt8[1, 2]], Any[UInt8[2]]],
        2^32,
    )
    Model.create_table!(c, "gone", Shape([Column("k", "int64", false)], ["k"]))
    Model.insert_rows!(c["gone"], [Any[1]], 2^32)
    Model.drop_table!(c, "gone")
    return c
end
