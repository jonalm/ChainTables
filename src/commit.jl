const NO_OPS = "commit!(w): the builder has no ops; a record after genesis carries at " *
    "least one, and genesis is create_chain's. Add ops, or do not commit."

const DRIFTED = "the local copy drifted from the chain after its head was applied, so " *
    "nothing is committed onto it"

const HEAD_NOT_WRITTEN = "the record is in the chain, and the head of the local copy " *
    "was not written"

"""
    write_builder(local_copy)

Return a `WriteBuilder` bound to the head of the local copy, for one `commit!`.

The copy has a head, which `sync!` gives a fresh copy, and is not pinned. Throws
`ArgumentError` for a copy with no head and `PinnedCopyError` for a pinned one.

Examples: test/test_commit_examples.jl
"""
function write_builder(local_copy::LocalCopy)
    check_open(local_copy)
    head_file = bound_head(local_copy)
    check_live(local_copy, "write_builder")
    return WriteBuilder(local_copy, head_file)
end

# Over 8 lines: each error is another answer to "did the commit happen".
"""
    commit!(w; comment = nothing)

Commit the ops of the write builder as one transaction record at the slot above the
head of its local copy, and return `(; slot, transaction_hash, state_fingerprint)`.

The builder is spent by the call, whatever comes of it. The ops are applied to the
copy's tables, the record is put to the slot only if the slot is empty, and then the
head of the local copy is written. `comment` is free text that the record carries.

Throws `WriteBuilderError` for a spent or empty builder, an op that the tables refuse,
or a record over the cap; `StaleHeadError` when the builder is behind the copy or the
copy behind the chain; `LostRaceError` when another client's record took the slot;
`WriteRefusedError` when a gateway refuses the record. In each of these nothing was
committed, and the copy is at its head. Nothing is retried.

Throws `CommitOutcomeUnknownError` for any other failure after the put began. After
`sync!`, the commit happened exactly when `commit_log` shows the error's
`transaction_hash` at its `slot`.

Also throws `PinnedCopyError`, `UnsupportedStoreError`, and what `sync!` throws for a
head that the store contradicts.

Examples: test/test_commit_examples.jl
"""
function commit!(w::WriteBuilder; comment = nothing)
    spend!(w)
    local_copy = w.copy
    check_open(local_copy)
    chain = chain_of(local_copy, "commit!")
    check_live(local_copy, "commit!")
    refuse_unsupported_store(chain, "commit!(w)")
    head_file = bound_head(local_copy)
    # The author is fetched before anything is applied (ADR-0028).
    user = write_author(chain, head_file.chain_id, head_file.slot + 1)
    check_builder(w, head_file, comment)
    check_head_record(local_copy, chain, DRIFTED)
    check_next_slot_empty(local_copy, chain)
    return with_rollback(() -> put_and_write_head!(w, chain, user, comment), local_copy)
end

function check_builder(w::WriteBuilder, head_file::Head, comment)
    isempty(w.ops) && throw(WriteBuilderError(; detail = NO_OPS))
    is_same_head(w.head, head_file) || throw(
        StaleHeadError(;
            w.copy.path, head_file.chain_id, slot = w.head.slot,
            chain_slot = head_file.slot, reason = :builder_behind_copy,
        )
    )
    comment isa Union{Nothing, AbstractString} || throw(
        WriteBuilderError(;
            detail = "commit!(w): comment is a $(typeof(comment)), not text",
        )
    )
    return nothing
end

function is_same_head(a::Head, b::Head)
    return a.slot == b.slot && a.transaction_hash == b.transaction_hash
end

# The pre-check of a commit (ADR-0007, ADR-0014): the head's own slot is fetched from
# the store and held against the head, and then the fingerprint of its record against
# the head's. `detail` says what the mismatch means to the caller.
function check_head_record(local_copy::LocalCopy, chain::Chain, detail)
    head_file = local_copy.head
    bytes = fetch_head_slot(local_copy, chain)
    record = Ops.decode_record(bytes; slot = head_file.slot)
    record.state_fingerprint == head_file.state_fingerprint || throw(
        FingerprintMismatchError(;
            local_copy.path, head_file.chain_id, head_file.slot,
            expected = StateFingerprint(record.state_fingerprint),
            computed = StateFingerprint(head_file.state_fingerprint),
            record_client = (; record.client.lib, record.client.julia),
            this_client = written_by_here(), detail,
        )
    )
    return nothing
end

