function record_path(chain::Chain, key)
    return record_path(chain.cache, chain.store, chain.bucket, key)
end

# The cached record of `slot`, read without asking the store, or `nothing`.
function read_cached_record(chain::Chain, slot::Integer)
    path = record_path(chain, slot_key(chain, slot))
    return isfile(path) ? read(path) : nothing
end

# Returns the bytes of the object at `key` and whether they came from the record cache.
# A fetched object is cached. An absent one is `nothing` and caches nothing, so a slot
# that is still empty is seen the moment its record lands (ADR-0012). The cache does
# not hash what it holds: the caller holds the bytes against the chain (ADR-0040).
function fetch_record(chain::Chain, key)
    path = record_path(chain, key)
    isfile(path) && return read(path), true
    bytes = fetch_object(chain.store, key)
    bytes === nothing || write_cache_file(path, bytes)
    return bytes, false
end

# Puts `bytes`, which the store holds at `key`, in the record cache. A cached file with
# other bytes is replaced: damaged, or left by a bucket that was emptied and used again
# (ADR-0040). A reader calls this only once the store's bytes pass its check, so a
# check that the store fails too leaves the cached file as it was.
function write_cached_record(chain::Chain, key, bytes)
    path = record_path(chain, key)
    held = isfile(path) ? read(path) : nothing
    held == bytes && return nothing
    held === nothing || @debug "the record cache held other bytes than the store" path
    write_cache_file(path, bytes)
    return nothing
end

# The Try variant of `Ops.decode_record`. A `try` around a public error type: the
# decoder finds a fault at many depths, and here they all become `nothing`.
function try_decode_record(bytes, slot)
    try
        return Ops.decode_record(bytes; slot)
    catch e
        e isa MalformedRecordError || rethrow()
        return nothing
    end
end

# `open` holds the head of a bound copy against the chain's id (ADR-0023). At `open` a
# chain knows its id only from slot 0 in the record cache. With a cold or damaged cache
# the check is left to the first `sync!`.
function expected_chain_id(chain::Chain)
    bytes = read_cached_record(chain, 0)
    bytes === nothing && return nothing
    return stored_chain_id(bytes, 0)
end

function stored_chain_id(bytes, slot)
    record = try_decode_record(bytes, slot)
    record === nothing && return nothing
    return chain_id_string(record.chain_id)
end

# Head discovery (ADR-0012): the highest slot that exists, by stat probes at
# `known + 1`, `known + 2`, `known + 4`, … until a miss, then by bisection of the last
# gap. `known` is a slot that exists, or -1. A miss is the end of the chain, because a
# chain has no gaps (ADR-0002). Nothing is listed and no miss is cached.
function fetch_top_slot(chain::Chain, known::Integer)
    hit, miss = probe_doubling(chain, Int64(known))
    return bisect_top_slot(chain, hit, miss)
end

function probe_doubling(chain::Chain, known::Int64)
    hit = known
    step = Int64(1)
    while has_slot(chain, known + step)
        hit = known + step
        step *= 2
    end
    return hit, known + step
end

function bisect_top_slot(chain::Chain, hit::Int64, miss::Int64)
    while miss - hit > 1
        middle = (hit + miss) ÷ 2
        if has_slot(chain, middle)
            hit = middle
        else
            miss = middle
        end
    end
    return hit
end

has_slot(chain::Chain, slot) = stat_object(chain.store, slot_key(chain, slot)) !== nothing
