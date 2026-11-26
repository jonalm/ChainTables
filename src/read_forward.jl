# How many stored bytes of cached records a read keeps decoded while it waits for the
# store to vouch for them. Records past it are read again once vouched for.
const PENDING_BYTES = 64 * 2^20

const SLOT_VANISHED = "the slot was there when head discovery probed it and is absent now"

const NAMED_BY_SLOT_ABOVE = "the store does not hold the record that the slot above names"

"""
    ParentLink

What a read that starts above slot 0 holds for the slot below its first: that record's
transaction hash, and the chain id.
"""
struct ParentLink
    transaction_hash::Vector{UInt8}
    chain_id::String
end

parent_link(::Nothing) = nothing
parent_link(head_file::Head) = ParentLink(head_file.transaction_hash, head_file.chain_id)

"""
    PendingRecord

A checked record from the record cache that waits for the store to vouch for it.
"""
struct PendingRecord
    slot::Int64
    transaction_hash::Vector{UInt8}
    record::Union{Nothing, Ops.Record}  # `nothing` when the read did not keep it
    size::Int  # what it counts against `keep_bytes`, 0 when it was not kept
end

"""
    ForwardRead

The state of one `read_forward`: the chain id, the last record that the store vouched
for, and the run of cached records that waits to be vouched for.
"""
mutable struct ForwardRead{C <: Chain, F}
    const chain::C
    const f::F
    const last::Int64
    const keep_bytes::Int
    const path::Union{Nothing, String}  # the local copy that is read for, as evidence
    chain_id::Union{Nothing, String}  # slot 0's, until then `nothing`
    anchor::Union{Nothing, Vector{UInt8}}  # the hash of the last record vouched for
    const pending::Vector{PendingRecord}
    pending_bytes::Int
    stopped::Bool  # `f` returned `true`
end

function ForwardRead(f, chain::Chain, last; parent, path, keep_bytes)
    chain_id = parent === nothing ? nothing : parent.chain_id
    anchor = parent === nothing ? nothing : parent.transaction_hash
    return ForwardRead(
        chain, f, Int64(last), Int(keep_bytes), path, chain_id, anchor, PendingRecord[],
        0, false,
    )
end

# Over 8 lines: which records are yielded, and on whose word, is the contract
# (ADR-0040). `keep_bytes` is set only by tests: the second read of a record is reached
# in production only with over 64 MiB of records waiting.
"""
    read_forward(f, chain, first, last; parent = nothing, path = nothing)

Call `f(slot, record, transaction_hash)` for the records of slots `first:last` in slot
order, and stop early when `f` returns `true`.

Records are fetched through the record cache, `read_ahead` ahead. Each is checked: it
decodes, carries the chain id (`parent`'s, else slot 0's) and names the hash of its
parent. `parent` is given exactly when `first > 0`. `path` is the local copy that is
read for, as evidence.

The record cache is not the chain's word. A record that the store returned is yielded
once checked. A cached one is yielded only once a record that the store returned names
it, directly or through a run of cached records that name each other. Slot 0 and slot
`last` come from the store, so every read starts and ends vouched for. A check that
fails is asked of the store: first the slot's own bytes, then the cached run below it,
from the top down, until the store agrees with the cache. The store's bytes replace a
cache file that differs once they pass.

Only the store's bytes throw `RewrittenChainError` or `MalformedRecordError`, and what
the store vouched for below the failing slot is yielded first.
"""
function read_forward(
        f, chain::Chain, first::Integer, last::Integer;
        parent::Union{Nothing, ParentLink} = nothing, path = nothing,
        keep_bytes = PENDING_BYTES,
    )
    (parent === nothing) == (first == 0) || throw(
        ArgumentError("a read has a parent exactly when it starts above slot 0")
    )
    read = ForwardRead(f, chain, last; parent, path, keep_bytes)
    tasks = Dict{Int64, Task}()
    try
        read_slots!(read, tasks, Int64(first))
    finally
        # Fetches ahead of an early stop or a failure land before the read returns.
        foreach(wait_landed, values(tasks))
    end
    return nothing
end

function wait_landed(task::Task)
    try
        wait(task)
    catch e
        e isa TaskFailedException || rethrow()
    end
    return nothing
end

function read_slots!(read::ForwardRead, tasks, first)
    for slot in first:read.last
        start_fetches!(tasks, read, slot)
        bytes, cached = task_result(pop!(tasks, slot))
        accept_slot!(read, slot, bytes, cached)
        read.stopped && return nothing
    end
    isempty(read.pending) || throw(
        AssertionError("BUG: the last slot came from the store, and a cached run waits")
    )
    return nothing
