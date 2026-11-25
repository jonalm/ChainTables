"""
    AbstractObjectStore

The interface of an object store: fetch one object, put one object only if its key is
absent, stat one key, list a prefix.

A store of your own implements `fetch_object`, `put_object_if_absent`, `stat_object`,
`list_objects` and `cache_namespace`. No verb has a fallback, so a store that leaves one
out fails with a `MethodError` at the first call. There is no delete. A failed request
throws `TransportError`.
"""
abstract type AbstractObjectStore end

"""
    PutOutcome(created, status)

What `put_object_if_absent` reports. `created` is `true` when the key did not exist and
now holds the bytes, and `false` only for a `412 Precondition Failed`.

`status` is the HTTP status that the transport saw. Nothing in the protocol depends on
it: the read-back of the slot decides the outcome of a commit.

Examples: test/test_object_store_examples.jl
"""
struct PutOutcome
    created::Bool
    status::Int
end

"""
    ObjectMeta(key, size, modified)

What `stat_object` and `list_objects` report about one object: its key, its size in
bytes, and when it was last modified.

Examples: test/test_object_store_examples.jl
"""
struct ObjectMeta
    key::String
    size::Int64
    # Whole seconds since the Unix epoch, which is all that S3 promises. Two objects
    # written in one second tie, and nothing in the protocol orders by it.
    modified::Int64
end

"""
    fetch_object(store, key)

Return the bytes of the object at `key`, or `nothing` when no such key exists.

One request, with no retry inside. A failure throws; it never returns `nothing`.

Examples: test/test_object_store_examples.jl
"""
function fetch_object end

"""
    put_object_if_absent(store, key, bytes)

Create `key` with `bytes` if and only if no such key exists, and return a `PutOutcome`.

The outcome has `created = false` only for a `412`. A `409` and every other failure
throw. The store never replaces an existing key. This is the only verb that writes.

Examples: test/test_object_store_examples.jl
"""
function put_object_if_absent end

"""
    stat_object(store, key)

Return the `ObjectMeta` of `key`, or `nothing` when no such key exists.

One request. A failure throws.

Examples: test/test_object_store_examples.jl
"""
function stat_object end

"""
    list_objects(store, prefix; start_after = nothing)

Return the `ObjectMeta` of every object whose key starts with `prefix`, compared by
bytes.

The order is not promised. An empty listing is an empty vector. A failure throws.

- `start_after`: only keys that sort after it, in byte order.

Examples: test/test_object_store_examples.jl
"""
function list_objects end

# A store that returns another store's namespace would write over that store's cached
# files on every read, so there is no shared default (ADR-0040).
"""
    cache_namespace(store)

Return the directory of the record cache that holds what is read through `store`.

Two stores that may hold different objects under one bucket name and key return
different namespaces. A namespace is at most 12 characters of `a-z`, `0-9`, `.`, `_`
and `-`, and is not `attachments`. A store of your own must define a method: a `Chain`
over a store without one is refused with `ArgumentError`.

Examples: test/test_object_store_examples.jl
"""
function cache_namespace(store::AbstractObjectStore)
    T = nameof(typeof(store))
    throw(
        ArgumentError(
            "$T does not define ChainTables.cache_namespace, the record cache's " *
                "directory for objects read through it. Define " *
                "ChainTables.cache_namespace(::$T) to return a portable name of at " *
                "most $MAX_NAMESPACE_LENGTH characters that no other store holding " *
                "different objects under the same bucket and key returns"
        )
    )
end

"""
    record_author(store)

Return the name that a record committed through `store` carries as its author, or
`nothing` when there is none.

For a plain bucket it is `USER`, else `USERNAME`, from the environment. A gateway
store returns the caller's name from AWS and ignores the environment.

Examples: test/test_object_store_examples.jl
"""
function record_author(::AbstractObjectStore)
    user = get(ENV, "USER", get(ENV, "USERNAME", ""))
    return isempty(user) ? nothing : user
end

# The largest record that `commit!` and `create_chain` put through `store`, in bytes
# (ADR-0006). A gateway store has a lower cap (ADR-0028).
record_cap(::AbstractObjectStore) = Ops.MAX_RECORD_BYTES

# `list_objects` compares by bytes (ADR-0010): half of a multi-byte code point is a
# legal prefix, which `startswith` refuses.
function startswith_bytes(key::AbstractString, prefix::AbstractString)
    key_bytes, prefix_bytes = codeunits(key), codeunits(prefix)
    length(prefix_bytes) <= length(key_bytes) || return false
    return view(key_bytes, eachindex(prefix_bytes)) == prefix_bytes
end

# TODO: the form of this type waits for a ruling (it holds `msg`, and it is outside
# `ChainTablesError`): https://github.com/jonalm/julia_codestyle/issues/150
"""
    TransportError(msg; status = nothing) <: Exception

Thrown by a verb of an object store when a request failed: `status` is the HTTP status
when there was a response, `nothing` for a connect failure or a timeout.

It is the transport's word, and the commit layer decides what it means. A test's
`InMemoryObjectStore` `fault` throws one to simulate a failed request.
"""
struct TransportError <: Exception
    msg::String
    status::Union{Nothing, Int}
end
TransportError(msg; status = nothing) = TransportError(msg, status)
function Base.showerror(io::IO, e::TransportError)
    print(io, "TransportError: ", e.msg)
    e.status === nothing || print(io, " (HTTP ", e.status, ")")
    return nothing
end

# A connect failure or a timeout, a `5xx`, a `409` and a `429` are retried (ADR-0010,
# ADR-0028). Every other status is not, an authorisation `4xx` above all. A `412`
# never gets here: the store returns it as a `PutOutcome`.
function is_retryable(e::TransportError)
    status = e.status
    status === nothing && return true
    return 500 <= status < 600 || status == 409 || status == 429
end

# Only the transport's own word is retried.
is_retryable(e) = false