# The preflight (ADR-0002): a taken next slot is a stale head, found before anything is
# applied.
function check_next_slot_empty(local_copy::LocalCopy, chain::Chain)
    head_file = local_copy.head
    next = head_file.slot + 1
    has_slot(chain, next) && throw(
        StaleHeadError(;
            local_copy.path, head_file.chain_id, head_file.slot,
            chain_slot = fetch_top_slot(chain, next), reason = :copy_behind_chain,
        )
    )
    return nothing
end

function put_and_write_head!(w::WriteBuilder, chain::Chain, user, comment)
    local_copy = w.copy
    head_file = local_copy.head
    slot = head_file.slot + 1
    load_tables!(local_copy, unique(op.table for op in w.ops))
    foreach(index -> apply_op!(local_copy, w.ops, index), eachindex(w.ops))
    staged = write_staged_tables(local_copy)
    client = Ops.local_client(; chain.record_host, user)
    bytes = Ops.encode_record(builder_record(w, staged, client, comment))
    check_record_cap(chain.store, bytes, "commit!(w)")
    transaction_hash = TransactionHash(Ops.transaction_hash(bytes))
    put_commit_record(chain, head_file.chain_id, slot, bytes)
    write_commit_head!(local_copy, chain, transaction_hash, staged)
    state_fingerprint = StateFingerprint(staged.state_fingerprint)
    return (; slot, transaction_hash, state_fingerprint)
end

# The state gate (ADR-0025): an insert on a present key, or an update or a delete on an
# absent one, is refused through the checks that apply runs. The op is stamped with the
# slot that the record is put to.
function apply_op!(local_copy::LocalCopy, ops, index)
    op = ops[index]
    try
        Ops.apply!(local_copy.content, op, local_copy.head.slot + 1)
    catch e
        e isa Model.ModelError || rethrow()
        what = "op $index ($(Ops.op_name(op)) on $(repr(op.table)))"
        throw(WriteBuilderError(; detail = "commit!(w): $what: $(e.detail)"))
    end
    return nothing
end

function builder_record(w::WriteBuilder, staged, client, comment)
    head_file = w.copy.head
    chain_id = chain_id_bytes(head_file.chain_id)
    slot = head_file.slot + 1
    parent = head_file.transaction_hash
    fingerprint = staged.state_fingerprint
    text = comment === nothing ? nothing : String(comment)
    ops = w.ops
    try
        return Ops.Record(chain_id, slot, parent, fingerprint, client, text, ops)
    catch e
        e isa Model.ModelError || rethrow()
        throw(WriteBuilderError(; detail = "commit!(w): $(e.detail)"))
    end
end

function put_commit_record(chain::Chain, chain_id, slot, bytes)
    transaction_hash = TransactionHash(Ops.transaction_hash(bytes))
    # style: catch-all any failure after the put began leaves the outcome unknown (ADR-0045)
    found = try
        put_record(chain, chain_id, slot, bytes)
    catch e
        e isa Exception || rethrow()
        is_known_unwritten(e) || throw(
            CommitOutcomeUnknownError(;
                chain.bucket, chain.prefix, chain_id, slot, transaction_hash, cause = e,
            )
        )
        rethrow()
    end
    found === nothing ||
        throw(LostRaceError(chain, chain_id, slot, found; reason = :slot_taken))
    return nothing
end

# Whether a failure of the put says that the record was not written (ADR-0045).
# ChainTables' own errors do: a gateway's refusal, a rewritten chain.
is_known_unwritten(::ChainTablesError) = true

# A client error of the store that is not retried does too.
function is_known_unwritten(e::TransportError)
    status = e.status
    return status !== nothing && 400 <= status < 500 && !is_retryable(e)
end

# Anything else leaves the outcome unknown: a failed read-back, an interrupt.
is_known_unwritten(::Exception) = false

# The local commit point (ADR-0009). The record is in the chain by now, so a head that
# is not written leaves the next `sync!` to apply the record onto the old head.
function write_commit_head!(local_copy::LocalCopy, chain::Chain, transaction_hash, staged)
    head_file = local_copy.head
    slot = head_file.slot + 1
    new_head = next_head(head_file.chain_id, slot, transaction_hash.bytes, staged)
    # style: catch-all whatever stops the head write, the record has landed (ADR-0045)
    try
        write_head!(local_copy, new_head)
    catch e
        e isa Exception || rethrow()
        throw(
            CommitOutcomeUnknownError(;
                chain.bucket, chain.prefix, head_file.chain_id, slot, transaction_hash,
                landed = true, cause = e, detail = HEAD_NOT_WRITTEN,
            )
        )
    end
    return nothing
end
