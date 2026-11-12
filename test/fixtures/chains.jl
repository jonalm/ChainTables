# Pure helpers for the tests of chains: slot keys and forged records. A test file that
# includes this has `using ChainTables: ChainTables`.

"""
    slotkey(slot, prefix = "p")

The key of `slot` under `prefix`, as `slot_key` writes it.
"""
slotkey(slot, prefix = "p") = prefix * "/" * lpad(string(slot), 12, '0')

"""
    forged_record(chain_id, slot, prev, fingerprint; ops = [], time_ms = 1, lib = "L",
                  comment = nothing)

The bytes of a record built by hand, as a committer outside this client would write it.
"""
function forged_record(
        chain_id, slot, prev, fingerprint;
        ops = ChainTables.Ops.Op[], time_ms = 1, lib = "L", comment = nothing
    )
    client = ChainTables.Ops.Client(nothing, nothing, lib, "J", time_ms)
    record = ChainTables.Ops.Record(chain_id, slot, prev, fingerprint, client, comment, ops)
    return ChainTables.Ops.encode_record(record)
end

"""
    with_comment(bytes, slot, comment)

The bytes of the record `bytes` holds as `slot`, with another comment: a record that
decodes and links like the original but hashes differently.
"""
function with_comment(bytes, slot, comment)
    r = ChainTables.Ops.decode_record(bytes; slot)
    twin = ChainTables.Ops.Record(
        r.chain_id, slot, r.prev_hash, r.state_fingerprint, r.client, comment, r.ops
    )
    return ChainTables.Ops.encode_record(twin)
end

"""
    with_fingerprint(bytes, slot, fingerprint)

The bytes of the record `bytes` holds as `slot`, carrying another state fingerprint: a
committer that lies about the content.
"""
function with_fingerprint(bytes, slot, fingerprint)
    r = ChainTables.Ops.decode_record(bytes; slot)
    lie = ChainTables.Ops.Record(
        r.chain_id, slot, r.prev_hash, fingerprint, r.client, r.comment, r.ops
    )
    return ChainTables.Ops.encode_record(lie)
end

"""
    flipped(bytes)

`bytes` with the last bit flipped: damage that keeps the length.
"""
function flipped(bytes)
    bad = Base.copy(bytes)
    bad[end] ⊻= 0x01
    return bad
end

const SAMPLE_ROWS = [
    (id = 1, label = "a", mass = 1.5), (id = 2, label = "b", mass = missing),
]

"""
    forged_chain(chain_id, last; liars = (), times = s -> 1000 + s)

The record bytes of slots `0:last` of a chain forged by hand, and the true state
fingerprint after each: genesis, a `samples` table at slot 1, then one insert per slot.
Every slot in `liars` carries a wrong fingerprint, `fill(UInt8(slot), 32)`; `times(slot)`
is each record's `client.time_ms`.
"""
function forged_chain(chain_id, last; liars = (), times = s -> 1000 + s)
    columns = [
        ChainTables.Column("id", "int64", false), ChainTables.Column("v", "text", true),
    ]
    shape = ChainTables.Shape(columns, ["id"])
    content = ChainTables.Content()
    records, fingerprints = Vector{UInt8}[], Vector{UInt8}[]
    prev = nothing
    # Each record names the one before it, so the slots are built in order.
    for s in 0:last
        ops = forged_ops(s, shape)
        foreach(op -> ChainTables.Ops.apply!(content, op, s), ops)
        push!(fingerprints, ChainTables.state_fingerprint(content))
        claimed = s in liars ? fill(UInt8(s), 32) : fingerprints[end]
        time_ms, lib = times(s), "L$s"
        bytes = forged_record(chain_id, s, prev, claimed; ops, time_ms, lib)
        push!(records, bytes)
        prev = ChainTables.Ops.transaction_hash(bytes)
    end
    return (; records, fingerprints)
end

function forged_ops(slot, shape)
    slot == 0 && return ChainTables.Ops.Op[]
    slot == 1 && return ChainTables.Ops.Op[ChainTables.Ops.CreateTable("samples", shape)]
    return ChainTables.Ops.Op[ChainTables.Ops.Insert("samples", [Any[slot, string(slot)]])]
end
