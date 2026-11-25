using ChainTables: ChainTables, AbstractObjectStore, Ops, PutOutcome, fetch_object,
    stat_object
using ChainTables.Testing: InMemoryObjectStore

# A store that implements nothing.
struct BareStore <: AbstractObjectStore end

# A store that names its own record cache namespace.
struct NamedStore <: AbstractObjectStore
    namespace::String
end

ChainTables.cache_namespace(store::NamedStore) = store.namespace

# A store whose put always answers `412` while nothing is ever there.
struct Phantom412Store <: AbstractObjectStore
    inner::InMemoryObjectStore
end

function ChainTables.cache_namespace(store::Phantom412Store)
    return ChainTables.cache_namespace(store.inner)
end

ChainTables.put_object_if_absent(::Phantom412Store, key, bytes) = PutOutcome(false, 412)
ChainTables.fetch_object(store::Phantom412Store, key) = fetch_object(store.inner, key)
ChainTables.stat_object(store::Phantom412Store, key) = stat_object(store.inner, key)

# A store that reports a refused put with a status that no store may answer.
struct BadOutcomeStore <: AbstractObjectStore end

ChainTables.cache_namespace(::BadOutcomeStore) = "bad"
ChainTables.put_object_if_absent(::BadOutcomeStore, key, bytes) = PutOutcome(false, 200)

# Bytes whose write fails part-way, as a crash in the middle of a fetch does.
struct TruncatedBytes <: AbstractVector{UInt8}
    n::Int
    n_written::Int
end

Base.size(bytes::TruncatedBytes) = (bytes.n,)

function Base.getindex(bytes::TruncatedBytes, i::Int)
    i <= bytes.n_written || throw(ErrorException("write interrupted at byte $i"))
    return UInt8(i)
end

# A fault hook of `InMemoryObjectStore`: the first `remaining` puts never arrive, and
# each fails with `failure`.
mutable struct LostPuts{E}
    remaining::Int
    const failure::E
end

function (fault::LostPuts)(verb, key, phase)
    verb === :put_object_if_absent && phase === :before || return nothing
    fault.remaining > 0 || return nothing
    fault.remaining -= 1
    throw(fault.failure)
end

# A fault hook of `InMemoryObjectStore`: `action()` runs at `phase` of each request of
# `verb` on `key`, or on any key when `key` is `nothing`.
struct FaultAt{F}
    verb::Symbol
    key::Union{Nothing, String}
    phase::Symbol
    action::F
end

function (fault::FaultAt)(verb, key, phase)
    verb === fault.verb && phase === fault.phase || return nothing
    fault.key === nothing || fault.key == key || return nothing
    fault.action()
    return nothing
end

no_fault(verb, key, phase) = nothing

slot_key(slot) = "p/" * lpad(slot, 12, '0')

# The file that the record cache of `chain` holds for `slot`.
function record_file(chain, slot)
    return ChainTables.record_path(chain.cache, chain.store, "bkt", slot_key(slot))
end

# The transaction hash of the record that `store` holds at `slot`.
stored_hash(store, slot) = Ops.transaction_hash(store.objects[slot_key(slot)])

# An object placed in the store behind its back, as a writer outside the protocol would.
function plant!(store::InMemoryObjectStore, key, bytes)
    store.objects[key] = bytes
    store.modified[key] = 0
    return nothing
end

function empty_store!(store::InMemoryObjectStore)
    empty!(store.objects)
    empty!(store.modified)
    return nothing
end

# Every object of `from`, planted in `to`.
function copy_objects!(to::InMemoryObjectStore, from::InMemoryObjectStore)
    foreach(key -> plant!(to, key, copy(from.objects[key])), collect(keys(from.objects)))
    return nothing
end

n_requests(store, verb, key) = count(==((verb, key)), store.calls)

# The keys fetched after the first `n` requests, in request order.
function fetched_after(store, n)
    return [key for (verb, key) in store.calls[(n + 1):end] if verb === :fetch_object]
end

# A store that reads through `inner`, except that the object at `key` is cut off after
# 10 of its 20 bytes.
struct CutStore <: AbstractObjectStore
    inner::InMemoryObjectStore
    key::String
end

ChainTables.cache_namespace(::CutStore) = "cut"
ChainTables.stat_object(store::CutStore, key) = stat_object(store.inner, key)

function ChainTables.fetch_object(store::CutStore, key)
    return key == store.key ? TruncatedBytes(20, 10) : fetch_object(store.inner, key)
end
