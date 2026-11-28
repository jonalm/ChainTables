const AS_OF_PREFIX = "chaintables-as_of-"

const PINNED_HEAD_DIFFERS = "the pinned copy's head is not the result of the record " *
    "in its slot"

# Over 8 lines: which given paths are opened, replayed or refused is the contract
# (ADR-0015, ADR-0023).
"""
    as_of(chain, target; path = nothing)

Return a pinned copy of the chain as of `target`: a slot, or the `TransactionHash` of
the record to stop at, never a time (`slot_at` finds a slot by time).

The copy is built by replay from slot 0, and the record at `target` is held against
its state fingerprint. `sync!`, `write_builder` and `commit!` refuse a pinned copy, and
`unpin!` makes it live. Without `path`, the copy is temporary and `close` deletes it.
A copy at `path` that is pinned at `target` is opened, and its head is held against the
record of its slot; one pinned below `target` is replayed forward. A live copy, or one
pinned above `target`, throws `ArgumentError`. When the call fails, a temporary copy is
removed, and so is a directory at `path` that it made, unless a checkpoint reached it.

Throws `ChainNotFoundError` when the chain has no slot 0.

Examples: test/test_as_of_examples.jl
"""
function as_of(chain::Chain, target; path = nothing)
    slot = target_slot(chain, target)
    temporary = path === nothing
    dir = temporary ? mktempdir(; prefix = AS_OF_PREFIX, cleanup = false) : String(path)
    _is_made = temporary || !ispath(dir)
    return with_removal_on_failure(dir, temporary, _is_made) do
        open_pinned(chain, dir, slot; temporary)
    end
end

function target_slot(chain::Chain, target::Integer)
    target >= 0 || throw(ArgumentError("slot $target is negative"))
    return Int64(target)
end

function target_slot(chain::Chain, target::TransactionHash)
    top = fetch_top_slot(chain, -1)
    top == -1 && throw(ChainNotFoundError(chain, "as_of"))
    slot = read_slot_of(chain, top, target)
    slot === nothing && throw(
        ArgumentError(
            "no record of the chain at $(location(chain)) has the transaction hash " *
                "$(bytes2hex(target)); slots 0 to $top were read"
        )
    )
    return slot
end

function target_slot(chain::Chain, target)
    throw(
        ArgumentError(
            "as_of takes a slot (an Integer) or a TransactionHash, got a $(typeof(target))"
        )
    )
end

# Returns the slot of the record whose transaction hash is `target`, or `nothing`.
function read_slot_of(chain::Chain, top, target::TransactionHash)
    found = Ref{Union{Nothing, Int64}}(nothing)
    read_forward(chain, 0, top) do slot, _, transaction_hash
        transaction_hash == target.bytes && (found[] = slot)
        return found[] !== nothing
    end
    return found[]
end

# Runs `f()`. When it throws, `dir` is removed if this call made it for a temporary
# copy, or made it and no checkpoint wrote a head file into it: the path is fresh again.
function with_removal_on_failure(f, dir, temporary, _is_made)
    _is_done = false
    try
        result = f()
        _is_done = true
        return result
    finally
        _is_done || remove_failed_directory(dir, temporary, _is_made)
    end
end

function remove_failed_directory(dir, temporary, _is_made)
    temporary || (_is_made && !has_head_file(dir)) || return nothing
    rm(dir; recursive = true, force = true)
    return nothing
end

function has_head_file(dir)
    heads = heads_dir(dir)
    return isdir(heads) && any(contains(HEAD_NAME), readdir(heads))
end

function open_pinned(chain::Chain, dir, slot; temporary)
    local_copy = open(chain, dir)
    local_copy.temporary = temporary
    check_pinnable(local_copy, local_copy.head, slot)
    write_pin(local_copy)
    replay_to!(local_copy, chain, local_copy.head, slot)
    return local_copy
end

check_pinnable(local_copy::LocalCopy, ::Nothing, slot) = nothing

# `as_of` never touches a live copy, and a copy never moves backwards (ADR-0015).
function check_pinnable(local_copy::LocalCopy, head_file::Head, slot)
    path = local_copy.path
    is_pinned(local_copy) || throw(
        ArgumentError(
            "the local copy at $path is live; as_of never touches a live copy. Give " *
                "another path, or none for a temporary copy"
        )
    )
    head_file.slot > slot && throw(
        ArgumentError(
            "the local copy at $path is pinned at slot $(head_file.slot), above $slot; " *
                "a local copy never moves backwards"
        )
    )
    return nothing
end

function replay_to!(local_copy::LocalCopy, chain::Chain, ::Nothing, slot)
    check_slot_exists(chain, slot)
    replay!(local_copy, 0, slot)
    return nothing
end

# A head pinned at the slot is held against its record, as a commit does: the open
# checks of the files say nothing about the chain (ADR-0023, ADR-0041).
function replay_to!(local_copy::LocalCopy, chain::Chain, head_file::Head, slot)
    head_file.slot == slot &&
        return check_head_record(local_copy, chain, PINNED_HEAD_DIFFERS)
    check_slot_exists(chain, slot)
    fetch_head_slot(local_copy, chain)
    replay!(local_copy, head_file.slot + 1, slot)
    return nothing
end

function check_slot_exists(chain::Chain, slot)
    has_slot(chain, slot) && return nothing
    slot > 0 && has_slot(chain, 0) && throw(
        ArgumentError(
            "the chain at $(location(chain)) has no slot $slot; its head is below it"
        )
    )
    throw(ChainNotFoundError(chain, "as_of"))
end
