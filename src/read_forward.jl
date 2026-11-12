"""
    ParentLink(transaction_hash, chain_id, holder)

What a read that starts above slot 0 holds for the slot below its first: that record's
transaction hash, the chain id, and who holds them, in words ("the local copy at …").
"""
struct ParentLink
    transaction_hash::Vector{UInt8}
    chain_id::String
    holder::String
end

"""
    VouchedLink(transaction_hash, source)

The transaction hash the next record must name as its parent, vouched for by the store,
and where it comes from in words ("slot 4"), for the error when a record names another.
"""
struct VouchedLink
    transaction_hash::Vector{UInt8}
    source::String
end

VouchedLink(slot::Integer, th) = VouchedLink(th, "slot $slot")
VouchedLink(parent::ParentLink) = VouchedLink(parent.transaction_hash, parent.holder)

"""
    PendingRecord(slot, transaction_hash, record, size)

A checked record of a cached run that waits for the store to vouch for it. `record` is
`nothing` when it was not kept decoded; `size` is what it counts against `keep_bytes`.
"""
struct PendingRecord
    slot::Int64
    transaction_hash::Vector{UInt8}
    record::Union{Nothing, Ops.Record}
    size::Int
end

"""
    ForwardRead(chain, f, last, keep_bytes, parent)

The state of one `read_forward`: the chain id, the last record vouched for, and the
cached run that waits for the store to vouch for it.
"""
mutable struct ForwardRead{C <: Chain, F}
    const chain::C
    const f::F
    const last::Int64
    const keep_bytes::Int
    chain_id::Union{Nothing, String}
    anchor::Union{Nothing, VouchedLink}
    const pending::Vector{PendingRecord}
    pending_bytes::Int
    stopped::Bool
end

function ForwardRead(chain::Chain, f, last, keep_bytes, parent::Union{Nothing, ParentLink})
    chain_id = parent === nothing ? nothing : parent.chain_id
    anchor = parent === nothing ? nothing : VouchedLink(parent)
    state = (chain_id, anchor, PendingRecord[], 0, false)
    return ForwardRead(chain, f, Int64(last), Int(keep_bytes), state...)
end

# How many stored bytes of cached records `read_forward` keeps decoded while it waits for
# the store to vouch for them; records past it are read from the cache again when vouched.
const PENDING_BYTES = 64 * 2^20

const SLOT_VANISHED = "the slot was there when head discovery probed it and is absent now"

# Over 8 lines: which records are yielded, and on whose word, is the contract (ADR-0040).
# `keep_bytes` is set only by tests: the re-read past it is reached in production only
# with over 64 MiB of records waiting.
"""
    read_forward(f, chain, first, last; parent = nothing, keep_bytes = PENDING_BYTES)

Call `f(slot, record, transaction_hash)` for the records of slots `first:last` in order,
stopping early when `f` returns `true`. Records are fetched `read_ahead` ahead through the
record cache, and each is checked: it decodes, carries the chain id, and names its
parent's hash. `parent` is given exactly when `first > 0`.

A record the store returned is yielded once checked; a cached one only once a record the
store returned names it. A failed check asks the store before the chain is
blamed. Throws `RewrittenChainError` or `MalformedRecordError` on the store's word only.

- `keep_bytes`: how many stored bytes of a waiting cached run are kept decoded.
"""
function read_forward(
        f, chain::Chain, first::Integer, last::Integer;
        parent::Union{Nothing, ParentLink} = nothing, keep_bytes = PENDING_BYTES
    )
    (parent === nothing) == (first == 0) ||
        throw(ArgumentError("read_forward: a parent is given exactly when first > 0"))
    r = ForwardRead(chain, f, last, keep_bytes, parent)
    tasks = Dict{Int64, Task}()
    try
        read_slots!(r, tasks, first)
    finally
        foreach(wait_landed, values(tasks))
    end
    return nothing
end

# Reads ahead of an early stop or a failure land, unawaited: their failures are moot.
function wait_landed(t::Task)
    try
        wait(t)
    catch e
        e isa TaskFailedException || rethrow()
    end
    return nothing
end

function read_slots!(r::ForwardRead, tasks, first)
    for s in first:r.last
        start_fetches!(tasks, r, s)
        bytes, cached = await(pop!(tasks, s))
        accept_slot!(r, s, bytes, cached)
        r.stopped && return nothing
    end
    isempty(r.pending) ||
        throw(AssertionError("BUG: the last slot came from the store, yet a run waits"))
    return nothing
