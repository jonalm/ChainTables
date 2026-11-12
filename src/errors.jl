"""
    ChainTablesError <: Exception

The supertype of every error ChainTables throws. Catch it to handle any operational
failure of the package; catch a concrete subtype to branch on one.
"""
abstract type ChainTablesError <: Exception end

const MaybeTxn = Union{Nothing, TransactionHash}
const MaybeFp = Union{Nothing, StateFingerprint}
const MaybeString = Union{Nothing, String}
const MaybeInt = Union{Nothing, Int64}

"""
    ClientVersion

The `lib` and `julia` versions a record's client map names, kept as forensics when two
clients disagree on a state fingerprint.
"""
const ClientVersion = @NamedTuple{lib::String, julia::String}

"""
    print_evidence(io, e::ChainTablesError)

Write each Evidence field of `e` that is known (not `nothing`) on its own line.
`detail` is not evidence: `print_summary` writes it.
"""
function print_evidence(io::IO, e::ChainTablesError)
    for name in fieldnames(typeof(e))
        value = getfield(e, name)
        (name === :detail || value === nothing) && continue
        print(io, "\n  ", name, " = ", evidence_text(value))
    end
    return nothing
end

evidence_text(h::Union{TransactionHash, StateFingerprint}) = bytes2hex(h)
evidence_text(s::String) = s
evidence_text(e::Exception) = sprint(showerror, e)
evidence_text(x) = repr(x)

"""
    print_summary(io, e, summary)

Write the type name, the fixed `summary` and, when there is one, `e.detail`.
"""
function print_summary(io::IO, e::ChainTablesError, summary::AbstractString)
    print(io, nameof(typeof(e)), ": ", summary)
    isempty(e.detail) || print(io, ": ", e.detail)
    print(io, ".")
    return nothing
end

"""
    StaleHeadError

A commit found that the write builder's head is behind its local copy or the chain:
the row set was computed against a state that has moved. The builder is spent. Run
`sync!(copy)`, recompute the row set and build again.
"""
struct StaleHeadError <: ChainTablesError
    path::MaybeString
    chain_id::MaybeString
    slot::MaybeInt # the builder's or the copy's head
    chain_slot::MaybeInt # where the copy or the chain was seen
    detail::String
end

function StaleHeadError(;
        path = nothing, chain_id = nothing, slot = nothing, chain_slot = nothing,
        detail = ""
    )
    return StaleHeadError(path, chain_id, slot, chain_slot, detail)
end

function Base.showerror(io::IO, e::StaleHeadError)
    print_summary(io, e, "the write builder's head is behind the chain")
    print_evidence(io, e)
    print(
        io, "\nRun `sync!(copy)`, recompute the row set against the fresh state and ",
        "build again with `write_builder(copy)`. This builder is spent and never re-run."
    )
    return nothing
end

"""
    LostRaceError

Another client's record already fills the slot this call tried to fill. The call is
spent and never retried. Sync and build again, or, for a new chain, open the existing
one or create under another prefix.
"""
struct LostRaceError <: ChainTablesError
    location::MaybeString # bucket/prefix
    chain_id::MaybeString
    slot::MaybeInt
    transaction_hash::MaybeTxn # the winner's record
    detail::String
end

function LostRaceError(;
        location = nothing, chain_id = nothing, slot = nothing, transaction_hash = nothing,
        detail = ""
    )
    winner = maybe_hash(TransactionHash, transaction_hash)
    return LostRaceError(location, chain_id, slot, winner, detail)
end

function Base.showerror(io::IO, e::LostRaceError)
    print_summary(io, e, "another client's record already fills the slot")
    print_evidence(io, e)
    print(
        io, "\nThis call is spent and never retried. For a commit: `sync!(copy)` and ",
        "build again with `write_builder(copy)`. For `create_chain`: open the existing ",
        "chain with `open(chain, path)`, or create under another prefix."
    )
    return nothing
end

"""
    CommitOutcomeUnknownError

A commit failed after the put of its record began, so it is unknown whether the commit
happened. After `sync!(copy)`, it happened exactly when `commit_log(copy)` shows
`transaction_hash` at `slot`. The builder is spent.
"""
struct CommitOutcomeUnknownError <: ChainTablesError
    chain_id::MaybeString
    slot::MaybeInt
    transaction_hash::MaybeTxn # our record's
    landed::Union{Nothing, Bool} # `true`: the record is known to be in the chain
    # Downstream packages read `cause` to report and settle the outcome; the exception
    # stack is gone once they store the error.
    # style: field the failure may be any exception type
    cause::Any
    detail::String
