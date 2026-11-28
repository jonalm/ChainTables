# The pause before each new attempt of a put. Short and bounded: a commit that cannot
# land in four attempts is a transport that the user should hear about.
const PUT_BACKOFF_SECONDS = (0.05, 0.1, 0.2)
const PUT_ATTEMPTS = length(PUT_BACKOFF_SECONDS) + 1

const MALFORMED_WINNER = "the record in the slot is malformed, so its chain id is not " *
    "known"

# The conditional put of a record, with its retry loop and read-back (ADR-0010).
# Returns `nothing` when `bytes` are at `slot`: created by this call, or found there by
# the read-back after a lost acknowledgement. Returns the other record's bytes when
# another record holds the slot. The read-back decides, never the status: it asks the
# store, past the record cache, after every put that did not create the key, and what
# it finds is cached. A failure that may be retried is thrown once the attempts are
# spent; any other failure is thrown at once.
function put_record(chain::Chain, chain_id, slot, bytes)
    key = slot_key(chain, slot)
    failure = nothing
    for attempt in 1:PUT_ATTEMPTS
        attempt == 1 || sleep(PUT_BACKOFF_SECONDS[attempt - 1])
        try
            put_creates(chain, chain_id, slot, bytes) && return nothing
        catch e
            e isa TransportError || rethrow()
            is_retryable(e) || rethrow()
            failure = e
        end
        found = fetch_object(chain.store, key)
        found === nothing || return read_back(chain, key, bytes, found)
    end
    # The last failure of the transport, kept over the read-backs that found nothing.
    failure === nothing || throw(failure)
    throw(
        RewrittenChainError(;
            chain.bucket, chain.prefix, chain_id, slot,
            detail = "the put to $key was refused as existing (412) and a fetch " *
                "found nothing there, $PUT_ATTEMPTS times over",
        )
    )
end

# One conditional put: `true` when it created the key, `false` for a `412`. A gateway's
# refusal is thrown again with the chain and the slot that the write was for.
function put_creates(chain::Chain, chain_id, slot, bytes)
    key = slot_key(chain, slot)
    outcome = try
        put_object_if_absent(chain.store, key, bytes)
    catch e
        e isa Union{WriteRefusedError, GatewayMismatchError} || rethrow()
        throw(typeof(e)(e, chain_id, slot, key))
    end
    outcome.created || outcome.status == 412 || throw(
        ArgumentError(
            "put_object_if_absent($(nameof(typeof(chain.store)))) returned created = " *
                "false with status $(outcome.status); a store may answer false only " *
                "for a 412"
        )
    )
    outcome.created && write_cached_record(chain, key, bytes)
    return outcome.created
end

# The store's bytes at the slot are the authority, so they are cached unchecked.
function read_back(chain::Chain, key, bytes, found)
    write_cached_record(chain, key, found)
    return Ops.transaction_hash(found) == Ops.transaction_hash(bytes) ? nothing : found
end

# The setup that the two throw sites of a lost race share: `found` is the record that
# holds the slot.
function LostRaceError(chain::Chain, chain_id, slot, found; reason)
    transaction_hash = TransactionHash(Ops.transaction_hash(found))
    detail = chain_id === nothing ? MALFORMED_WINNER : ""
    return LostRaceError(;
        chain.bucket, chain.prefix, chain_id, slot, transaction_hash, reason, detail,
    )
end

# The author of the record for `slot`, or `nothing` when the chain names none. It is
# fetched before anything is applied or written (ADR-0028). A gateway's refusal of the
# caller is thrown again with the chain and the slot.
function write_author(chain::Chain, chain_id, slot)
    chain.record_user || return nothing
    try
        return record_author(chain.store)
    catch e
        e isa WriteRefusedError || rethrow()
        throw(WriteRefusedError(e, chain_id, slot, slot_key(chain, slot)))
    end
end

# `encode_record` holds a record to the cap of the format. A store may have a lower one.
function check_record_cap(store::AbstractObjectStore, bytes, call)
    cap = record_cap(store)
    n = length(bytes)
    n <= cap || throw(
        WriteBuilderError(;
            detail = "$call: record is $n bytes; the cap on a " *
                "$(nameof(typeof(store))) is $cap bytes ($(cap ÷ 2^20) MiB): split " *
                "the write into more than one commit",
        )
    )
    return nothing
end
