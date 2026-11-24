using ChainTables: Model, Ops
using ChainTables.Model: Column, Content, Shape
using ChainTables.Ops: Client, CreateTable, Insert, Record

const RECORD_CHAIN_ID = UInt8.(0:15)
const RECORD_FINGERPRINT = fill(0xaa, 32)
const RECORD_PARENT = fill(0xbb, 32)
const RECORD_CLIENT = Client(nothing, nothing, "L", "J", 1)
const ID_V_SHAPE = Shape([Column("id", "int64", false), Column("v", "text", true)], ["id"])

function record_at(slot, ops)
    parent = slot == 0 ? nothing : RECORD_PARENT
    return Record(
        RECORD_CHAIN_ID, slot, parent, RECORD_FINGERPRINT, RECORD_CLIENT, nothing, ops
    )
end

# A record as a second client meets it: through its bytes.
as_read(slot, ops) = Ops.decode_record(Ops.encode_record(record_at(slot, ops)); slot)

# The content after slot 1: table "t" with the rows [1, "a"] and [2, missing].
function two_row_content()
    content = Content()
    ops = [CreateTable("t", ID_V_SHAPE), Insert("t", [Any[1, "a"], Any[2, missing]])]
    Ops.apply!(content, as_read(1, ops))
    return content
end
