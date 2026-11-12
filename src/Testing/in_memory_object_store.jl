# Over 8 lines: the fields a test sets and reads are this type's whole interface.
"""
    InMemoryObjectStore(; clock, fault, seed) <: AbstractObjectStore

An object store that keeps its objects in memory, for tests that must not reach AWS.

A put to an existing key is refused with `412` and never overwrites. Absent is `nothing`,
and a failure throws. Listings come back shuffled, so a test that relies on their order
fails. `modified` is whole seconds, and prefixes match by bytes. Each store is its own
record-cache namespace.

- `clock`: returns whole seconds since the epoch, stamped on each put. Default: the wall
  clock.
- `fault`: `fault(verb, key, phase)` is called with `phase = :before` on every request
  and `:after` once the store has acted. Throw from it to simulate a failure: at
  `:before` the request never lands; at `:after` it landed and the reply was lost. A
  field: assign another function at any time. Default: does nothing.
- `seed`: seeds the listing shuffle, so a test can reproduce one order.

`calls` holds every request as `(verb, key)`, in order; `objects` and `modified` hold the
bytes and the stamps by key.

Examples: test/test_testing_in_memory_object_store_examples.jl
"""
mutable struct InMemoryObjectStore{C} <: AbstractObjectStore
    const objects::Dict{String, Vector{UInt8}}
    const modified::Dict{String, Int64}
    const calls::Vector{Tuple{Symbol, String}}
    const namespace::String # the record cache's directory for this store (ADR-0040)
    const clock::C
    # style: field users assign a fault function of any type at any time
    fault::Any
    state::UInt64 # the xorshift64 state of the listing shuffle
end

function InMemoryObjectStore(;
        clock = wall_clock_seconds, fault = ignore_request, seed = hash(time_ns())
    )
    namespace = "mem-" * string(rand(UInt32); base = 16, pad = 8)
    # xorshift64 needs a non-zero state.
    state = UInt64(seed) | UInt64(1)
    return InMemoryObjectStore{typeof(clock)}(
        Dict{String, Vector{UInt8}}(), Dict{String, Int64}(), Tuple{Symbol, String}[],
        namespace, clock, fault, state
    )
end

wall_clock_seconds() = floor(Int64, time())
ignore_request(verb, key, phase) = nothing

ChainTables.cache_namespace(store::InMemoryObjectStore) = store.namespace

function ChainTables.fetch_object(store::InMemoryObjectStore, key::AbstractString)
    key = String(key)
    begin_request!(store, :fetch_object, key)
    bytes = haskey(store.objects, key) ? copy(store.objects[key]) : nothing
    end_request(store, :fetch_object, key)
    return bytes
end

function ChainTables.put_object_if_absent(
        store::InMemoryObjectStore, key::AbstractString, bytes
    )
    key = String(key)
    begin_request!(store, :put_object_if_absent, key)
    # A copy, so the caller's later writes to `bytes` never reach the store.
    created = store_if_absent!(store, key, Vector{UInt8}(bytes))
    end_request(store, :put_object_if_absent, key)
    return created ? PutOutcome(true, 200) : PutOutcome(false, 412)
end

# S3 refuses bytes that do not hash to the key's hash as BadDigest; so does this store.
function ChainTables.put_attachment(store::InMemoryObjectStore, key::AbstractString, io::IO)
    key = String(key)
    hash = attachment_hash(key)
    stream_size(io)
    begin_request!(store, :put_attachment, key)
    bytes = read(io)
    detail = "an InMemoryObjectStore answered BadDigest"
    bytes2hex(sha256(bytes)) == hash.hex || throw(AttachmentChangedError(; key, detail))
    created = store_if_absent!(store, key, bytes)
    end_request(store, :put_attachment, key)
    return created
end

function ChainTables.fetch_object_to(
        store::InMemoryObjectStore, key::AbstractString, path::AbstractString
    )
    key = String(key)
    begin_request!(store, :fetch_object_to, key)
    bytes = get(store.objects, key, nothing)
    bytes === nothing || write(path, bytes)
    end_request(store, :fetch_object_to, key)
    return bytes === nothing ? nothing : Int64(length(bytes))
end

function ChainTables.stat_object(store::InMemoryObjectStore, key::AbstractString)
    key = String(key)
    begin_request!(store, :stat_object, key)
    meta = haskey(store.objects, key) ? object_meta(store, key) : nothing
    end_request(store, :stat_object, key)
    return meta
end

function ChainTables.list_objects(
        store::InMemoryObjectStore, prefix::AbstractString;
        start_after::Union{Nothing, AbstractString} = nothing
    )
    prefix = String(prefix)
    after = start_after === nothing ? nothing : String(start_after)
    begin_request!(store, :list_objects, prefix)
    listed = [
        object_meta(store, key)
            for key in keys(store.objects) if is_listed(key, prefix, after)
    ]
    shuffle_listing!(store, listed)
    end_request(store, :list_objects, prefix)
    return listed
end

function begin_request!(store::InMemoryObjectStore, verb::Symbol, key::String)
    push!(store.calls, (verb, key))
    store.fault(verb, key, :before)
    return nothing
end

function end_request(store::InMemoryObjectStore, verb::Symbol, key::String)
    store.fault(verb, key, :after)
    return nothing
end

function store_if_absent!(store::InMemoryObjectStore, key::String, bytes::Vector{UInt8})
    haskey(store.objects, key) && return false
    store.objects[key] = bytes
    store.modified[key] = Int64(store.clock())
    return true
end

function object_meta(store::InMemoryObjectStore, key::String)
    return ObjectMeta(key, length(store.objects[key]), store.modified[key])
end

# `cmp` of two Strings compares bytes, as S3 orders keys.
function is_listed(key::String, prefix::String, after::Union{Nothing, String})
    return startswith_bytes(key, prefix) && (after === nothing || cmp(key, after) > 0)
end

# Fisher–Yates over an xorshift64 kept in the store, so shuffling needs no Random
# dependency and a seed reproduces an order.
function shuffle_listing!(store::InMemoryObjectStore, listed::Vector)
    for i in length(listed):-1:2
        j = Int(next_random!(store) % UInt64(i)) + 1
        listed[i], listed[j] = listed[j], listed[i]
    end
    return listed
end

function next_random!(store::InMemoryObjectStore)
    x = store.state
    x ⊻= x << 13
    x ⊻= x >> 7
    x ⊻= x << 17
    store.state = x
    return x
end
