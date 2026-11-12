# Over 8 lines: each refusal names what the caller can do about it.
"""
    sync!(copy)

Bring the local copy up to the chain's head: check the head's own slot against the store,
find the chain's head, and replay the records after the copy's, checkpointing on the way.
Return `(; applied, slot, transaction_hash)`; nothing new is `applied = 0`.

Throws `RewrittenChainError` or `WrongChainError` when the store contradicts the head,
`ChainNotFoundError` for a copy with no head and no slot 0, `PinnedCopyError` for a
pinned copy, and `MalformedRecordError` for a record no client can apply. A failed sync
leaves the copy at its last checkpoint.

Examples: test/test_sync_examples.jl
"""
function sync!(copy::LocalCopy)
    check_open(copy)
    chain = chain_of(copy, "sync!")
    refuse_pinned(copy, "sync!")
    h = copy.head
    h === nothing || check_head_slot(copy, chain)
    lo = h === nothing ? Int64(-1) : h.slot
    top = gallop(chain, lo)
    top == lo && h === nothing &&
        throw(ChainNotFoundError(; chain.bucket, chain.prefix, call = "sync!(copy)"))
    applied = top == lo ? Int64(0) : replay!(copy, lo + 1, top).applied
    transaction_hash = TransactionHash(copy.head.transaction_hash)
    return (; applied, slot = copy.head.slot, transaction_hash)
end

"""
    check_head_slot(copy, chain)

Fetch the head's own slot from the store, past the record cache, and return its bytes
once they hash to the head's transaction hash. A warm cache is no proof the
head is still on the chain. Throws `RewrittenChainError` when the slot is absent or holds
another record, `WrongChainError` when that record names another chain.
"""
function check_head_slot(copy::LocalCopy, chain::Chain)
    h = copy.head
    key = slot_key(chain, h.slot)
    bytes = fetch_object(chain.store, key)
    expected = h.transaction_hash
    detail = "the head's slot is absent at $(location(chain))"
    bytes === nothing &&
        throw(RewrittenChainError(; h.chain_id, h.slot, expected, detail))
    th = Ops.transaction_hash(bytes)
    th == expected || throw_other_head_record(copy, chain, bytes)
    heal_record!(chain, key, bytes)
    return bytes
end

function throw_other_head_record(copy::LocalCopy, chain::Chain, bytes)
    h = copy.head
    theirs = try_decode_record(bytes, h.slot)
    opened = theirs === nothing ? h.chain_id : chain_id_string(theirs.chain_id)
    opened == h.chain_id ||
        throw(WrongChainError(; copy.path, bound = h.chain_id, opened))
    detail = "the head's slot at $(location(chain)) holds a record the copy did not apply"
    expected, found = h.transaction_hash, Ops.transaction_hash(bytes)
    throw(RewrittenChainError(; h.chain_id, h.slot, expected, found, detail))
end

"""
    check_head_record(copy, chain)

Return the head's own record once `check_head_slot` passes and its state fingerprint is
the head's: the pre-check before a commit builds on the head. Throws
`FingerprintMismatchError` otherwise.
"""
function check_head_record(copy::LocalCopy, chain::Chain)
    h = copy.head
    record = Ops.decode_record(check_head_slot(copy, chain); slot = h.slot)
    record.state_fingerprint == h.state_fingerprint && return record
    evidence = (;
        h.chain_id, h.slot, expected = record.state_fingerprint,
        computed = h.state_fingerprint,
        record_client = client_version(record.client), this_client = written_by_here(),
        detail = "the head of the local copy at $(copy.path) disagrees with its own record",
    )
    throw(FingerprintMismatchError(; evidence...))
end

"""
    Replay(copy, last, clock)

One replay's checkpoint schedule, called as `replay(slot, record, transaction_hash)` for
each record: apply it, and checkpoint at `last` and whenever the apply time since the last
checkpoint exceeds that checkpoint's duration, both on `clock` in nanoseconds.
"""
mutable struct Replay{C <: LocalCopy, K}
    const copy::C
    const last::Int64
    const clock::K
    applying_ns::Int64
    last_checkpoint_ns::Int64
    const checkpoints::Vector{Int64}
end

Replay(copy::LocalCopy, last, clock) = Replay(copy, Int64(last), clock, 0, 0, Int64[])

function (replay::Replay)(s, record, th)
    copy = replay.copy
    t0 = replay.clock()
    load_tables!(copy, record)
    Ops.apply!(copy.content, record)
    replay.applying_ns += replay.clock() - t0
    (replay.applying_ns > replay.last_checkpoint_ns || s == replay.last) &&
        checkpoint_at!(replay, s, record, th)
    return false
end

function checkpoint_at!(replay::Replay, s, record, th)
    t1 = replay.clock()
    fingerprint = record.state_fingerprint
    checkpoint!(replay.copy, record.chain_id, s, th, fingerprint; client = record.client)
    replay.last_checkpoint_ns = replay.clock() - t1
    replay.applying_ns = 0
    push!(replay.checkpoints, s)
    return nothing
end

# `clock` is a dependency: a test scripts it to place the checkpoints.
"""
    replay!(copy, first, last; clock = time_ns)

Apply slots `first:last` of the chain to the copy as `read_forward` yields them, and
checkpoint by the amortized rule (`Replay`). Return `(; applied, checkpoints)`, the slots
checkpointed. A failure drops the model, so the copy stays at its last checkpoint.
"""
function replay!(copy::LocalCopy, first::Integer, last::Integer; clock = time_ns)
    chain = chain_of(copy, "sync!")
    copy.head === nothing && first != 0 &&
        throw(ArgumentError("a copy with no head replays from slot 0, not $first"))
    replay = Replay(copy, last, clock)
    parent = parent_link(copy)
    with_rollback(copy) do
        read_forward(replay, chain, first, last; parent)
    end
    return (; applied = Int64(last) - Int64(first) + 1, replay.checkpoints)
end

function parent_link(copy::LocalCopy)
    h = copy.head
    h === nothing && return nothing
    return ParentLink(h.transaction_hash, h.chain_id, "the local copy at $(copy.path)")
end
