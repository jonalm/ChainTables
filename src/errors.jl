# ADR-0020 (errors are types, the message is the contract). Every lane raises these
# types; #34 step 7 completed the taxonomy with the evidence fields, step 8 typed the hashes.
#
# Each type carries `msg` — the three-part message: what happened in the glossary's
# words, the evidence, the next move naming the function — and the same evidence as
# fields, so a caller can branch on the type and read the chain id, slot and hashes
# without parsing text. Every evidence field is keyword-optional and `nothing` when
# the raiser does not know it; a hash is a `TransactionHash` or a `StateFingerprint`
# (ADR-0019), built from the raw 32 bytes a raiser passes.

"""
    ChainTablesError <: Exception

Abstract supertype of every error ChainTables raises (ADR-0020). Every concrete type
holds `msg`, the message that is the contract, and its evidence as fields.
"""
abstract type ChainTablesError <: Exception end

"""
    AbstractObjectStore

The object-store port: fetch one object, put one object only if its key is absent,
stat one key, list a prefix (ADR-0010, ADR-0019). Declared here rather than in
`store.jl` so the local-copy lane can dispatch on it before the store lane lands.
"""
abstract type AbstractObjectStore end

const MaybeTxn = Union{Nothing,TransactionHash}
const MaybeFp = Union{Nothing,StateFingerprint}
const MaybeString = Union{Nothing,String}
const MaybeInt = Union{Nothing,Int64}

"""
    StaleHeadError(msg; chain_id, slot, chain_slot)

Raised by `commit!`: the builder's head is behind the local copy's or the chain's
(ADR-0002, ADR-0013). `slot` is the builder's head, `chain_slot` where the chain was
seen, `nothing` when unknown. Next move: `sync!(copy)`, recompute the row set, build again.
"""
struct StaleHeadError <: ChainTablesError
    msg::String
    chain_id::MaybeString
    slot::MaybeInt
    chain_slot::MaybeInt
end
StaleHeadError(msg; chain_id = nothing, slot = nothing, chain_slot = nothing) =
    StaleHeadError(msg, chain_id, slot, chain_slot)

"""
    LostRaceError(msg; chain_id, slot, transaction_hash)

Raised by `commit!` and `create_chain`: another client's record is at `slot`, and
`transaction_hash` is its hash (ADR-0002, ADR-0010). Never retried: the builder is spent.
"""
struct LostRaceError <: ChainTablesError
    msg::String
    chain_id::MaybeString
    slot::MaybeInt
    transaction_hash::MaybeTxn
end
LostRaceError(msg; chain_id = nothing, slot = nothing, transaction_hash = nothing) =
    LostRaceError(msg, chain_id, slot, maybe_hash(TransactionHash, transaction_hash))

"""
    UnsupportedStoreError(msg; endpoint)

Raised by `commit!` against a store that is not AWS S3 unless
`assume_first_writer_wins` is set (ADR-0016). Raised by #34 step 9.
"""
struct UnsupportedStoreError <: ChainTablesError
    msg::String
    endpoint::MaybeString
end
UnsupportedStoreError(msg; endpoint = nothing) = UnsupportedStoreError(msg, endpoint)

"""
    WriteBuilderError(msg)

Raised by the write builder in the call that is wrong, and by `commit!` for the
state gate, a spent or empty builder, or a record over the cap (ADR-0001, ADR-0019).
The message starts with the call to fix; that is the whole evidence.
"""
struct WriteBuilderError <: ChainTablesError
    msg::String
end

"""
    PinnedCopyError(msg; path, slot)

Raised by `sync!` and `commit!` on a pinned copy (ADR-0015). Next move: `unpin!(copy)`.
"""
struct PinnedCopyError <: ChainTablesError
    msg::String
    path::MaybeString
    slot::MaybeInt
end
PinnedCopyError(msg; path = nothing, slot = nothing) = PinnedCopyError(msg, path, slot)

