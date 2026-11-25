const REBUILD = "recompute the row set and build again with `write_builder(copy)`. " *
    "This builder is spent."

const STALE_HEAD_NEXT_MOVES = Dict(
    :builder_behind_copy => "A `sync!` moved the local copy after this builder was " *
        "taken. With the copy as it is now, $REBUILD",
    :copy_behind_chain => "Run `sync!(copy)`, $REBUILD",
)

const STALE_HEAD_NEXT_MOVE = "Run `sync!(copy)`, $REBUILD"

"""
    StaleHeadError

Thrown when `commit!` finds its write builder behind the local copy, or the local copy
behind the chain.

`reason` is `:builder_behind_copy` in the first case: `slot` is the builder's head and
`chain_slot` the local copy's. It is `:copy_behind_chain` in the second: `slot` is the
local copy's head and `chain_slot` the chain's. `path` is the local copy.
"""
Base.@kwdef struct StaleHeadError <: ChainTablesError
    path::Union{Nothing, String} = nothing
    chain_id::Union{Nothing, String} = nothing
    slot::Union{Nothing, Int64} = nothing
    chain_slot::Union{Nothing, Int64} = nothing
    reason::Union{Nothing, Symbol} = nothing
    detail::String = ""
end

function Base.showerror(io::IO, e::StaleHeadError)
    print_summary(io, e, "the write builder's head is behind the chain.")
    print_evidence(io, e)
    print(io, get(STALE_HEAD_NEXT_MOVES, e.reason, STALE_HEAD_NEXT_MOVE))
    return nothing
end

const LOST_RACE_NEXT_MOVES = Dict(
    :slot_taken => "The write is never retried. Run `sync!(copy)`, $REBUILD",
    :chain_exists => "A chain is at this bucket and prefix already, and `create_chain` " *
        "is never retried. Use that chain with `open(chain, path)` and `sync!(copy)`, " *
        "or create under another prefix.",
)

const LOST_RACE_NEXT_MOVE = "The write is never retried. Run `sync!(copy)` to read " *
    "the chain as it is now; after a commit, recompute the row set and build again."

"""
    LostRaceError

Thrown when `commit!` or `create_chain` finds another client's record in the slot it
wrote to.

`reason` is `:slot_taken` from `commit!` and `:chain_exists` from `create_chain`.
`transaction_hash` is the hash of the record in the slot, and `chain_id` the chain's:
from `create_chain`, the id of the chain that is there, `nothing` when its genesis
record is malformed.
"""
Base.@kwdef struct LostRaceError <: ChainTablesError
    bucket::Union{Nothing, String} = nothing
    prefix::Union{Nothing, String} = nothing
    chain_id::Union{Nothing, String} = nothing
    slot::Union{Nothing, Int64} = nothing
    transaction_hash::Union{Nothing, TransactionHash} = nothing
    reason::Union{Nothing, Symbol} = nothing
    detail::String = ""
end

function Base.showerror(io::IO, e::LostRaceError)
    print_summary(io, e, "another client's record is in this slot.")
    print_evidence(io, e)
    print(io, get(LOST_RACE_NEXT_MOVES, e.reason, LOST_RACE_NEXT_MOVE))
    return nothing
end

# style: field BioMeCore's commit!(::ChangeSet) keeps cause and throws it after it settles
"""
    CommitOutcomeUnknownError

Thrown when `commit!` stops after the put of its record began, so that the failure does
not say whether the commit happened.

`transaction_hash` is the hash of the record it put at `slot`. `landed` is `true` when
the record is known to be in the chain and only the local copy's head was not written,
and `nothing` when that is not known. `cause` is the failure.
"""
Base.@kwdef struct CommitOutcomeUnknownError <: ChainTablesError
    bucket::Union{Nothing, String} = nothing
    prefix::Union{Nothing, String} = nothing
    chain_id::Union{Nothing, String} = nothing
    slot::Union{Nothing, Int64} = nothing
    transaction_hash::Union{Nothing, TransactionHash} = nothing
    landed::Union{Nothing, Bool} = nothing
    cause::Exception
    detail::String = ""
end

function Base.showerror(io::IO, e::CommitOutcomeUnknownError)
    print_summary(io, e, "the commit stopped after the put of its record began.")
    print_evidence(io, e)
    print(io, "Run `sync!(copy)`: the commit happened exactly when `commit_log(copy)` ")
    print(io, "shows `transaction_hash` at `slot`. This builder is spent.")
    return nothing
end

"""
    UnsupportedStoreError

Thrown when `commit!` meets an object store that is not AWS S3, on a chain without
`assume_first_writer_wins`.

`endpoint` is the store's endpoint.
"""
Base.@kwdef struct UnsupportedStoreError <: ChainTablesError
    endpoint::Union{Nothing, String} = nothing
    detail::String = ""
end

function Base.showerror(io::IO, e::UnsupportedStoreError)
    summary = "the object store is not AWS S3, so nothing promises that a put never " *
        "replaces an existing key."
    print_summary(io, e, summary)
    print_evidence(io, e)
    print(io, "Use AWS S3, or construct the `Chain` with ")
    print(io, "`assume_first_writer_wins = true` to make that promise for the store.")
    return nothing
end

"""
    WriteBuilderError

Thrown when the write builder or `commit!` refuses a call before anything is written: a
wrong value, a spent or empty builder, an op that the content does not allow, or a
record over the cap.

`detail` starts with the call to fix. It is the whole evidence.
"""
Base.@kwdef struct WriteBuilderError <: ChainTablesError
    detail::String
end

function Base.showerror(io::IO, e::WriteBuilderError)
    print_summary(io, e, "the write was refused before anything was written.")
    print(io, "Correct the call that the message names.")
    return nothing
end

"""
    PinnedCopyError

Thrown when `sync!`, `write_builder` or `commit!` is called on a pinned
copy.

`slot` is the slot the copy is pinned at, `nothing` for a copy with no head. `detail`
names the call.
"""
Base.@kwdef struct PinnedCopyError <: ChainTablesError
    path::Union{Nothing, String} = nothing
    slot::Union{Nothing, Int64} = nothing
    detail::String = ""
end

function Base.showerror(io::IO, e::PinnedCopyError)
    print_summary(io, e, "the local copy is pinned, so the call does not move it.")
    print_evidence(io, e)
    print(io, "Run `unpin!(copy)` to make it live, or use a live copy.")
    return nothing
end
