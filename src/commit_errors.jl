"""
    StaleHeadError

Thrown when `commit!` finds its write builder behind the local copy, or the local copy
behind the chain.

In the first case `slot` is the builder's head and `chain_slot` the local copy's. In
the second `slot` is the local copy's head and `chain_slot` the chain's.
"""
Base.@kwdef struct StaleHeadError <: ChainTablesError
    chain_id::Union{Nothing, String} = nothing
    slot::Union{Nothing, Int64} = nothing
    chain_slot::Union{Nothing, Int64} = nothing
    detail::String = ""
end

function Base.showerror(io::IO, e::StaleHeadError)
    print_summary(io, e, "the write builder's head is behind the chain.")
    print_evidence(io, e)
    print(io, "Run `sync!(copy)`, recompute the row set and build again with ")
    print(io, "`write_builder(copy)`. This builder is spent.")
    return nothing
end

"""
    LostRaceError

Thrown when `commit!` or `create_chain` finds another client's record in the slot it
wrote to.

`transaction_hash` is the hash of that record.
"""
Base.@kwdef struct LostRaceError <: ChainTablesError
    chain_id::Union{Nothing, String} = nothing
    slot::Union{Nothing, Int64} = nothing
    transaction_hash::Union{Nothing, TransactionHash} = nothing
    detail::String = ""
end

function Base.showerror(io::IO, e::LostRaceError)
    print_summary(io, e, "another client's record is in this slot.")
    print_evidence(io, e)
    print(io, "The write is never retried. Run `sync!(copy)` to read the chain as it ")
    print(io, "is now; after a commit, recompute the row set and build again.")
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

Thrown when `sync!` or `commit!` is called on a pinned copy.

`slot` is the slot the copy is pinned at, `nothing` for a copy with no head.
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
