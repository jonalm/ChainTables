# ADR-0020 (errors are types, the message is the contract); the evidence fields are
# added by #34 step 7, which completes the taxonomy. Every lane raises these types.
#
# Each type carries only `msg` for now. ADR-0020 §"The message contract" requires
# the evidence as fields too (chain id, slot, expected vs computed, client.lib /
# client.julia); step 7 adds them once the lanes have converged.

"""
    ChainTablesError <: Exception

Abstract supertype of every error ChainTables raises (ADR-0020).
"""
abstract type ChainTablesError <: Exception end

"""
    AbstractObjectStore

The object-store port: fetch one object, put one object only if its key is absent,
stat one key, list a prefix (ADR-0010, ADR-0019). Declared here rather than in
`store.jl` so the local-copy lane can dispatch on it before the store lane lands.
"""
abstract type AbstractObjectStore end

# commit
struct StaleHeadError <: ChainTablesError; msg::String; end
struct LostRaceError <: ChainTablesError; msg::String; end
struct UnsupportedStoreError <: ChainTablesError; msg::String; end

# the write builder
struct WriteBuilderError <: ChainTablesError; msg::String; end

# sync, commit
struct PinnedCopyError <: ChainTablesError; msg::String; end

# apply, commit pre-check / repair
struct FingerprintMismatchError <: ChainTablesError; msg::String; end
struct DivergenceError <: ChainTablesError; msg::String; end

# sync
struct RewrittenChainError <: ChainTablesError; msg::String; end
struct ChainNotFoundError <: ChainTablesError; msg::String; end

# open, load
struct NotALocalCopyError <: ChainTablesError; msg::String; end
struct LayoutVersionError <: ChainTablesError; msg::String; end
struct WrongChainError <: ChainTablesError; msg::String; end
struct LocalCopyInconsistentError <: ChainTablesError; msg::String; end

# apply
struct MalformedRecordError <: ChainTablesError; msg::String; end
