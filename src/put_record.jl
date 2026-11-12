const PHANTOM_412 =
    "the put was refused as existing (412) and a fetch found nothing there, " *
    "$PUT_ATTEMPTS times: objects appear and vanish from outside the protocol"

"""
    put_record!(chain, key, bytes)

Put `bytes` at `key` if absent, re-issuing a retryable failure up to `PUT_ATTEMPTS` times.
Return `nothing` when `bytes` are at `key`, created now or found by the read-back after a
lost acknowledgement, and the other record's bytes when another record holds the slot.

The read-back asks the store, past the record cache, after every put that did not report
`created`, and caches what it finds; the status never decides the outcome.
"""
function put_record!(chain::Chain, key::AbstractString, bytes)
    ours = Ops.transaction_hash(bytes)
    for attempt in 1:PUT_ATTEMPTS
        attempt == 1 || sleep(PUT_BACKOFF_S[attempt - 1])
        put_lands!(chain, key, bytes, attempt == PUT_ATTEMPTS) && return nothing
        found = fetch_object(chain.store, key)
        found === nothing && continue
        heal_record!(chain, key, found)
        return Ops.transaction_hash(found) == ours ? nothing : found
    end
    throw(RewrittenChainError(; detail = PHANTOM_412))
end

"""
    put_lands!(chain, key, bytes, is_last)

Issue one conditional put of `bytes` at `key` and return `true` when it created the key
(the record is then cached), `false` for a `412` or a retryable failure. A retryable
failure of the last attempt throws once a read-back finds the slot empty.
"""
function put_lands!(chain::Chain, key, bytes, is_last)
    outcome = try
        put_object_if_absent(chain.store, key, bytes)
    catch e
        e isa TransportError || rethrow()
        retryable(e) || rethrow()
        is_last && fetch_object(chain.store, key) === nothing && rethrow()
        return false
    end
    if outcome.created
        cache_record!(chain, key, bytes)
        return true
    end
    outcome.status == 412 || throw(ArgumentError(broken_put_promise(chain.store, outcome)))
    return false
end

function broken_put_promise(store, outcome)
    return "put_object_if_absent($(nameof(typeof(store)))) returned created = false " *
        "with status $(outcome.status); the store may refuse only with a 412"
end

"""
    put_record_for!(chain, chain_id, slot, bytes)

`put_record!` of `bytes` at `slot`, with a gateway's refusal or mismatch thrown again
naming the chain id and the slot.
"""
function put_record_for!(chain::Chain, chain_id, slot, bytes)
    try
        return put_record!(chain, slot_key(chain, slot), bytes)
    catch e
        e isa Union{WriteRefusedError, GatewayMismatchError} || rethrow()
        rethrow_for_slot(e, chain, chain_id, slot)
    end
end

"""
    write_author(chain, chain_id, slot)

Return the author a record for `slot` names: `record_author(chain.store)`, or `nothing`
when the chain does not record one. A gateway's refusal of the caller is thrown again
naming the chain id and the slot.
"""
function write_author(chain::Chain, chain_id, slot)
    chain.record_user || return nothing
    try
        return record_author(chain.store)
    catch e
        e isa WriteRefusedError || rethrow()
        rethrow_for_slot(e, chain, chain_id, slot)
    end
end

function rethrow_for_slot(e::WriteRefusedError, chain::Chain, chain_id, slot)
    key = something(e.key, slot_key(chain, slot))
    throw(WriteRefusedError(; chain_id, slot, key, e.caller, e.reason, e.detail))
end

function rethrow_for_slot(e::GatewayMismatchError, chain::Chain, chain_id, slot)
    key = something(e.key, slot_key(chain, slot))
    throw(GatewayMismatchError(; chain_id, slot, key, e.bucket, e.gateway, e.detail))
end

"""
    check_record_cap(store, bytes, call)

Throw `WriteBuilderError` naming `call` when `bytes` are over `record_cap(store)`.
"""
function check_record_cap(store::AbstractObjectStore, bytes, call)
    cap = record_cap(store)
    n = length(bytes)
    T = nameof(typeof(store))
    n <= cap || throw(WriteBuilderError(; call, detail = over_cap(n, cap, T)))
    return nothing
end

over_cap(n, cap, T) = "the record is $n bytes, over the $cap-byte cap of a $T"
