"""
    write_builder(copy)

Return a single-use write builder bound to the copy's head. The copy must have a head
(`sync!(copy)` binds a fresh one) and be live, not pinned.

Examples: test/test_commit_examples.jl
"""
function write_builder(copy::LocalCopy)
    check_open(copy)
    h = copy.head
    h === nothing && throw(ArgumentError(no_head(copy, "write_builder")))
    refuse_pinned(copy, "write_builder")
    pending = Set{String}(name for name in keys(copy.tables) if name ∉ copy.loaded)
    head = (; slot = h.slot, transaction_hash = h.transaction_hash)
    return WriteBuilder(copy.content; copy, head, pending)
end

function no_head(copy, call)
    return "$call: the local copy at $(copy.path) has no head yet; sync!(copy) binds it"
end

# Over 8 lines: the order of refusals and the outcome contract are the API (ADR-0045).
"""
    commit!(w; comment = nothing)

Commit the builder's ops as one transaction record at the slot above the copy's head.
Return `(; slot, transaction_hash, state_fingerprint)`. The builder is spent first, so a
second `commit!` throws `WriteBuilderError`; `comment` is free text the record carries.

Nothing is applied or written when the builder is empty, when the copy moved after the
builder was taken or the chain is past the copy's head (`StaleHeadError`), when the head
does not match its own record, or when an op names a present key on insert or an absent
one on update or delete (`WriteBuilderError`).

Then the record is put with retries and a read-back. Another client's record at the slot
is `LostRaceError` and a gateway's refusal `WriteRefusedError`, never retried. Any other
failure once the put began, the head write included, is `CommitOutcomeUnknownError`
naming our record's transaction hash: after `sync!(copy)`, the commit happened exactly
when `commit_log(copy)` shows that hash at that slot. A failure before the head is
written leaves the copy at its head.

Examples: test/test_commit_examples.jl
"""
function commit!(w::WriteBuilder; comment = nothing)
    spend!(w)
    copy = w.copy
    copy === nothing && throw(WriteBuilderError(; call = "commit!(w)", detail = NO_COPY))
    check_open(copy)
    chain = chain_of(copy, "commit!")
    refuse_pinned(copy, "commit!")
    refuse_unsupported_store(chain, "commit!(w)")
    h = copy.head
    h === nothing && throw(ArgumentError(no_head(copy, "commit!(w)")))
    user = write_author(chain, h.chain_id, h.slot + 1)
    isempty(w.ops) && throw(WriteBuilderError(; call = "commit!(w)", detail = NO_OPS))
    is_same_head(w.head, h) || throw_moved_copy(copy, w.head.slot)
    check_comment(comment)
    check_head_record(copy, chain)
    refuse_taken_slot(copy, chain)
    client = Ops.local_client(; chain.record_host, user)
    put = with_rollback(copy) do
        put_commit_record!(copy, chain, w.ops, client, comment)
    end
    write_commit_head!(copy, chain, put)
    transaction_hash = TransactionHash(put.transaction_hash)
    state_fingerprint = StateFingerprint(put.staged.state_fingerprint)
    return (; put.slot, transaction_hash, state_fingerprint)
end

const NO_COPY = "the builder was not taken over a local copy; use write_builder(copy)"

const NO_OPS = "the builder has no ops; only the genesis record, create_chain's, has none"

function check_comment(comment)
    comment === nothing || comment isa AbstractString ||
        throw(WriteBuilderError(; call = "commit!(w)", detail = not_text(comment)))
    return nothing
end

not_text(comment) = "comment is a $(typeof(comment)), not text"

function is_same_head(taken, h)
    return taken.slot == h.slot && taken.transaction_hash == h.transaction_hash
end

function throw_moved_copy(copy::LocalCopy, slot)
    h = copy.head
    detail = "a sync! moved the local copy after the builder was taken"
    throw(StaleHeadError(; copy.path, h.chain_id, slot, chain_slot = h.slot, detail))
end

# A taken next slot is a stale head, found before anything is applied (ADR-0002).
function refuse_taken_slot(copy::LocalCopy, chain::Chain)
    h = copy.head
    slot_exists(chain, h.slot + 1) || return nothing
    chain_slot = gallop(chain, h.slot + 1)
    detail = "another client committed the slot above the copy's head"
    throw(StaleHeadError(; copy.path, h.chain_id, h.slot, chain_slot, detail))