end

function CommitOutcomeUnknownError(;
        chain_id = nothing, slot = nothing, transaction_hash = nothing, landed = nothing,
        cause = nothing, detail = ""
    )
    ours = maybe_hash(TransactionHash, transaction_hash)
    return CommitOutcomeUnknownError(chain_id, slot, ours, landed, cause, detail)
end

function Base.showerror(io::IO, e::CommitOutcomeUnknownError)
    print_summary(io, e, "the commit may or may not have happened")
    print_evidence(io, e)
    print(
        io, "\nRun `sync!(copy)`: the commit happened exactly when `commit_log(copy)` ",
        "shows `transaction_hash` at `slot`. This builder is spent and never re-run."
    )
    return nothing
end

"""
    UnsupportedStoreError

A commit was refused because the store is not AWS S3, the only store whose conditional
put ChainTables trusts. Use AWS S3, or set `assume_first_writer_wins` for a store you
know keeps that promise.
"""
struct UnsupportedStoreError <: ChainTablesError
    endpoint::MaybeString
    call::MaybeString
    detail::String
end

function UnsupportedStoreError(; endpoint = nothing, call = nothing, detail = "")
    return UnsupportedStoreError(endpoint, call, detail)
end

function Base.showerror(io::IO, e::UnsupportedStoreError)
    print_summary(io, e, "the store is not AWS S3, so a commit to it is refused")
    print_evidence(io, e)
    print(
        io, "\nA conditional put (`If-None-Match: *`) must create the key or fail with ",
        "412, and never overwrite. Use AWS S3, or set `assume_first_writer_wins = true` ",
        "for a store you know keeps that promise."
    )
    return nothing
end

"""
    WriteBuilderError

A write builder call or a commit was refused: a wrong table, column, row or key, a
spent or empty builder, or a record over the size cap. Fix the call `call` names.
"""
struct WriteBuilderError <: ChainTablesError
    call::MaybeString
    detail::String
end

WriteBuilderError(; call = nothing, detail = "") = WriteBuilderError(call, detail)

function Base.showerror(io::IO, e::WriteBuilderError)
    print_summary(io, e, "the write was refused")
    print_evidence(io, e)
    print(io, "\nFix the call named above; nothing was written.")
    return nothing
end

"""
    ChainNotFoundError

There is no slot 0 at the chain's bucket and prefix. Either the bucket or prefix is
not the chain's, or no chain was created there; the two cannot be told apart. Check
the address, or call `create_chain(chain)`.
"""
struct ChainNotFoundError <: ChainTablesError
    bucket::MaybeString
    prefix::MaybeString
    call::MaybeString
    detail::String
end

function ChainNotFoundError(;
        bucket = nothing, prefix = nothing, call = nothing, detail = ""
    )
    return ChainNotFoundError(bucket, prefix, call, detail)
end

function Base.showerror(io::IO, e::ChainNotFoundError)
    print_summary(io, e, "no chain at this bucket and prefix (no slot 0)")
    print_evidence(io, e)
    print(
        io, "\nEither the bucket or prefix is not the chain's, or no chain was created ",
        "there; the two cannot be told apart. Check the address, or call ",
        "`create_chain(chain)`, which writes slot 0."
    )
    return nothing
end

"""
    RewrittenChainError

The bucket contradicts what the local copy has applied: a slot holds bytes of another
hash, an applied slot is absent, or a record names a parent the copy does not hold.
Never healed; the copy stays readable. Stop and find out who rewrote the chain.
"""
struct RewrittenChainError <: ChainTablesError
    chain_id::MaybeString
    slot::MaybeInt
    expected::MaybeTxn
    found::MaybeTxn # `nothing` when the slot was absent
    detail::String
end

function RewrittenChainError(;
        chain_id = nothing, slot = nothing, expected = nothing, found = nothing,
        detail = ""
    )
    expected_hash = maybe_hash(TransactionHash, expected)
    found_hash = maybe_hash(TransactionHash, found)
    return RewrittenChainError(chain_id, slot, expected_hash, found_hash, detail)
