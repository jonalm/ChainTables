"""
    AbstractObjectStore

The object store a chain reaches its bucket through: four operations, `fetch_object`,
`put_object_if_absent`, `stat_object` and `list_objects`, and no delete. Subtype it to
reach another store; the subtype implements the four and `cache_namespace`. There is no
fallback method: a store that leaves an operation out fails with a `MethodError`.

Examples: test/test_store_examples.jl
"""
abstract type AbstractObjectStore end

"""
    PutOutcome(created, status)

What a conditional put reported: `created` is `true` when the key was absent and now
holds the bytes, and `false` only for a `412 Precondition Failed`. `status` is the HTTP
status, kept for messages; the read-back of the slot decides a commit's outcome.

Examples: test/test_store_examples.jl
"""
struct PutOutcome
    created::Bool
    status::Int
end

"""
    ObjectMeta(key, size, modified)

What `stat_object` and `list_objects` report about one object: its `key`, its `size` in
bytes, and `modified` in whole seconds since the Unix epoch. Two objects written in one
second tie; nothing in the protocol orders by it.

Examples: test/test_store_examples.jl
"""
struct ObjectMeta
    key::String
    size::Int64
    modified::Int64
end

"""
    fetch_object(store, key)

Return the bytes of the object at `key`, or `nothing` when no such key exists.

A transport or authorisation failure throws; it is never `nothing`. One request, no
retry.

Examples: test/test_store_examples.jl
"""
function fetch_object end

"""
    put_object_if_absent(store, key, bytes)

Create `key` holding `bytes` only if no such key exists, and return a `PutOutcome`.

`created` is `false` only for a `412`; a `409` and every transport failure throw. The
store never overwrites an existing key: a store that does splits the chain.

Examples: test/test_store_examples.jl
"""
function put_object_if_absent end

"""
    stat_object(store, key)

Return the `ObjectMeta` of `key`, or `nothing` when no such key exists. One `HEAD`
request; a failure throws.

Examples: test/test_store_examples.jl
"""
function stat_object end

"""
    list_objects(store, prefix; start_after = nothing)

Return the `ObjectMeta` of every object whose key starts with `prefix`, compared by
bytes, and sorts strictly after `start_after` in byte order when it is given.

The order of the result is not promised. A failure throws; no match is an empty vector.

Examples: test/test_store_examples.jl
"""
function list_objects end

"""
    startswith_bytes(key, prefix)

Return whether `key` starts with `prefix` compared byte by byte, so half of a multi-byte
code point is a valid prefix.
"""
function startswith_bytes(key::AbstractString, prefix::AbstractString)
    k, p = codeunits(key), codeunits(prefix)
    return length(p) <= length(k) && view(k, 1:length(p)) == p
end

"""
    record_cap(store)

Return the largest transaction record, in bytes, that a commit puts through `store`:
`Ops.MAX_RECORD_BYTES` unless the store's own method says less.
"""
record_cap(::AbstractObjectStore) = Ops.MAX_RECORD_BYTES

"""
    record_author(store)

Return the author a record committed through `store` names: `USER`, else `USERNAME`,
from the environment, or `nothing` when neither is set. A store whose own method knows
the caller (a gateway bucket) returns that name instead.

Examples: test/test_store_examples.jl
"""
function record_author(::AbstractObjectStore)
    user = get(ENV, "USER", get(ENV, "USERNAME", ""))
    return isempty(user) ? nothing : user
end

# The longest `cache_namespace`: `mem-` and 8 hex digits.
const MAX_NAMESPACE_LENGTH = 12

const NAMESPACE_CONTRACT =
    "to return a portable name of at most $MAX_NAMESPACE_LENGTH characters " *
    "that no other store holding different objects under the same bucket and key returns"

"""
    cache_namespace(store)

Return the record cache's directory, above the bucket, for objects read through `store`.

Two stores that may hold different objects under one bucket and key must return
different names, so every subtype defines its own method; this one throws.

Examples: test/test_store_examples.jl
"""
function cache_namespace(store::AbstractObjectStore)
    name = nameof(typeof(store))
    msg = "$name does not define ChainTables.cache_namespace; define it $NAMESPACE_CONTRACT"
    throw(ArgumentError(msg))
end

"""
    retryable(e)

Return whether a failed request may be issued again: a `TransportError` with no answer
(`status === nothing`), a `5xx`, a `409` or a `429`. No other status, and no other
exception, is retried.
"""
function retryable(e::TransportError)
    return e.status === nothing || 500 <= e.status < 600 || e.status in (409, 429)
end
retryable(e) = false

# A commit that cannot land in four attempts is a transport the user should hear
# about, not one to wait on.
const PUT_ATTEMPTS = 4
const PUT_BACKOFF_S = (0.05, 0.1, 0.2)
