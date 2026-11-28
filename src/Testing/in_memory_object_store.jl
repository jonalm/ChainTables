# style: field a test sets `fault` mid-test to a function of a new type; a type
# parameter for `clock` would make `Chain{InMemoryObjectStore}` name no chain
# The docstring is over 8 lines: the rules that a test relies on, and each keyword.
"""
    InMemoryObjectStore(; clock = () -> floor(Int64, time()),
                        fault = (verb, key, phase) -> nothing, seed = hash(time_ns()))

An object store in memory that holds to the rules of S3 that ChainTables relies on: a
put never replaces a key, and a key just put can be fetched. Absent is `nothing` and a
failure throws. A listing comes back shuffled, so a test that relies on its order
fails; `modified` is whole seconds, so two puts can tie.

- `clock`: returns the whole seconds since the epoch that a put records.
- `fault`: called as `fault(verb, key, :before)` before each request acts and as
  `fault(verb, key, :after)` after it. To simulate a failure, throw from it: at
  `:before` nothing happens, at `:after` the request landed and its answer was lost. A
  test may set the field at any time.
- `seed`: the seed of the listing's shuffle, so that a test can repeat an order.

`objects` and `modified` hold the bytes and the times by key. `calls` records each
request as `(verb, key)`, in order. Each store has its own record cache.

Examples: test/test_testing_in_memory_object_store_examples.jl
"""
mutable struct InMemoryObjectStore <: AbstractObjectStore
    const objects::Dict{String, Vector{UInt8}}
    const modified::Dict{String, Int64}
    const calls::Vector{Tuple{Symbol, String}}
    const namespace::String  # the record cache's directory for this store (ADR-0040)
    const clock::Any
    fault::Any
    state::UInt64  # of the xorshift that shuffles listings
end

function InMemoryObjectStore(;
        clock = () -> floor(Int64, time()), fault = (verb, key, phase) -> nothing,
        seed = hash(time_ns()),
    )
    state = UInt64(seed) | UInt64(1)  # an xorshift needs a state that is not zero
    namespace = "mem-" * string(rand(UInt32); base = 16, pad = 8)
    return InMemoryObjectStore(
        Dict{String, Vector{UInt8}}(), Dict{String, Int64}(), Tuple{Symbol, String}[],
        namespace, clock, fault, state,
    )
end

ChainTables.cache_namespace(store::InMemoryObjectStore) = store.namespace

function ChainTables.fetch_object(store::InMemoryObjectStore, key::AbstractString)
    key = String(key)
    start_request!(store, :fetch_object, key)
    bytes = haskey(store.objects, key) ? copy(store.objects[key]) : nothing
    end_request(store, :fetch_object, key)
    return bytes
end

function ChainTables.put_object_if_absent(
        store::InMemoryObjectStore, key::AbstractString, bytes
    )
    key = String(key)
    start_request!(store, :put_object_if_absent, key)
    _is_new = !haskey(store.objects, key)
    _is_new && store_object!(store, key, Vector{UInt8}(bytes))
    end_request(store, :put_object_if_absent, key)
    return _is_new ? PutOutcome(true, 200) : PutOutcome(false, 412)
end

function ChainTables.stat_object(store::InMemoryObjectStore, key::AbstractString)
    key = String(key)
    start_request!(store, :stat_object, key)
    meta = haskey(store.objects, key) ? object_meta(store, key) : nothing
    end_request(store, :stat_object, key)
    return meta
end

function ChainTables.list_objects(
        store::InMemoryObjectStore, prefix::AbstractString;
        start_after::Union{Nothing, AbstractString} = nothing,
    )
    prefix = String(prefix)
    start_request!(store, :list_objects, prefix)
    listed = [
        object_meta(store, key) for key in keys(store.objects)
            if is_listed(key, prefix, start_after)
    ]
    shuffle_listing!(store, listed)
    end_request(store, :list_objects, prefix)
    return listed
end

# Like S3, the store refuses bytes that do not hash to the key (`BadDigest`).
function ChainTables.upload_attachment(
        store::InMemoryObjectStore, key::AbstractString, io::IO
    )
    upload = AttachmentUpload(key, io)
    start_request!(store, :put_attachment, upload.key)
    bytes = read(io)
    bytes2hex(sha256(bytes)) == upload.hash ||
        throw(AttachmentChangedError(; upload.key))
    _is_new = !haskey(store.objects, upload.key)
    _is_new && store_object!(store, upload.key, bytes)
    end_request(store, :put_attachment, upload.key)
    return _is_new
end

function ChainTables.fetch_object_to(
        store::InMemoryObjectStore, key::AbstractString, path::AbstractString
    )
    key = String(key)
    start_request!(store, :fetch_object_to, key)
    bytes = get(store.objects, key, nothing)
    bytes === nothing || write(path, bytes)
    end_request(store, :fetch_object_to, key)
    return bytes === nothing ? nothing : Int64(length(bytes))
end

function start_request!(store::InMemoryObjectStore, verb::Symbol, key::String)
    push!(store.calls, (verb, key))
    store.fault(verb, key, :before)
    return nothing
end

function end_request(store::InMemoryObjectStore, verb::Symbol, key::String)
    store.fault(verb, key, :after)
    return nothing
end

function store_object!(store::InMemoryObjectStore, key::String, bytes::Vector{UInt8})
    store.objects[key] = bytes
    store.modified[key] = Int64(store.clock())
    return nothing
end

function object_meta(store::InMemoryObjectStore, key::String)
    return ObjectMeta(key, length(store.objects[key]), store.modified[key])
end

function is_listed(key::String, prefix::String, start_after)
    startswith_bytes(key, prefix) || return false
    return start_after === nothing || cmp(key, String(start_after)) > 0
end

# Fisher–Yates over an xorshift64 kept in the store, so that shuffling needs no Random
# dependency and a seed repeats an order.
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