end

# `tasks` holds the slots from `s` on that are fetched but not yet read.
function start_fetches!(tasks, r::ForwardRead, s)
    for k in (s + length(tasks)):min(r.last, s + r.chain.read_ahead - 1)
        tasks[k] = @async fetch_slot(r, k)
    end
    return nothing
end

# Slot 0 and the last slot come from the store, so every read starts and ends vouched.
function fetch_slot(r::ForwardRead, k)
    key = slot_key(r.chain, k)
    k == r.last || k == 0 || return fetch_record(r.chain, key)
    return fetch_object(r.chain.store, key), false
end

"""
    await(t)

Return the task's result. Throws the task's own exception rather than the
`TaskFailedException` around it, so a failed fetch reads as what it is.
"""
function await(t::Task)
    try
        return fetch(t)
    catch e
        e isa TaskFailedException || rethrow()
        throw(e.task.exception)
    end
end

function accept_slot!(r::ForwardRead, s, bytes, cached)
    record = try_record(r, bytes, s, top_link(r))
    if record === nothing && cached
        bytes, cached = fetch_object(r.chain.store, slot_key(r.chain, s)), false
        record = try_record(r, bytes, s, top_link(r))
    end
    if record === nothing
        record = record_after_settling!(r, s, bytes)
        r.stopped && return nothing
    end
    r.chain_id === nothing && (r.chain_id = chain_id_string(record.chain_id))
    th = Ops.transaction_hash(bytes)
    if cached
        hold!(r, s, th, record, length(bytes))
    else
        yield_vouched!(r, s, bytes, th, record)
    end
    return nothing
end

top_link(r::ForwardRead) = isempty(r.pending) ? r.anchor : link_to(last(r.pending))

link_to(p::PendingRecord) = VouchedLink(p.slot, p.transaction_hash)

"""
    try_record(r, bytes, s, parent)

Return the record `bytes` hold as slot `s` when they are present, decode, carry the
read's chain id and name `parent`'s hash; else `nothing`. `reject` throws the reason.
"""
function try_record(r::ForwardRead, bytes, s, parent)
    bytes === nothing && return nothing
    record = try_decode_record(bytes, s)
    record === nothing && return nothing
    is_of_chain(record, r.chain_id) || return nothing
    return names_parent(record, parent) ? record : nothing
end

function is_of_chain(record, chain_id)
    return chain_id === nothing || chain_id_string(record.chain_id) == chain_id
end

function names_parent(record, parent)
    return parent === nothing || record.prev_hash == parent.transaction_hash
end

"""
    reject(r, bytes, s, parent)

Throw why `try_record(r, bytes, s, parent)` refused `bytes`: `RewrittenChainError` for an
absent slot or another parent, `MalformedRecordError` for bytes that do not decode or a
record of another chain.
"""
function reject(r::ForwardRead, bytes, s, parent)
    chain_id = r.chain_id
    slot = s
    detail = SLOT_VANISHED
    bytes === nothing && throw(RewrittenChainError(; chain_id, slot, detail))
    record = Ops.decode_record(bytes; slot = s)
    theirs = chain_id_string(record.chain_id)
    is_of_chain(record, chain_id) ||
        throw(MalformedRecordError(; chain_id, slot, detail = "its chain id is $theirs"))
    names_parent(record, parent) && throw(AssertionError("BUG: a sound record rejected"))
    detail = "slot $s does not name the record of $(parent.source) as its parent"
    expected, found = parent.transaction_hash, record.prev_hash
    throw(RewrittenChainError(; chain_id, slot, expected, found, detail))
end

function hold!(r::ForwardRead, s, th, record, n)
    _is_kept = r.pending_bytes + n <= r.keep_bytes
    push!(r.pending, PendingRecord(s, th, _is_kept ? record : nothing, _is_kept ? n : 0))
    r.pending_bytes += _is_kept ? n : 0
    return nothing
end

function yield_vouched!(r::ForwardRead, s, bytes, th, record)
    heal_record!(r.chain, slot_key(r.chain, s), bytes)
    flush!(r)
    r.stopped && return nothing
    r.stopped = r.f(s, record, th) === true
    r.anchor = VouchedLink(s, th)
    return nothing
