"""
    FingerprintMismatchError

Thrown when a state fingerprint is not the one this client holds or computes for its
slot: at a checkpoint, in the pre-checks of `commit!` and `as_of`, and in `verify`.

`expected` is the record's fingerprint and `computed` the one this client holds or
computes. From `verify(copy)` without `full`, `expected` is the head's fingerprint and
`computed` the one its table files hash to, `nothing` when a file is missing.
`record_client` and `this_client` name the library and the Julia that wrote the record
and that run here, when known. `path` is the local copy.
"""
Base.@kwdef struct FingerprintMismatchError <: ChainTablesError
    path::Union{Nothing, String} = nothing
    chain_id::Union{Nothing, String} = nothing
    slot::Union{Nothing, Int64} = nothing
    expected::Union{Nothing, StateFingerprint} = nothing
    computed::Union{Nothing, StateFingerprint} = nothing
    record_client::Union{Nothing, ClientVersions} = nothing
    this_client::Union{Nothing, ClientVersions} = nothing
    detail::String = ""
end

function Base.showerror(io::IO, e::FingerprintMismatchError)
    print_summary(io, e, "a state fingerprint is not the one this client computes.")
    print_evidence(io, e)
    print(io, "Run `repair!(copy)`: it rewrites damaged table files and says whether ")
    print(io, "this machine reproduces the chain.")
    return nothing
end

"""
    DivergenceError

Thrown when `repair!` replays the record cache to the head's slot and gets another state
fingerprint than the head holds.

`expected` is the head's fingerprint and `computed` the replay's. The error does not
say which side is right.
"""
Base.@kwdef struct DivergenceError <: ChainTablesError
    chain_id::Union{Nothing, String} = nothing
    slot::Union{Nothing, Int64} = nothing
    expected::Union{Nothing, StateFingerprint} = nothing
    computed::Union{Nothing, StateFingerprint} = nothing
    detail::String = ""
end

function Base.showerror(io::IO, e::DivergenceError)
    summary = "a fresh replay of the record cache does not give the head's state " *
        "fingerprint."
    print_summary(io, e, summary)
    print_evidence(io, e)
    print(io, "This machine cannot reproduce the chain. Nothing was written; the ")
    print(io, "local copy stays readable and never commits onto this chain.")
    return nothing
end

"""
    RewrittenChainError

Thrown when the bucket contradicts what the local copy has applied: a slot holds a
record of another hash, an applied slot is absent, or a record names a parent that the
copy does not hold.

`expected` is the hash the copy holds and `found` the hash fetched, `nothing` when the
slot was absent. For a wrong parent, both are hashes of the parent, not of the slot.
`path` is the local copy, `nothing` when the chain is read without one.
"""
Base.@kwdef struct RewrittenChainError <: ChainTablesError
    path::Union{Nothing, String} = nothing
    bucket::Union{Nothing, String} = nothing
    prefix::Union{Nothing, String} = nothing
    chain_id::Union{Nothing, String} = nothing
    slot::Union{Nothing, Int64} = nothing
    expected::Union{Nothing, TransactionHash} = nothing
    found::Union{Nothing, TransactionHash} = nothing
    detail::String = ""
end

function Base.showerror(io::IO, e::RewrittenChainError)
    print_summary(io, e, "the bucket contradicts what the local copy has applied.")
    print_evidence(io, e)
    print(io, "The bucket was written from outside the protocol, and nothing heals ")
    print(io, "it. The local copy stays readable.")
    return nothing
end

"""
    ChainNotFoundError

Thrown when a call that reads the chain finds no slot 0 at the chain's bucket and
prefix.

The bucket or prefix is not the chain's, or no chain was created there, or it was
truncated. The error cannot tell which.
"""
Base.@kwdef struct ChainNotFoundError <: ChainTablesError
    bucket::Union{Nothing, String} = nothing
    prefix::Union{Nothing, String} = nothing
    detail::String = ""
end

function Base.showerror(io::IO, e::ChainNotFoundError)
    print_summary(io, e, "there is no slot 0 at this bucket and prefix.")
    print_evidence(io, e)
    print(io, "Either the bucket or prefix is not the chain's, or no chain was ")
    print(io, "created there; the two cannot be told apart from here. ")
    print(io, "`create_chain(chain)` writes slot 0.")
    return nothing
end

"""
    RecordCacheError

Thrown when `verify(copy; full = true)` or `repair!` finds that the record cache lacks
the record of `slot` or holds bytes of another hash, and when a cache file changes
between two reads.

`path` is the cache file, `expected` the hash the chain names and `found` the hash of
the file's bytes, `nothing` when the file is missing. `sync!`, `as_of` and `slot_at`
never throw it: they read such a record from the object store.
"""
Base.@kwdef struct RecordCacheError <: ChainTablesError
    chain_id::Union{Nothing, String} = nothing
    slot::Union{Nothing, Int64} = nothing
    path::Union{Nothing, String} = nothing
    expected::Union{Nothing, TransactionHash} = nothing
    found::Union{Nothing, TransactionHash} = nothing
    detail::String = ""
end

function Base.showerror(io::IO, e::RecordCacheError)
    summary = "the record cache does not hold the record that the chain names for " *
        "this slot."
    print_summary(io, e, summary)
    print_evidence(io, e)
    print(io, "The record cache is damaged, not the chain. Run `repair!(copy)`, ")
    print(io, "which fetches the record from the object store and replaces the file.")
    return nothing
end

"""
    MalformedRecordError

Thrown when a record is one that no client can apply under its format version, found
when the record is decoded or applied.

`detail` names the rule that the record breaks. `op` is the 1-based index of the op
that broke a rule at apply. `chain_id` and `slot` are `nothing` when the record's bytes
do not give them.
"""
Base.@kwdef struct MalformedRecordError <: ChainTablesError
    chain_id::Union{Nothing, String} = nothing
    slot::Union{Nothing, Int64} = nothing
    op::Union{Nothing, Int64} = nothing
    detail::String = ""
end

function Base.showerror(io::IO, e::MalformedRecordError)
    print_summary(io, e, "no client can apply this record under its format version.")
    print_evidence(io, e)
    print(io, "Whoever committed it had a bug, and the chain is dead beyond this ")
    print(io, "slot. A new chain is the recovery.")
    return nothing
end
