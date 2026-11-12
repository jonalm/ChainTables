"""
    PinnedCopyError

The local copy is pinned at a slot, so a call that would move it is refused. Run
`unpin!(copy)` to make it live, or use a live copy.
"""
struct PinnedCopyError <: ChainTablesError
    path::MaybeString
    slot::MaybeInt
    call::MaybeString
    detail::String
end

function PinnedCopyError(; path = nothing, slot = nothing, call = nothing, detail = "")
    return PinnedCopyError(path, slot, call, detail)
end

function Base.showerror(io::IO, e::PinnedCopyError)
    print_summary(io, e, "the local copy is pinned, so it cannot move")
    print_evidence(io, e)
    print(io, "\nRun `unpin!(copy)` to make it live, or use a live copy.")
    return nothing
end

"""
    FingerprintMismatchError

A record's state fingerprint (`expected`) differs from the one this client holds or
computes (`computed`, `nothing` when a table file is missing). Run `repair!(copy)`.
"""
struct FingerprintMismatchError <: ChainTablesError
    chain_id::MaybeString
    slot::MaybeInt
    expected::MaybeFp
    computed::MaybeFp
    record_client::Union{Nothing, ClientVersion}
    this_client::Union{Nothing, ClientVersion}
    detail::String
end

function FingerprintMismatchError(;
        chain_id = nothing, slot = nothing, expected = nothing, computed = nothing,
        record_client = nothing, this_client = nothing, detail = ""
    )
    expected_fp = maybe_hash(StateFingerprint, expected)
    computed_fp = maybe_hash(StateFingerprint, computed)
    return FingerprintMismatchError(
        chain_id, slot, expected_fp, computed_fp, record_client, this_client, detail
    )
end

function Base.showerror(io::IO, e::FingerprintMismatchError)
    print_summary(io, e, "the state fingerprint differs from the record's")
    print_evidence(io, e)
    print(io, "\nRun `repair!(copy)`, which replays the chain into fresh table files.")
    return nothing
end

"""
    DivergenceError

A fresh replay of the record cache to the head's slot yields `computed`, where the
head carries `expected`: this machine cannot reproduce the chain. It does not say
which side is right. Report it with both client versions.
"""
struct DivergenceError <: ChainTablesError
    path::MaybeString
    chain_id::MaybeString
    slot::MaybeInt
    expected::MaybeFp
    computed::MaybeFp
    tables::Vector{String} # the tables whose hashes differ
    detail::String
end

function DivergenceError(;
        path = nothing, chain_id = nothing, slot = nothing, expected = nothing,
        computed = nothing, tables = String[], detail = ""
    )
    expected_fp = maybe_hash(StateFingerprint, expected)
    computed_fp = maybe_hash(StateFingerprint, computed)
    return DivergenceError(path, chain_id, slot, expected_fp, computed_fp, tables, detail)
end

function Base.showerror(io::IO, e::DivergenceError)
    print_summary(io, e, "a fresh replay does not reproduce the head's state")
    print_evidence(io, e)
    print(
        io, "\nThis machine cannot reproduce the chain; which side is right is not ",
        "decided here. Report it with the Julia and ChainTables versions."
    )
    return nothing
end

"""
    NotALocalCopyError

The path is not a local copy: a file, or a non-empty directory without `heads/` and
`tables/`, or a head no client can read. Open another path.
"""
struct NotALocalCopyError <: ChainTablesError
    path::MaybeString
    detail::String
end

NotALocalCopyError(; path = nothing, detail = "") = NotALocalCopyError(path, detail)

function Base.showerror(io::IO, e::NotALocalCopyError)
    print_summary(io, e, "the path is not a local copy")
    print_evidence(io, e)
    print(io, "\nOpen another path, or empty this one if it is disposable.")
    return nothing
end

"""
    LayoutVersionError

A head file of the local copy was written by a newer client, in a layout this one
cannot read. Upgrade ChainTables, or delete the copy and sync again.
"""
struct LayoutVersionError <: ChainTablesError
    path::MaybeString
    file::MaybeString
    detail::String
end

function LayoutVersionError(; path = nothing, file = nothing, detail = "")
    return LayoutVersionError(path, file, detail)
end

function Base.showerror(io::IO, e::LayoutVersionError)
    print_summary(io, e, "the local copy has a newer layout than this client reads")
    print_evidence(io, e)
    print(io, "\nUpgrade ChainTables, or delete the copy and sync again (never migrate).")
    return nothing
end

"""
    WrongChainError

The local copy is bound to chain `bound`, and the chain being opened is `opened`.
Open another path for this chain.
"""
struct WrongChainError <: ChainTablesError
    path::MaybeString
    bound::MaybeString
    opened::MaybeString
    detail::String
end

function WrongChainError(; path = nothing, bound = nothing, opened = nothing, detail = "")
    return WrongChainError(path, bound, opened, detail)
end

function Base.showerror(io::IO, e::WrongChainError)
    print_summary(io, e, "the local copy is bound to another chain")
    print_evidence(io, e)
    print(io, "\nOpen another path for this chain.")
    return nothing
end

"""
    LocalCopyInconsistentError

The local copy is damaged: a head that is not self-consistent, a named file missing,
or a table file whose bytes do not hash to its name. Run `repair!(copy)`; with no
readable head, delete the directory and sync.
"""
struct LocalCopyInconsistentError <: ChainTablesError
    path::MaybeString
    slot::MaybeInt
    file::MaybeString # relative to `path`
    detail::String
end

function LocalCopyInconsistentError(;
        path = nothing, slot = nothing, file = nothing, detail = ""
    )
    return LocalCopyInconsistentError(path, slot, file, detail)
end

function Base.showerror(io::IO, e::LocalCopyInconsistentError)
    print_summary(io, e, "the local copy is damaged")
    print_evidence(io, e)
    print(
        io, "\nRun `repair!(copy)`; with no readable head, delete the directory ",
        "and sync again."
    )
    return nothing
end

"""
    RecordCacheError

The record cache lacks a slot's record (`found` is `nothing`) or holds bytes of
another hash. The cache is damaged, not the chain: run `repair!(copy)`. When the file
changed while it was being checked, run the call again.
"""
struct RecordCacheError <: ChainTablesError
    chain_id::MaybeString
    slot::MaybeInt
    path::MaybeString # the cache file
    expected::MaybeTxn
    found::MaybeTxn
    detail::String
end

function RecordCacheError(;
        chain_id = nothing, slot = nothing, path = nothing, expected = nothing,
        found = nothing, detail = ""
    )
    expected_hash = maybe_hash(TransactionHash, expected)
    found_hash = maybe_hash(TransactionHash, found)
    return RecordCacheError(chain_id, slot, path, expected_hash, found_hash, detail)
end

function Base.showerror(io::IO, e::RecordCacheError)
    print_summary(io, e, "the record cache does not hold the chain's record")
    print_evidence(io, e)
    print(
        io, "\nRun `repair!(copy)`, which fetches the record again. If another process ",
        "was writing the cache, run the call again."
    )
    return nothing
end
