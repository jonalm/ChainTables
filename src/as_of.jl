const AS_OF_PREFIX = "chaintables-as_of-"

const AS_OF_TARGETS = "give a slot (an Integer) or a TransactionHash"

# Over 8 lines: how a given path is reused is the contract.
"""
    as_of(chain, target; path = nothing)

Return a pinned local copy of the chain as of `target`: a slot, or the `TransactionHash`
of the record to stop at, never a time (`slot_at` turns a time into a slot). Built by
replay from slot 0 and verified at the target; `sync!`, `write_builder` and `commit!`
refuse it until `unpin!`. The live local copy is never touched.

With no `path` the copy is temporary and `close` deletes it. A `path` holding a copy of
this chain pinned at or below `target` is reopened and replayed forward; a live copy or
one pinned above is refused. Throws `ChainNotFoundError` when the chain has no slot 0.

Examples: test/test_as_of_examples.jl
"""
function as_of(chain::Chain, target; path = nothing)
    slot = target_slot(chain, target)
    _is_temporary = path === nothing
    dir = _is_temporary ? mktempdir(; prefix = AS_OF_PREFIX, cleanup = false) : String(path)
    _is_made = !ispath(dir)
    copy = with_cleanup_on_failure(() -> remove_temporary(dir, _is_temporary)) do
        open(chain, dir)
    end
    copy.temporary = _is_temporary
    with_cleanup_on_failure(() -> close_failed_as_of(copy, dir, _is_made)) do
        pin_at!(copy, chain, slot)
    end
    return copy
end

function remove_temporary(dir, _is_temporary)
    _is_temporary && rm(dir; recursive = true, force = true)
    return nothing
end

# A directory this call made, with no head written into it, is removed, so the path is
# fresh again.
function close_failed_as_of(copy::LocalCopy, dir, _is_made)
    close(copy)
    _is_made && copy.head === nothing && rm(dir; recursive = true, force = true)
    return nothing
end

function pin_at!(copy::LocalCopy, chain::Chain, slot)
    h = copy.head
    h === nothing || check_reusable_pin(copy, slot)
    pin!(copy)
    if h === nothing || h.slot < slot
        check_slot_exists(chain, slot)
        h === nothing || check_head_slot(copy, chain)
        replay!(copy, h === nothing ? 0 : h.slot + 1, slot)
    else
        check_head_record(copy, chain)
    end
    return nothing
end

function check_reusable_pin(copy::LocalCopy, slot)
    at = "as_of: the local copy at $(copy.path)"
    h = copy.head
    is_pinned(copy) ||
        throw(ArgumentError("$at is live (slot $(h.slot)), and as_of never touches one"))
    h.slot > slot &&
        throw(ArgumentError("$at is pinned at slot $(h.slot), above $slot"))
    return nothing
end

function check_slot_exists(chain::Chain, slot)
    slot_exists(chain, slot) && return nothing
    slot > 0 && slot_exists(chain, 0) ||
        throw(ChainNotFoundError(; chain.bucket, chain.prefix, call = "as_of"))
    throw(ArgumentError("as_of: the chain at $(location(chain)) has no slot $slot"))
end

"""
    target_slot(chain, target)

Return the slot `as_of` stops at: `target` itself when it is a slot, or the slot whose
record hashes to `target`, found by reading the chain from slot 0.
"""
function target_slot(chain::Chain, target::Integer)
    target >= 0 || throw(ArgumentError("as_of: slot $target is negative"))
    return Int64(target)
end

function target_slot(chain::Chain, target::TransactionHash)
    top = chain_top(chain, "as_of")
    found = Ref{Union{Nothing, Int64}}(nothing)
    read_forward(chain, 0, top) do s, record, th
        th == target.bytes && (found[] = s)
        return found[] !== nothing
    end
    where = location(chain)
    found[] === nothing &&
        throw(ArgumentError("as_of: no record of the chain at $where hashes to $target"))
    return found[]::Int64
end

# A fingerprint is a hash too, and the one most easily passed by mistake.
function target_slot(chain::Chain, ::StateFingerprint)
    throw(ArgumentError("as_of: a StateFingerprint is not an address; $AS_OF_TARGETS"))
end

# A wrong address gets a message naming the two right ones, not a MethodError.
function target_slot(chain::Chain, target)
    T = typeof(target)
    throw(ArgumentError("as_of: target is a $T; $AS_OF_TARGETS"))
end

function chain_top(chain::Chain, call)
    top = gallop(chain, -1)
    top == -1 && throw(ChainNotFoundError(; chain.bucket, chain.prefix, call))
    return top
end

"""
    slot_at(chain, time_ms)

Return the highest slot whose record's `client.time_ms` is at or below `time_ms`
(milliseconds since the Unix epoch, UTC), by reading every record from slot 0. A scan,
because committers' clocks are not monotone across clients. A time before the genesis
record's throws `ArgumentError`: there is no state before slot 0.

Examples: test/test_as_of_examples.jl
"""
function slot_at(chain::Chain, time_ms)
    time_ms isa Integer ||
        throw(ArgumentError("slot_at: time_ms is a $(typeof(time_ms)), not an Integer"))
    top = chain_top(chain, "slot_at")
    best = Ref{Union{Nothing, Int64}}(nothing)
    genesis_ms = Ref{Int64}(0)
    read_forward(chain, 0, top) do s, record, th
        s == 0 && (genesis_ms[] = record.client.time_ms)
        record.client.time_ms <= time_ms && (best[] = s)
        return false
    end
    best[] === nothing &&
        throw(ArgumentError("slot_at: $time_ms is before the genesis, at $(genesis_ms[])"))
    return best[]::Int64
end