"""
    FingerprintMismatchError(msg; chain_id, slot, expected, computed, record_client, this_client)

Raised at a checkpoint, by the commit and `as_of` pre-checks and by `verify`: the
record's `state_fingerprint` (`expected`) against what this client holds or computes
(`computed`) (ADR-0007, ADR-0023); from `verify(copy)` without `full`, the head's
fingerprint against the one its table files hash to, `computed = nothing` when a file
is missing. `record_client` and `this_client` are `(; lib, julia)` — the forensics
ADR-0006 and ADR-0022 named — when known. Next move: `repair!(copy)`.
"""
struct FingerprintMismatchError <: ChainTablesError
    msg::String
    chain_id::MaybeString
    slot::MaybeInt
    expected::MaybeFp
    computed::MaybeFp
    record_client::Any
    this_client::Any
end
FingerprintMismatchError(msg; chain_id = nothing, slot = nothing, expected = nothing, computed = nothing,
                         record_client = nothing, this_client = nothing) =
    FingerprintMismatchError(msg, chain_id, slot, maybe_hash(StateFingerprint, expected), maybe_hash(StateFingerprint, computed),
                             record_client, this_client)

"""
    DivergenceError(msg; chain_id, slot, expected, computed)

Raised by `repair!`: a fresh replay of the record cache to the head's `slot` yields
`computed`, the head carries `expected`, so this machine cannot reproduce the chain
(ADR-0014). Deliberately does not say which side is right.
"""
struct DivergenceError <: ChainTablesError
    msg::String
    chain_id::MaybeString
    slot::MaybeInt
    expected::MaybeFp
    computed::MaybeFp
end
DivergenceError(msg; chain_id = nothing, slot = nothing, expected = nothing, computed = nothing) =
    DivergenceError(msg, chain_id, slot, maybe_hash(StateFingerprint, expected), maybe_hash(StateFingerprint, computed))

"""
    RewrittenChainError(msg; chain_id, slot, expected, found)

Raised by `sync!` and `commit!`: the bucket contradicts what the copy has applied — a
slot fetching bytes of another hash, an applied slot absent, or a record naming a parent
the copy does not hold (ADR-0014). `found` is the hash fetched, `nothing` when the slot
was absent. Never healed; the copy stays readable.
"""
struct RewrittenChainError <: ChainTablesError
    msg::String
    chain_id::MaybeString
    slot::MaybeInt
    expected::MaybeTxn
    found::MaybeTxn
end
RewrittenChainError(msg; chain_id = nothing, slot = nothing, expected = nothing, found = nothing) =
    RewrittenChainError(msg, chain_id, slot, maybe_hash(TransactionHash, expected), maybe_hash(TransactionHash, found))

"""
    ChainNotFoundError(msg; bucket, prefix)

Raised by `sync!` on a copy with no head against a prefix with no slot 0: a wrong bucket
or prefix, **or** a chain not created or truncated — deliberately uncertain (ADR-0019,
ADR-0020).
"""
struct ChainNotFoundError <: ChainTablesError
    msg::String
    bucket::MaybeString
    prefix::MaybeString
end
ChainNotFoundError(msg; bucket = nothing, prefix = nothing) = ChainNotFoundError(msg, bucket, prefix)

"""
    NotALocalCopyError(msg; path)

Raised by `open`: `path` is not a local copy of ours (ADR-0023).
"""
struct NotALocalCopyError <: ChainTablesError
    msg::String
    path::MaybeString
end
NotALocalCopyError(msg; path = nothing) = NotALocalCopyError(msg, path)

"""
    LayoutVersionError(msg; path, file)

Raised by `open`: head `file` of the copy at `path` was written by a newer client
(ADR-0023). Rebuild, never migrate — or upgrade.
"""
struct LayoutVersionError <: ChainTablesError
    msg::String
    path::MaybeString
    file::MaybeString
end
LayoutVersionError(msg; path = nothing, file = nothing) = LayoutVersionError(msg, path, file)

"""
    WrongChainError(msg; path, bound, opened)

Raised by `open`: the copy at `path` is bound to chain `bound`, the chain being opened
is `opened` (ADR-0023).
"""
struct WrongChainError <: ChainTablesError
    msg::String
    path::MaybeString
    bound::MaybeString
    opened::MaybeString
