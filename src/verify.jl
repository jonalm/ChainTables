"""
    BackwardWalk(copy, chain, call, fetch)

A walk of the record cache from the copy's head down to slot 0, each record held against
the hash the one above names. A record the cache lacks or holds other bytes for is a
damaged record cache: with `fetch = false` the walk stops with `RecordCacheError` naming
`call`; with `fetch = true` the store's bytes replace it once they hash right.
"""
struct BackwardWalk{C <: LocalCopy, K <: Chain}
    copy::C
    chain::K
    call::String
    fetch::Bool
end

# Over 8 lines: the two forms check different things and throw different errors.
"""
    verify(copy; full = false)

Check the local copy and return `nothing`, or throw; no request reaches the store and the
head never moves.

Hash every table file the head names against its name and recompute the state
fingerprint: a damaged copy throws `FingerprintMismatchError`, fixed by `repair!(copy)`.
With `full = true`, also walk the record cache down from the head, replay it in memory,
and throw `FingerprintMismatchError` naming the first slot this client does not
reproduce; a damaged record cache throws `RecordCacheError`, a damaged attachment cache
`AttachmentCacheError`.

Examples: test/test_verify_examples.jl
"""
function verify(copy::LocalCopy; full = false)
    check_open(copy)
    copy.head === nothing && throw(ArgumentError(no_head(copy, "verify(copy)")))
    verify_files(copy)
    full || return nothing
    chain = chain_of(copy, "verify")
    walk = BackwardWalk(copy, chain, "verify(copy; full = true)", false)
    records = walked_records(walk)
    mismatch = first_mismatch(records)
    mismatch === nothing || throw_unreproduced(copy, records, mismatch)
    verify_attachments(copy, chain)
    return nothing
end

# Every table file the head names hashed against its name, and the fingerprint over what
# they hash to against the head's (ADR-0007, ADR-0023).
function verify_files(copy::LocalCopy)
    h = copy.head
    files = files_of(h)
    found = Dict(hash => table_file_hash(copy, hash) for (hash, _) in files)
    problems = [
        file_problem(hash, names, found[hash])
            for (hash, names) in files if found[hash] != hash
    ]
    _is_sound = isempty(problems) && state_fingerprint(h.tables) == h.state_fingerprint
    _is_sound && return nothing
    _has_missing = any(isnothing, values(found))
    computed = _has_missing ? nothing : files_fingerprint(h, found)
    detail = "the local copy at $(copy.path) is damaged: " * join(problems, "; ")
    expected = h.state_fingerprint
    throw(FingerprintMismatchError(; h.chain_id, h.slot, expected, computed, detail))
end

function table_file_hash(copy::LocalCopy, hash)
    file = table_path(copy, hash)
    return isfile(file) ? hash_file(file) : nothing
end

function files_fingerprint(h, found)
    return state_fingerprint(name => found[hash] for (name, hash) in h.tables)
end

function file_problem(hash, names, got)
    which = length(names) == 1 ? "table" : "tables"
    which *= " " * join(repr.(names), ", ")
    what = got === nothing ? "is missing" : "hashes to $(bytes2hex(got)), not its name"
    return "table file tables/$(bytes2hex(hash)) ($which) $what"
end

"""
    files_of(h)

Return the table files the head names, each with the names of the tables it holds, in
table name order: two tables with identical content share one file.
"""
function files_of(h::Head)
    hashes = unique(last.(h.tables))
    return [hash => [name for (name, x) in h.tables if x == hash] for hash in hashes]
end

"""
    walked_records(walk)

Return the records of slots `0:head.slot` from the record cache, each held against the
hash the walk down from the head established for it.
"""
function walked_records(walk::BackwardWalk)
    hashes = walked_hashes(walk)
    return map(s -> walked_record_at(walk, s, hashes[s + 1]), 0:walk.copy.head.slot)
end

function walked_hashes(walk::BackwardWalk)
    hashes = Vector{Vector{UInt8}}(undef, walk.copy.head.slot + 1)
    walk_back(walk) do s, record, th
        hashes[s + 1] = th
        return false
    end
    return hashes
end