end

function Base.showerror(io::IO, e::RewrittenChainError)
    print_summary(io, e, "the chain contradicts what this local copy has applied")
    print_evidence(io, e)
    print(
        io, "\nA slot is written once, so someone rewrote the chain outside the ",
        "protocol. Nothing is healed and the copy stays readable; find out who wrote it."
    )
    return nothing
end

"""
    MalformedRecordError

A record that no client can apply under this format version. The chain cannot be
read beyond `slot`. `op` is the 1-based index of the op that broke a rule, when it was
an op's. Report it to whoever writes to the chain.
"""
struct MalformedRecordError <: ChainTablesError
    chain_id::MaybeString
    slot::MaybeInt
    op::MaybeInt
    detail::String
end

function MalformedRecordError(;
        chain_id = nothing, slot = nothing, op = nothing, detail = ""
    )
    return MalformedRecordError(chain_id, slot, op, detail)
end

function Base.showerror(io::IO, e::MalformedRecordError)
    print_summary(io, e, "the record cannot be applied under this format version")
    print_evidence(io, e)
    print(io, "\nThe chain cannot be read beyond this slot; report it to its writers.")
    return nothing
end

const WRITE_REFUSED_NEXT_MOVES = Dict(
    "not_allowed" => "Ask the bucket's operator to add this author to the gateway policy.",
    "author_mismatch" => "The record's author is not the caller; report it as a bug.",
    "forbidden" => "Ask the operator for the writer permission set (InvokeFunctionUrl).",
)

"""
    WriteRefusedError

The gateway refused to fill a slot, and nothing is retried. `reason` says who must
act: `"not_allowed"` (the policy has no entry for this author), `"author_mismatch"` (a
bug) or `"forbidden"` (the principal may not invoke the gateway).
"""
struct WriteRefusedError <: ChainTablesError
    chain_id::MaybeString
    slot::MaybeInt
    key::MaybeString
    caller::MaybeString # the author name this client resolved for itself
    reason::MaybeString
    detail::String
end

function WriteRefusedError(;
        chain_id = nothing, slot = nothing, key = nothing, caller = nothing,
        reason = nothing, detail = ""
    )
    return WriteRefusedError(chain_id, slot, key, caller, reason, detail)
end

function Base.showerror(io::IO, e::WriteRefusedError)
    print_summary(io, e, "the gateway refused the write")
    print_evidence(io, e)
    fallback = "A person must act before a retry can succeed."
    print(io, "\n", get(WRITE_REFUSED_NEXT_MOVES, something(e.reason, ""), fallback))
    return nothing
end

"""
    GatewayMismatchError

The gateway answered `created`, but the bucket this chain reads does not hold the
object: the gateway fills another bucket. Nothing is retried. Pair the bucket with
its own gateway, as one `Bucket` value.
"""
struct GatewayMismatchError <: ChainTablesError
    chain_id::MaybeString
    slot::MaybeInt
    key::MaybeString
    bucket::MaybeString
    gateway::MaybeString
    detail::String
end

function GatewayMismatchError(;
        chain_id = nothing, slot = nothing, key = nothing, bucket = nothing,
        gateway = nothing, detail = ""
    )
    return GatewayMismatchError(chain_id, slot, key, bucket, gateway, detail)
end

function Base.showerror(io::IO, e::GatewayMismatchError)
    print_summary(io, e, "the gateway wrote to another bucket than this chain's")
    print_evidence(io, e)
    print(
        io, "\nThe object now sits in the gateway's own bucket. Pair the bucket with ",
        "its own gateway, as one `Bucket` value."
    )
    return nothing
end

"""
    TransportError

A request to the object store, the gateway or STS failed: no answer, or an answer
that is neither success nor a refusal the package names. `status` is the HTTP status,
`nothing` when there was no answer. Retry later, or fix the network.
"""
struct TransportError <: ChainTablesError
    status::MaybeInt
    detail::String
end

TransportError(detail::AbstractString; status = nothing) = TransportError(status, detail)

function Base.showerror(io::IO, e::TransportError)
    print_summary(io, e, "a request failed")
    print_evidence(io, e)
    print(io, "\nCheck the network and the store, then try again.")
    return nothing
end