end

# The five values are the record's inputs; bundling them would only rename them.
"""
    put_commit_record!(copy, chain, ops, client, comment)

Apply `ops` to the copy's model at the next slot, stage the touched tables, and put the
record. Return `(; slot, transaction_hash, staged)` once our record holds the slot.
"""
function put_commit_record!(copy::LocalCopy, chain::Chain, ops, client, comment)
    h = copy.head
    slot = h.slot + 1
    apply_builder_ops!(copy, ops, slot)
    staged = stage!(copy)
    record = commit_record(h, staged, ops, client, comment)
    bytes = Ops.encode_record(record)
    check_record_cap(chain.store, bytes, "commit!(w)")
    found = put_or_unknown!(chain, h.chain_id, slot, bytes)
    found === nothing || throw_lost_race(chain, h.chain_id, slot, found)
    return (; slot, transaction_hash = Ops.transaction_hash(bytes), staged)
end

# The state gate runs through apply's own checks (ADR-0025). The ops apply at the target
# slot: a lost race never re-applies them, because the builder is spent.
function apply_builder_ops!(copy::LocalCopy, ops, slot)
    load_tables!(copy, unique(op.table for op in ops))
    foreach((op, i) -> apply_builder_op!(copy.content, op, i, slot), ops, eachindex(ops))
    return nothing
end

function apply_builder_op!(content, op, i, slot)
    try
        Ops.apply!(content, op, slot)
    catch e
        e isa ModelError || rethrow()
        detail = "op $i ($(Ops.op_name(op)) on $(repr(op.table))): $(e.detail)"
        throw(WriteBuilderError(; call = "commit!(w)", detail))
    end
    return nothing
end

# The five values are the record's fields that the builder does not hold.
function commit_record(h, staged, ops, client, comment)
    chain_id = chain_id_bytes(h.chain_id)
    text = comment === nothing ? nothing : String(comment)
    fingerprint = staged.state_fingerprint
    try
        return Ops.Record(
            chain_id, h.slot + 1, h.transaction_hash, fingerprint, client, text, ops
        )
    catch e
        e isa ModelError || rethrow()
        throw(WriteBuilderError(; call = "commit!(w)", e.detail))
    end
end

"""
    put_or_unknown!(chain, chain_id, slot, bytes)

`put_record_for!`, with every failure that does not prove the record unwritten thrown
as `CommitOutcomeUnknownError` naming our record's hash and the failure as `cause`.
"""
function put_or_unknown!(chain::Chain, chain_id, slot, bytes)
    try
        return put_record_for!(chain, chain_id, slot, bytes)
    catch e
        # Any failure may leave the record landed: an interrupt or a store's own error too.
        e isa Exception || rethrow()
        is_known_unwritten(e) && rethrow()
        transaction_hash = Ops.transaction_hash(bytes)
        detail = "the put of the record failed"
        cause = e
        throw(CommitOutcomeUnknownError(; chain_id, slot, transaction_hash, cause, detail))
    end
end

"""
    is_known_unwritten(e)

Return whether a failure of the put proves the record was not written: a client error
the store refused it with, or one of ChainTables's own refusals.
"""
function is_known_unwritten(e::TransportError)
    return e.status !== nothing && 400 <= e.status < 500 && !retryable(e)
end
is_known_unwritten(::ChainTablesError) = true
is_known_unwritten(e) = false

function throw_lost_race(chain::Chain, chain_id, slot, found)
    transaction_hash = Ops.transaction_hash(found)
    where = location(chain)
    throw(LostRaceError(; location = where, chain_id, slot, transaction_hash))
end

# The record is in the chain, but the head is not: the next sync! applies it onto the
# old head.
function write_commit_head!(copy::LocalCopy, chain::Chain, put)
    chain_id = chain_id_bytes(copy.head.chain_id)
    try
        with_rollback(copy) do
            write_head!(copy, chain_id, put.slot, put.transaction_hash, put.staged)
        end
    catch e
        e isa Exception || rethrow()
        evidence = (;
            copy.head.chain_id, put.slot, put.transaction_hash, landed = true, cause = e,
            detail = "the record is in the chain, but the copy's head was not written",
        )
        throw(CommitOutcomeUnknownError(; evidence...))
    end
    return nothing
end