end

# `tasks` holds the slots from `slot` on that are fetched and not yet read.
function start_fetches!(tasks, read::ForwardRead, slot)
    ahead = min(read.last, slot + read.chain.read_ahead - 1)
    for next in (slot + length(tasks)):ahead
        tasks[next] = @async fetch_slot(read, next)
    end
    return nothing
end

function fetch_slot(read::ForwardRead, slot)
    chain = read.chain
    key = slot_key(chain, slot)
    slot == read.last || slot == 0 || return fetch_record(chain, key)
    return fetch_object(chain.store, key), false
end

# The task's own exception, not the `TaskFailedException` around it, so a failed fetch
# reads as what it is.
function task_result(task::Task)
    try
        return fetch(task)
    catch e
        e isa TaskFailedException || rethrow()
        throw(e.task.exception)
    end
end

function accept_slot!(read::ForwardRead, slot, bytes, cached)
    record = try_checked_record(read, slot, bytes)
    if record === nothing && cached
        # The store's word before the chain is blamed: first this slot's bytes.
        bytes, cached = fetch_object(read.chain.store, slot_key(read.chain, slot)), false
        record = try_checked_record(read, slot, bytes)
    end
    if record === nothing
        record = record_after_settling!(read, slot, bytes)
        read.stopped && return nothing
    end
    read.chain_id === nothing && (read.chain_id = chain_id_string(record.chain_id))
    if cached
        hold!(read, slot, bytes, record)
    else
        yield_vouched!(read, slot, bytes, record)
    end
    return nothing
end

# The hash that the next record must name: the top of the waiting run, else the anchor.
function parent_hash(read::ForwardRead)
    return isempty(read.pending) ? read.anchor : last(read.pending).transaction_hash
end

# The Try variant of `checked_record`.
function try_checked_record(read::ForwardRead, slot, bytes)
    bytes === nothing && return nothing
    record = try_decode_record(bytes, slot)
    record === nothing && return nothing
    is_of_chain(record, read.chain_id) || return nothing
    return names_parent(record, parent_hash(read)) ? record : nothing
end

# Returns the record that `bytes` hold as `slot`: they are there, decode, carry the
# chain id of the read and name the parent. Throws `RewrittenChainError` for an absent
# slot or another parent, and `MalformedRecordError` for bytes that do not decode or
# that are a record of another chain.
function checked_record(read::ForwardRead, slot, bytes)
    chain = read.chain
    evidence = (; read.path, chain.bucket, chain.prefix, read.chain_id, slot)
    bytes === nothing && throw(RewrittenChainError(; evidence..., detail = SLOT_VANISHED))
    record = Ops.decode_record(bytes; slot)
    check_of_chain(record, read.chain_id, slot)
    parent = parent_hash(read)
    names_parent(record, parent) || throw(
        RewrittenChainError(;
            evidence..., expected = TransactionHash(parent),
            found = TransactionHash(record.prev_hash),
            detail = "the record names another parent than the record of slot " *
                "$(slot - 1)",
        )
    )
    return record
end

function check_of_chain(record::Ops.Record, chain_id, slot)
    is_of_chain(record, chain_id) || throw(
        MalformedRecordError(;
            chain_id, slot,
            detail = "the record carries chain id " *
                "$(chain_id_string(record.chain_id)): a record of another chain was " *
                "written into this prefix",
        )
    )
    return nothing
end

function is_of_chain(record::Ops.Record, chain_id)
    return chain_id === nothing || chain_id_string(record.chain_id) == chain_id
end

names_parent(record::Ops.Record, parent) = parent === nothing || record.prev_hash == parent

function hold!(read::ForwardRead, slot, bytes, record)
    _is_kept = read.pending_bytes + length(bytes) <= read.keep_bytes
    kept = _is_kept ? record : nothing
    size = _is_kept ? length(bytes) : 0
    push!(read.pending, PendingRecord(slot, Ops.transaction_hash(bytes), kept, size))
    read.pending_bytes += size
    return nothing
end

function yield_vouched!(read::ForwardRead, slot, bytes, record)
    write_cached_record(read.chain, slot_key(read.chain, slot), bytes)
    flush!(read)
    read.stopped && return nothing
    transaction_hash = Ops.transaction_hash(bytes)
    read.stopped = read.f(slot, record, transaction_hash) === true
    read.anchor = transaction_hash
    return nothing
end