# The cached record of `slot`, rehashed: a file that changed since the walk vouched for it
# means another process writes the record cache.
function walked_record_at(walk::BackwardWalk, slot, expected)
    path = record_path(walk.chain, slot_key(walk.chain, slot))
    bytes = cached_record(walk.chain, slot)
    found = bytes === nothing ? nothing : Ops.transaction_hash(bytes)
    detail = "the cached record changed while $(walk.call) read it"
    chain_id = walk.copy.head.chain_id
    found == expected ||
        throw(RecordCacheError(; chain_id, slot, path, expected, found, detail))
    return Ops.decode_record(bytes; slot)
end

"""
    walk_back(f, walk)

Call `f(slot, record, transaction_hash)` from the copy's head down to slot 0, each record
held against the hash the one above names, stopping when `f` returns `true`.
"""
function walk_back(f, walk::BackwardWalk)
    h = walk.copy.head
    expected, named_by = h.transaction_hash, "the head of the local copy"
    for s in h.slot:-1:0
        bytes = walked_bytes(walk, s, expected, named_by)
        record = Ops.decode_record(bytes; slot = s)
        check_record_chain(record, h.chain_id, s)
        f(s, record, Ops.transaction_hash(bytes)) === true && return nothing
        expected, named_by = record.prev_hash, "slot $s"
    end
    return nothing
end

function check_record_chain(record, chain_id, slot)
    theirs = chain_id_string(record.chain_id)
    theirs == chain_id ||
        throw(MalformedRecordError(; chain_id, slot, detail = "its chain id is $theirs"))
    return nothing
end

# The bytes of slot `s` that hash to `expected`, which `named_by` names: the cache's, or,
# when the walk fetches, the store's, which then replace the cached file.
function walked_bytes(walk::BackwardWalk, s, expected, named_by)
    bytes = cached_record(walk.chain, s)
    hashes_to(bytes, expected) && return bytes
    path = record_path(walk.chain, slot_key(walk.chain, s))
    found = bytes === nothing ? nothing : Ops.transaction_hash(bytes)
    chain_id = walk.copy.head.chain_id
    detail = cache_problem(walk.call, found, named_by)
    slot = s
    walk.fetch || throw(RecordCacheError(; chain_id, slot, path, expected, found, detail))
    return store_bytes_named(walk, s, expected, named_by)
end

function cache_problem(call, found, named_by)
    found === nothing && return "the record is not cached, and $call is local"
    return "the cached record is not the one $named_by names"
end

function store_bytes_named(walk::BackwardWalk, s, expected, named_by)
    key = slot_key(walk.chain, s)
    bytes = fetch_object(walk.chain.store, key)
    found = bytes === nothing ? nothing : Ops.transaction_hash(bytes)
    detail = "the store's record is not the one $named_by names"
    chain_id = walk.copy.head.chain_id
    found == expected ||
        throw(RewrittenChainError(; chain_id, slot = s, expected, found, detail))
    heal_record!(walk.chain, key, bytes)
    return bytes
end

"""
    first_mismatch(records)

Return `nothing` when replaying `records` from slot 0 reproduces the last one's state
fingerprint; else `(; slot, computed)` for the first slot that does not, found by bisection.
Determinism makes it sound: once a slot fails to reproduce, so does every later one.
"""
function first_mismatch(records)
    top = length(records) - 1
    reproduces(replay_records!(Content(), records, 0, top), records, top) && return nothing
    lo, hi, base = -1, top, Content()
    while hi - lo > 1
        mid = (lo + hi) ÷ 2
        content = replay_records!(deepcopy(base), records, lo + 1, mid)
        if reproduces(content, records, mid)
            lo, base = mid, content
        else
            hi = mid
        end
    end
    computed = state_fingerprint(replay_records!(deepcopy(base), records, lo + 1, hi))
    return (; slot = Int64(hi), computed)
end

function replay_records!(content, records, from, to)
    foreach(s -> Ops.apply!(content, records[s + 1]), from:to)
    return content
end

function reproduces(content, records, s)
    return state_fingerprint(content) == records[s + 1].state_fingerprint
end

function throw_unreproduced(copy::LocalCopy, records, mismatch)
    h, record = copy.head, records[mismatch.slot + 1]
    below = mismatch.slot == 0 ? "it is the first record" : "slots below it reproduce"
    evidence = (;
        h.chain_id, mismatch.slot, expected = record.state_fingerprint, mismatch.computed,
        record_client = client_version(record.client), this_client = written_by_here(),
        detail = "replaying the record cache from slot 0, $below",
    )
    throw(FingerprintMismatchError(; evidence...))
end
