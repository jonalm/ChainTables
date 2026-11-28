const NAMED_BY_HEAD = "the store does not hold the record that the local copy's " *
    "head names"

# The record cache read as the chain, from the head of the local copy down (ADR-0014):
# the head names the transaction hash of its own slot, and each record names its
# parent's. A record is decoded only once its bytes hash to that name.
"""
    read_back_from_head(f, local_copy, chain; fetch)

Call `f(slot, record, transaction_hash)` for the records of the local copy's chain from
its head down to slot 0, and stop early when `f` returns `true`.

Each record is read from the record cache and held against the transaction hash that
the slot above, or the head, names. Without `fetch`, a record the cache lacks or holds
other bytes for throws `RecordCacheError`. With `fetch`, it is read from the store,
which must hold those bytes, else `RewrittenChainError`.
"""
function read_back_from_head(f, local_copy::LocalCopy, chain::Chain; fetch)
    head_file = local_copy.head
    expected = head_file.transaction_hash
    for slot in head_file.slot:-1:0
        bytes = read_named_record(local_copy, chain, slot, expected; fetch)
        record = Ops.decode_record(bytes; slot)
        check_of_chain(record, head_file.chain_id, slot)
        f(slot, record, expected) && return nothing
        expected = record.prev_hash
    end
    return nothing
end

function read_named_record(local_copy::LocalCopy, chain::Chain, slot, expected; fetch)
    chain_id = local_copy.head.chain_id
    if fetch
        detail = rewritten_detail(local_copy, slot)
        return fetch_named_record(chain, slot, expected; local_copy.path, chain_id, detail)
    end
    bytes = read_cached_record(chain, slot)
    hashes_to(bytes, expected) && return bytes
    throw(
        RecordCacheError(;
            chain_id, slot, path = record_path(chain, slot_key(chain, slot)),
            expected = TransactionHash(expected), found = found_hash(bytes),
            detail = cache_file_fault(bytes),
        )
    )
end

cache_file_fault(::Nothing) = "the file is missing"
cache_file_fault(bytes) = "the file holds other bytes"

# Which name the store's bytes fail: the head names its own slot, every record its
# parent's.
function rewritten_detail(local_copy::LocalCopy, slot)
    return slot == local_copy.head.slot ? NAMED_BY_HEAD : NAMED_BY_SLOT_ABOVE
end
