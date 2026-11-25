using ChainTables: ChainTables, Ops, head, table
using ChainTables.Ops: Client, Insert, Record

const FORGER = Client(nothing, nothing, "L", "J", 1)

# The id of the chain that `local_copy` is bound to, read from its head file: no API
# name returns it for a local copy.
bound_chain_id(local_copy) = local_copy.head.chain_id

# The bytes of a record for `slot` of the chain of `local_copy`, as a writer outside
# the protocol would put them there. By default it inserts one row into `samples`.
function forged_record(
        local_copy, slot, parent;
        chain_id = ChainTables.chain_id_bytes(bound_chain_id(local_copy)),
        fingerprint = head(local_copy).state_fingerprint.bytes, comment = nothing,
        ops = [Insert("samples", [Any[3, "c", 3.0]])],
    )
    record = Record(chain_id, slot, parent, fingerprint, FORGER, comment, ops)
    return Ops.encode_record(record)
end

# The rows of `samples` at the head of the local copy, in key order.
sample_rows(local_copy) = [Tuple(row) for row in table(local_copy, :samples)]