# Yields the waiting run, which the store has vouched for.
function flush!(read::ForwardRead)
    for pending in read.pending
        record = pending_record(read, pending)
        read.stopped = read.f(pending.slot, record, pending.transaction_hash) === true
        read.stopped && return nothing
    end
    read.anchor = parent_hash(read)
    empty!(read.pending)
    read.pending_bytes = 0
    return nothing
end

function pending_record(read::ForwardRead, pending::PendingRecord)
    record = pending.record
    return record === nothing ? read_vouched_record(read, pending) : record
end

# A vouched-for record that was not kept: from the cache again.
function read_vouched_record(read::ForwardRead, pending::PendingRecord)
    slot = pending.slot
    bytes = fetch_named_record(
        read.chain, slot, pending.transaction_hash;
        read.path, read.chain_id, detail = NAMED_BY_SLOT_ABOVE,
    )
    return Ops.decode_record(bytes; slot)
end

# Returns the bytes of `slot` that hash to `expected`, the hash the chain names for it:
# the record cache's, else the store's, which then replace the cached file. When the
# store does not hold them either, the cached file stays as it was, as evidence
# (ADR-0040). `path`, `chain_id` and `detail` are for the `RewrittenChainError`.
function fetch_named_record(chain::Chain, slot, expected; path, chain_id, detail)
    bytes = read_cached_record(chain, slot)
    hashes_to(bytes, expected) && return bytes
    key = slot_key(chain, slot)
    bytes = fetch_object(chain.store, key)
    hashes_to(bytes, expected) || throw(
        RewrittenChainError(;
            path, chain.bucket, chain.prefix, chain_id, slot,
            expected = TransactionHash(expected), found = found_hash(bytes), detail,
        )
    )
    write_cached_record(chain, key, bytes)
    return bytes
end

hashes_to(bytes, expected) = bytes !== nothing && Ops.transaction_hash(bytes) == expected

found_hash(::Nothing) = nothing
found_hash(bytes) = TransactionHash(Ops.transaction_hash(bytes))

# Returns the record of `slot` from the store's `bytes`, once the cached run below it is
# settled with the store. When the store's word fails, the part of the run that it
# vouched for is yielded first, and then the failure is thrown.
function record_after_settling!(read::ForwardRead, slot, bytes)
    isempty(read.pending) && return checked_record(read, slot, bytes)
    settle!(read)
    read.stopped && return nothing
    record = try_checked_record(read, slot, bytes)
    record === nothing || return record
    flush!(read)
    read.stopped && return nothing
    return checked_record(read, slot, bytes)
end

# The cached run failed to vouch for what follows it. The store is asked for the run
# from the top down until it agrees with the cache: that record vouches for the run
# below it. The store's bytes above that point are then checked upwards and held as
# the run.
function settle!(read::ForwardRead)
    fresh = Dict{Int, Union{Nothing, Vector{UInt8}}}()
    agree = fetch_agreement!(fresh, read)
    above = [pending.slot for pending in read.pending[(agree + 1):end]]
    resize!(read.pending, agree)
    read.pending_bytes = sum(pending -> pending.size, read.pending; init = 0)
    for (offset, slot) in enumerate(above)
        hold_store_record!(read, slot, fresh, agree + offset)
        read.stopped && return nothing
    end
    return nothing
end

# Fetches the run's slots from the top down until the store's bytes hash as the cached
# ones did. Up to `keep_bytes` of what the store returned is kept in `fresh`, by index
# in the run. Returns the index of the record that agrees, 0 when none does.
function fetch_agreement!(fresh, read::ForwardRead)
    agree = length(read.pending)
    fresh_bytes = 0
    while agree >= 1
        pending = read.pending[agree]
        bytes = fetch_object(read.chain.store, slot_key(read.chain, pending.slot))
        hashes_to(bytes, pending.transaction_hash) && break
        n_bytes = bytes === nothing ? 0 : length(bytes)
        if fresh_bytes + n_bytes <= read.keep_bytes
            fresh[agree] = bytes
            fresh_bytes += n_bytes
        end
        agree -= 1
    end
    return agree
end

function hold_store_record!(read::ForwardRead, slot, fresh, index)
    key = slot_key(read.chain, slot)
    bytes = haskey(fresh, index) ? pop!(fresh, index) : fetch_object(read.chain.store, key)
    record = try_checked_record(read, slot, bytes)
    if record === nothing
        flush!(read)
        read.stopped && return nothing
        record = checked_record(read, slot, bytes)
    end
    write_cached_record(read.chain, key, bytes)
    hold!(read, slot, bytes, record)
    return nothing
end
