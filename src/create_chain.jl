# Over 8 lines: create_chain refuses as commit! does, and a caller must know it.
"""
    create_chain(chain)

Create the chain at `chain`'s bucket and prefix: mint its chain id and commit a genesis
record with no ops to slot 0. Return `(; chain_id, slot = 0, transaction_hash)`, not a
local copy: `open` and `sync!` build one.

Throws `LostRaceError` when a chain is already there; it is never retried. Like
`commit!`, it refuses a store that is not AWS S3 unless `assume_first_writer_wins`, and
throws `WriteRefusedError` when a gateway refuses the slot.

Examples: test/test_create_chain_examples.jl
"""
function create_chain(chain::Chain)
    refuse_unsupported_store(chain, "create_chain(chain)")
    id_bytes = rand(UInt8, 16)
    chain_id = chain_id_string(id_bytes)
    user = write_author(chain, chain_id, 0)
    client = Ops.local_client(; chain.record_host, user)
    fingerprint = state_fingerprint(Content())
    record = Ops.Record(id_bytes, 0, nothing, fingerprint, client, nothing, Ops.Op[])
    bytes = Ops.encode_record(record)
    check_record_cap(chain.store, bytes, "create_chain(chain)")
    found = put_record_for!(chain, chain_id, 0, bytes)
    found === nothing || throw_genesis_taken(chain, found)
    transaction_hash = TransactionHash(Ops.transaction_hash(bytes))
    return (; chain_id, slot = 0, transaction_hash)
end

function throw_genesis_taken(chain::Chain, found)
    theirs = try_decode_record(found, 0)
    chain_id = theirs === nothing ? nothing : chain_id_string(theirs.chain_id)
    detail = theirs === nothing ? "a chain whose genesis record is malformed is there" : ""
    transaction_hash = Ops.transaction_hash(found)
    where = location(chain)
    throw(LostRaceError(; location = where, chain_id, slot = 0, transaction_hash, detail))
end

"""
    try_create_chain(chain)

Return what `create_chain(chain)` returns, or `nothing` when a chain is already at
`chain`'s bucket and prefix. For setup that runs more than once; every other error
propagates.

Examples: test/test_create_chain_examples.jl
"""
function try_create_chain(chain::Chain)
    try
        return create_chain(chain)
    catch e
        e isa LostRaceError || rethrow()
        return nothing
    end
end
