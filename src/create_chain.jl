"""
    create_chain(chain)

Create the chain at `chain`'s bucket and prefix and return
`(; chain_id, slot, transaction_hash)`: the new chain id as text, `slot = 0` and the
`TransactionHash` of the genesis record.

It writes the genesis record, with no ops, to slot 0, and nothing else writes that
slot. It returns no local copy: `open` and `sync!` build one.

Throws `LostRaceError` when a chain is there already; the put is never retried. Throws
`UnsupportedStoreError` for a store that is not AWS S3 on a chain without
`assume_first_writer_wins`, and `WriteRefusedError` when a gateway refuses the slot.

Examples: test/test_create_chain_examples.jl
"""
function create_chain(chain::Chain)
    check_supported_store(chain, "create_chain")
    chain_id = rand(UInt8, 16)
    chain_id_text = chain_id_string(chain_id)
    user = write_author(chain, chain_id_text, 0)
    client = Ops.local_client(; chain.record_host, user)
    fingerprint = Model.state_fingerprint(Model.Content())
    record = Ops.Record(chain_id, 0, nothing, fingerprint, client, nothing, Ops.Op[])
    bytes = Ops.encode_record(record)
    check_record_cap(chain.store, bytes, "create_chain(chain)")
    found = put_record(chain, chain_id_text, 0, bytes)
    found === nothing || throw(
        LostRaceError(chain, stored_chain_id(found, 0), 0, found; reason = :chain_exists)
    )
    transaction_hash = TransactionHash(Ops.transaction_hash(bytes))
    return (; chain_id = chain_id_text, slot = 0, transaction_hash)
end

# For setup that runs more than once. It is still a creation: a mistyped prefix makes a
# new chain without a word, which is why `create_chain` itself throws (ADR-0033).
"""
    try_create_chain(chain)

Create the chain as `create_chain` does and return what it returns, or return `nothing`
when a chain is there already.

Every other error of `create_chain` is thrown unchanged.

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