end
WrongChainError(msg; path = nothing, bound = nothing, opened = nothing) = WrongChainError(msg, path, bound, opened)

"""
    LocalCopyInconsistentError(msg; path, slot, file)

Raised by `open` and at load: a damaged copy — a head not self-consistent, a named file
missing, or a table file whose bytes do not hash to its name (ADR-0023). `file` is the
offending file relative to `path`, when there is one. Next move: `repair!(copy)`, or, with
no readable head, delete the directory and sync.
"""
struct LocalCopyInconsistentError <: ChainTablesError
    msg::String
    path::MaybeString
    slot::MaybeInt
    file::MaybeString
end
LocalCopyInconsistentError(msg; path = nothing, slot = nothing, file = nothing) =
    LocalCopyInconsistentError(msg, path, slot, file)

"""
    MalformedRecordError(msg; chain_id, slot, op)

Raised at apply and on decoding: a record no client can apply under this format
version (ADR-0025). `op` is the 1-based index of the op that broke the rule, when the
rule was an op's. The chain is dead beyond `slot`.
"""
struct MalformedRecordError <: ChainTablesError
    msg::String
    chain_id::MaybeString
    slot::MaybeInt
    op::MaybeInt
end
MalformedRecordError(msg; chain_id = nothing, slot = nothing, op = nothing) = MalformedRecordError(msg, chain_id, slot, op)

"""
    WriteRefusedError(msg; chain_id, slot, key, caller, reason)

Raised by `commit!` and `create_chain` on a gateway bucket: the gateway refused to fill
the slot, and nothing is retried (ADR-0028). `key` is the slot's key, `caller` the author
name this client resolved for itself, and `reason` says who must act:

| `reason` | cause | next move |
|---|---|---|
| `"not_allowed"` | the gateway policy has no entry for this name on this prefix, or the principal is not a user or assumed role | ask the bucket's operator to add the name to the gateway policy |
| `"author_mismatch"` | `client.user` ≠ the caller name | a bug, or credentials changed between the STS call and the put; report it |
| `"forbidden"` | AWS returned 403 before the gateway ran | the principal lacks `lambda:InvokeFunctionUrl` and `lambda:InvokeFunction`; ask the operator for the writer permission set |

One type with a `reason` rather than three: the caller's branch is the same in every case —
stop, and have a person act.
"""
struct WriteRefusedError <: ChainTablesError
    msg::String
    chain_id::MaybeString
    slot::MaybeInt
    key::MaybeString
    caller::MaybeString
    reason::MaybeString
end
WriteRefusedError(msg; chain_id = nothing, slot = nothing, key = nothing, caller = nothing, reason = nothing) =
    WriteRefusedError(msg, chain_id, slot, key, caller, reason)

"""
    GatewayMismatchError(msg; chain_id, slot, key, bucket, gateway)

Raised by `commit!` and `create_chain` on a gateway bucket: the gateway answered
`200 created` and the bucket this chain reads does not hold the slot — the gateway fills
another bucket than the one named (ADR-0029). Nothing is retried, and the record now sits
in the gateway's own bucket, where no delete can reach it. The next move is the
configuration's: pair the bucket with its own gateway, as one [`Bucket`](@ref) value.
"""
struct GatewayMismatchError <: ChainTablesError
    msg::String
    chain_id::MaybeString
    slot::MaybeInt
    key::MaybeString
    bucket::MaybeString
    gateway::MaybeString
end
GatewayMismatchError(msg; chain_id = nothing, slot = nothing, key = nothing, bucket = nothing, gateway = nothing) =
    GatewayMismatchError(msg, chain_id, slot, key, bucket, gateway)

# The message is the contract (ADR-0020): every type shows as its message, so a
# `@test_throws "…"` matches the text a user reads.
Base.showerror(io::IO, e::ChainTablesError) = print(io, nameof(typeof(e)), ": ", e.msg)
