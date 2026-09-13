# #34 step 6 — ADR-0019, ADR-0010, ADR-0016: `Testing.InMemoryObjectStore`, the faithful
# double and the submodule's only member. Anything else added here becomes a second API
# to keep stable (ADR-0019), so fixture behaviour is a field of the store, never a helper.
"""
    Testing

Holds [`InMemoryObjectStore`](@ref), the in-process object store a user testing their
own ChainTables-backed code runs against instead of AWS (ADR-0019). Nothing else.
"""
module Testing

import ..AbstractObjectStore, ..PutOutcome, ..ObjectMeta
import ..fetch_object, ..put_object_if_absent, ..stat_object, ..list_objects, ..startswith_bytes

"""
    InMemoryObjectStore(; clock, fault, seed) <: AbstractObjectStore

The faithful in-process double of the object-store port (ADR-0010, ADR-0019): a
single-threaded dictionary behind the four verbs, which is a stronger guarantee than any
real store and satisfies ADR-0016's minimum backend contract by construction —
`put_object_if_absent` refuses an existing key with a `412` and never overwrites, and a
`fetch_object` of a key just created returns it. Absent is `nothing` and failure raises,
never conflated; listings come back **shuffled**, so a test that relies on their order
fails; `modified` is whole seconds and ties within a second; prefixes match by bytes.

Fields a test may set:
- `clock`: a callable returning whole seconds since the epoch, stamped on each put.
  Default is the wall clock.
- `fault`: `fault(verb::Symbol, key::String, phase::Symbol)`, called with `:before` on
  every request and with `:after` once the store has acted, before the response is
  returned. Throw from it to simulate a failure: at `:before` the request never lands,
  at `:after` it landed but the acknowledgement was lost (ADR-0002's ambiguous outcome).
  Default does nothing.
- `seed`: seeds the listing shuffle, so a test can reproduce one order. Default varies.

`calls` records every request as `(verb, key)` in order, for asserting that an
operation made none (`open`, ADR-0023) or how many (galloping, ADR-0012). `objects`
and `modified` hold the bytes and stamps by key and are the store's own copies.
"""
mutable struct InMemoryObjectStore <: AbstractObjectStore
    const objects::Dict{String,Vector{UInt8}}
    const modified::Dict{String,Int64}
    const calls::Vector{Tuple{Symbol,String}}
    clock::Any
    fault::Any
    state::UInt64
end

function InMemoryObjectStore(; clock = () -> floor(Int64, time()),
                             fault = (verb, key, phase) -> nothing,
                             seed = hash(time_ns()))
    state = UInt64(seed) | UInt64(1)   # xorshift needs a non-zero state
    return InMemoryObjectStore(Dict{String,Vector{UInt8}}(), Dict{String,Int64}(),
                               Tuple{Symbol,String}[], clock, fault, state)
end

function _request!(store::InMemoryObjectStore, verb::Symbol, key::String)
    push!(store.calls, (verb, key))
    store.fault(verb, key, :before)
    return nothing
end
_respond!(store::InMemoryObjectStore, verb::Symbol, key::String) = (store.fault(verb, key, :after); nothing)

function fetch_object(store::InMemoryObjectStore, key::AbstractString)
    key = String(key)
    _request!(store, :fetch_object, key)
    bytes = haskey(store.objects, key) ? copy(store.objects[key]) : nothing
    _respond!(store, :fetch_object, key)
    return bytes
end

function put_object_if_absent(store::InMemoryObjectStore, key::AbstractString, bytes)
    key = String(key)
    _request!(store, :put_object_if_absent, key)
    if haskey(store.objects, key)
        outcome = PutOutcome(false, 412)          # ADR-0016 rules 1 and 2: refused, never overwritten
    else
        store.objects[key] = Vector{UInt8}(bytes)
        store.modified[key] = Int64(store.clock())
        outcome = PutOutcome(true, 200)
    end
    _respond!(store, :put_object_if_absent, key)
    return outcome
end

function stat_object(store::InMemoryObjectStore, key::AbstractString)
    key = String(key)
    _request!(store, :stat_object, key)
    meta = haskey(store.objects, key) ?
        ObjectMeta(key, length(store.objects[key]), store.modified[key]) : nothing
    _respond!(store, :stat_object, key)
    return meta
end

function list_objects(store::InMemoryObjectStore, prefix::AbstractString;
                      start_after::Union{Nothing,AbstractString} = nothing)
    prefix = String(prefix)
    _request!(store, :list_objects, prefix)
    listed = ObjectMeta[]
    for (key, bytes) in store.objects
        startswith_bytes(key, prefix) || continue
        start_after !== nothing && cmp(key, String(start_after)) <= 0 && continue
        push!(listed, ObjectMeta(key, length(bytes), store.modified[key]))
    end
    _shuffle!(store, listed)
    _respond!(store, :list_objects, prefix)
    return listed
end

# Internal helpers are underscored: the submodule's one member is the store (ADR-0019).
# Fisher–Yates over an xorshift64 kept in the store, so shuffling needs no Random
# dependency and a seed reproduces an order.
function _next!(store::InMemoryObjectStore)
    x = store.state
    x ⊻= x << 13
    x ⊻= x >> 7
    x ⊻= x << 17
    store.state = x
    return x
end
function _shuffle!(store::InMemoryObjectStore, v::Vector)
    for i in length(v):-1:2
        j = Int(_next!(store) % UInt64(i)) + 1
        v[i], v[j] = v[j], v[i]
    end
    return v
end

end # module Testing
