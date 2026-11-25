# The amortized rule of ADR-0013.
"""
    Replay

The checkpoints of one replay. Called with each record: it applies the record, and
writes a checkpoint at the last slot and whenever the time spent on apply since the last
checkpoint is over the time that checkpoint took.
"""
mutable struct Replay{C, K}
    const local_copy::LocalCopy{C}
    const last::Int64
    const clock::K  # nanoseconds
    const checkpoints::Vector{Int64}
    applying_ns::Int64
    checkpoint_ns::Int64
end

Replay(local_copy::LocalCopy, last, clock) = Replay(local_copy, last, clock, Int64[], 0, 0)

function (replay::Replay)(slot, record, transaction_hash)
    local_copy = replay.local_copy
    started = replay.clock()
    load_tables!(local_copy, record)
    Ops.apply!(local_copy.content, record)
    replay.applying_ns += replay.clock() - started
    replay.applying_ns > replay.checkpoint_ns || slot == replay.last || return false
    started = replay.clock()
    checkpoint!(local_copy, record, transaction_hash)
    replay.checkpoint_ns = replay.clock() - started
    replay.applying_ns = 0
    push!(replay.checkpoints, slot)
    return false
end

"""
    sync!(local_copy)

Bring the local copy up to the head of its chain and return
`(; applied, slot, transaction_hash)`: the number of records applied, and the head's
slot and `TransactionHash`.

The head's own slot is fetched from the store and held against the head. The records
above it are fetched through the record cache, held against the chain and applied in
slot order, with a checkpoint at the end. Nothing new is `applied = 0`. A fresh copy is
bound to the chain at slot 0.

Throws `RewrittenChainError` when the store contradicts what the copy applied,
`WrongChainError` when the head's slot holds a record of another chain,
`MalformedRecordError` for a record that no client can apply, `ChainNotFoundError` for a
fresh copy when there is no slot 0, and `PinnedCopyError` for a pinned copy. After a
failure the copy is at its last checkpoint.

Examples: test/test_sync_examples.jl
"""
function sync!(local_copy::LocalCopy)
    check_open(local_copy)
    chain = chain_of(local_copy, "sync!")
    check_live(local_copy, "sync!")
    known = fetch_known_slot(local_copy, chain)
    top = fetch_top_slot(chain, known)
    top == -1 && throw(
        ChainNotFoundError(; chain.bucket, chain.prefix, detail = "the call was `sync!`")
    )
    applied = top == known ? Int64(0) : replay!(local_copy, known + 1, top).applied
    head_file = local_copy.head
    transaction_hash = TransactionHash(head_file.transaction_hash)
    return (; applied, head_file.slot, transaction_hash)
end

# The slot that the copy is known to be at on the chain: its head's, once the store
# holds the head's record there, and -1 for a fresh copy.
function fetch_known_slot(local_copy::LocalCopy, chain::Chain)
    head_file = local_copy.head
    head_file === nothing && return Int64(-1)
    fetch_head_slot(local_copy, chain)
    return head_file.slot
end

# Returns the bytes of the head's own slot, fetched from the store past the record
# cache and held against the head (ADR-0014, ADR-0041). A warm cache is no proof that
# the head is still on the chain: the prefix may have been emptied or used again.
function fetch_head_slot(local_copy::LocalCopy, chain::Chain)
    head_file = local_copy.head
    key = slot_key(chain, head_file.slot)
    bytes = fetch_object(chain.store, key)
    bytes === nothing && throw(
        RewrittenChainError(;
            local_copy.path, chain.bucket, chain.prefix, head_file.chain_id,
            head_file.slot, expected = TransactionHash(head_file.transaction_hash),
            detail = "the slot of the local copy's head is absent",
        )
    )
    check_head_bytes(local_copy, chain, bytes)
    write_cached_record(chain, key, bytes)
    return bytes
end

function check_head_bytes(local_copy::LocalCopy, chain::Chain, bytes)
    head_file = local_copy.head
    found = Ops.transaction_hash(bytes)
    found == head_file.transaction_hash && return nothing
    opened = stored_chain_id(bytes, head_file.slot)
    opened === nothing || opened == head_file.chain_id || throw(
        WrongChainError(;
            local_copy.path, chain.bucket, chain.prefix, bound = head_file.chain_id,
            opened, detail = "the record in the slot of the head names the other chain",
        )
    )
    throw(
        RewrittenChainError(;
            local_copy.path, chain.bucket, chain.prefix, head_file.chain_id,
            head_file.slot, expected = TransactionHash(head_file.transaction_hash),
            found = TransactionHash(found),
            detail = "the slot of the local copy's head holds another record",
        )
    )
end

# Applies slots `first:last` of the chain to the copy, each record as `read_forward`
# yields it, and returns `(; applied, checkpoints)` with the slots of the checkpoints.
# A failure leaves the copy at its last checkpoint. `clock` is set only by tests, which
# script it to place the checkpoints.
function replay!(local_copy::LocalCopy, first::Integer, last::Integer; clock = time_ns)
    chain = chain_of(local_copy, "sync!")
    head_file = local_copy.head
    head_file === nothing && first != 0 && throw(
        ArgumentError("a local copy with no head replays from slot 0, not $first")
    )
    replay = Replay(local_copy, last, clock)
    parent = parent_link(head_file)
    with_rollback(local_copy) do
        read_forward(replay, chain, first, last; parent, local_copy.path)
    end
    return (; applied = Int64(last) - Int64(first) + 1, replay.checkpoints)
end

# Runs `f()`. When it throws, the loaded tables are dropped on the way out, so the copy
# stays at its head and loads again from the head's files (ADR-0009).
function with_rollback(f, local_copy::LocalCopy)
    _is_done = false
    try
        result = f()
        _is_done = true
        return result
    finally
        _is_done || discard!(local_copy)
    end
end