end

# Yield the vouched-for run waiting in `r.pending`, stopping when `f` returns `true`.
function flush!(r::ForwardRead)
    for p in r.pending
        r.stopped = r.f(p.slot, pending_record(r, p), p.transaction_hash) === true
        r.stopped && return nothing
    end
    isempty(r.pending) || (r.anchor = link_to(last(r.pending)))
    empty!(r.pending)
    r.pending_bytes = 0
    return nothing
end

function pending_record(r::ForwardRead, p::PendingRecord)
    return p.record === nothing ? reread(r, p) : p.record
end

# A vouched-for record that was not kept: from the cache again, or, when the file changed
# meanwhile, from the store, which must hold the bytes the chain names.
function reread(r::ForwardRead, p::PendingRecord)
    key = slot_key(r.chain, p.slot)
    bytes = cached_record(r.chain, key)
    th = p.transaction_hash
    hashes_to(bytes, th) && return Ops.decode_record(bytes; slot = p.slot)
    bytes = fetch_object(r.chain.store, key)
    found = bytes === nothing ? nothing : Ops.transaction_hash(bytes)
    detail = "the store no longer holds the record the slot above names"
    expected, slot = th, p.slot
    found == th || throw(RewrittenChainError(; r.chain_id, slot, expected, found, detail))
    heal_record!(r.chain, key, bytes)
    return Ops.decode_record(bytes; slot = p.slot)
end

"""
    record_after_settling!(r, s, bytes)

Return slot `s`'s record from the store's `bytes` once the cached run below it is settled
with the store (`settle!`). When the store's word fails, the part of the run it vouched for
is yielded first, then the failure is thrown; `nothing` when `f` stopped the read.
"""
function record_after_settling!(r::ForwardRead, s, bytes)
    isempty(r.pending) && reject(r, bytes, s, r.anchor)
    parent = settle!(r)
    r.stopped && return nothing
    record = try_record(r, bytes, s, parent)
    record === nothing || return record
    flush!(r)
    r.stopped && return nothing
    return reject(r, bytes, s, parent)
end

"""
    settle!(r)

Ask the store for the cached run in `r.pending` from the top down until it agrees with the
cache, then check the store's bytes above that point upwards and hold them as the run.
Return the run's top as a link. A failure is thrown after the vouched part is yielded.
"""
function settle!(r::ForwardRead)
    fresh = Dict{Int, Union{Nothing, AbstractVector{UInt8}}}()
    agree = store_agreement!(fresh, r)
    above = [p.slot for p in r.pending[(agree + 1):end]]
    resize!(r.pending, agree)
    r.pending_bytes = sum(p -> p.size, r.pending; init = 0)
    parent = top_link(r)
    for (j, s) in enumerate(above)
        key = slot_key(r.chain, s)
        bytes = haskey(fresh, agree + j) ? fresh[agree + j] : fetch_slot_bytes(r, key)
        record = try_record(r, bytes, s, parent)
        record === nothing && return reject_after_flush!(r, bytes, s, parent)
        heal_record!(r.chain, key, bytes)
        th = Ops.transaction_hash(bytes)
        hold!(r, s, th, record, length(bytes))
        parent = VouchedLink(s, th)
    end
    return parent
end

function reject_after_flush!(r::ForwardRead, bytes, s, parent)
    flush!(r)
    r.stopped && return parent
    return reject(r, bytes, s, parent)
end

# Fetch the run's slots from the top down until the store's bytes hash as the cached ones
# did, keeping up to `keep_bytes` of what it returned in `fresh`. Returns the index of the
# agreeing record, 0 when none agrees.
function store_agreement!(fresh, r::ForwardRead)
    agree = length(r.pending)
    fresh_bytes = 0
    while agree >= 1
        p = r.pending[agree]
        bytes = fetch_object(r.chain.store, slot_key(r.chain, p.slot))
        hashes_to(bytes, p.transaction_hash) && break
        n = bytes === nothing ? 0 : length(bytes)
        if fresh_bytes + n <= r.keep_bytes
            fresh[agree] = bytes
            fresh_bytes += n
        end
        agree -= 1
    end
    return agree
end

hashes_to(bytes, th) = bytes !== nothing && Ops.transaction_hash(bytes) == th

fetch_slot_bytes(r::ForwardRead, key) = fetch_object(r.chain.store, key)
