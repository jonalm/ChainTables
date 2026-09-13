# #34 step 8 — ADR-0014, ADR-0007, ADR-0015, ADR-0020, ADR-0023: recovery is always
# explicit. `verify` checks and raises; `repair!` is the one thing that rewrites, and only
# what does not hash to its name; `as_of` builds a pinned copy at a slot; `slot_at` turns
# a time into a slot by scan. Nothing here heals anything by itself.

using .Model: Content

# ---------------------------------------------------------------------------
# The record cache as the chain (ADR-0014): what verify(full) walks and repair! replays.
# ---------------------------------------------------------------------------

# The transaction hash each slot 0..head.slot must have, walked backwards from the head:
# the head names its own slot, every record names its parent. The cache's copy of a slot
# is rehashed against that before anything of it is trusted; a copy that lacks a slot
# stops unless `fetch` fills it from the store. Returns the hashes by slot (index s + 1).
function cached_chain_hashes(copy::LocalCopy, chain::Chain, call; fetch = false)
    h = copy.head
    hashes = Vector{Vector{UInt8}}(undef, h.slot + 1)
    expected = h.transaction_hash
    named_by = "the head of the local copy at $(copy.path) names it as"
    for s in h.slot:-1:0
        key = slot_key(chain, s)
        path = record_path(chain.cache, chain.bucket, key)
        bytes = fetch ? fetch_record(chain.cache, chain.store, chain.bucket, key) : cached_record(chain, s)
        bytes === nothing && throw(ArgumentError("$call: slot $s of chain $(h.chain_id) is not in the record cache ($path), " *
            "and the check is local. repair!(copy) fetches what the cache lacks and rewrites what differs; a fresh local " *
            "copy sync!ed from the chain fetches every record."))
        th = Ops.transaction_hash(bytes)
        th == expected || error("$call: the record cache's copy of slot $s ($path) hashes to $(bytes2hex(th)); " *
            "$named_by $(bytes2hex(expected)). The record cache is damaged: delete that file, and repair!(copy) " *
            "fetches it again.")
        hashes[s+1] = th
        record = Ops.decode_record(bytes; slot = s)
        chain_id_string(record.chain_id) == h.chain_id || throw(MalformedRecordError("malformed record at slot $s: it " *
            "carries chain id $(chain_id_string(record.chain_id)), the chain is $(h.chain_id) (a record of another chain " *
            "was written into this prefix). No client can apply it (ADR-0025)."; chain_id = h.chain_id, slot = s))
        s == 0 || (expected = record.prev_hash; named_by = "slot $s names its parent as")
    end
    return hashes
end

# The record at `slot`, from the cache, rehashed against what the chain walk established.
function cached_record_at(chain::Chain, slot, hashes, call)
    bytes = cached_record(chain, slot)
    (bytes !== nothing && Ops.transaction_hash(bytes) == hashes[slot+1]) ||
        error("$call: the record cache's copy of slot $slot changed while it was being read")
    return Ops.decode_record(bytes; slot)
end

# ---------------------------------------------------------------------------
# verify (ADR-0014, ADR-0007, ADR-0020)
# ---------------------------------------------------------------------------

"""
    verify(copy; full = false) -> nothing

Check the local copy and raise `FingerprintMismatchError` on any failure (ADR-0020:
a `Bool` would be ignorable); `nothing` on success. Local only, no network, and the
head never moves (ADR-0014).

Without `full`: hash every table file the head names and hold each against its name,
then recompute the state fingerprint from those hashes and hold it against the head's
(ADR-0007, recomputed in full) — the pass `open` deliberately skips (ADR-0023). A file
that does not hash to its name, or is missing, is a **damaged copy**, and the error
names every such file and `repair!(copy)`.

With `full = true`, ADR-0007's localizing form, after the files: walk the record cache
from the head down to slot 0, rehashing every record and checking each `prev_hash`
(record-hash verification folds in here), then replay in memory and **bisect to the
first slot whose fingerprint this client does not reproduce** — the head is replayed
first, and if it reproduces the copy is verified; otherwise `log` replays from slot 0
find the first mismatching slot, which the error names in message and fields with
the record's `client.lib`/`client.julia` against this machine's. The bisection assumes
what determinism gives: once a slot fails to reproduce, so does every later one. A
record the cache lacks stops the check (it is local); a cached record whose bytes do
not hash to what the chain names is a damaged record cache, and the error says which
file to delete.
"""
function verify(copy::LocalCopy; full = false)
    check_open(copy)
    h = copy.head
    h === nothing && throw(ArgumentError("verify(copy): the local copy at $(copy.path) has no head yet, so there is " *
        "nothing to verify; sync!(copy) binds it"))
    verify_files(copy)
    full || return nothing
    chain = chain_of(copy, "verify")
    call = "verify(copy; full = true)"
    hashes = cached_chain_hashes(copy, chain, call)
    records = [cached_record_at(chain, s, hashes, call) for s in 0:h.slot]
    replay_to(content, from, to) = (for s in from:to; Ops.apply!(content, records[s+1]); end; content)
    reproduces(content, s) = Model.state_fingerprint(content) == records[s+1].state_fingerprint
    top = replay_to(Content(), 0, h.slot)
    reproduces(top, h.slot) && return nothing
    # bisect: `lo` reproduces (or is -1), `hi` does not; `base` is the content at `lo`
    lo, hi, base = -1, h.slot, Content()
    while hi - lo > 1
        mid = (lo + hi) ÷ 2
        content = replay_to(deepcopy(base), lo + 1, mid)
        if reproduces(content, mid)
            lo, base = mid, content
        else
            hi = mid
        end
    end
    content = replay_to(deepcopy(base), lo + 1, hi)
    computed = Model.state_fingerprint(content)
    record = records[hi+1]
    here = written_by_here()
    below = hi == 0 ? "it is the first record" : "slots 0 to $(hi - 1) reproduce"
    throw(FingerprintMismatchError("state fingerprint mismatch at slot $hi (chain $(h.chain_id)): replaying the record " *
        "cache from slot 0, the record's state_fingerprint is $(bytes2hex(record.state_fingerprint)), this client computes " *
        "$(bytes2hex(computed)) after applying it; $below. The record was written by $(record.client.lib) on Julia " *
        "$(record.client.julia); this client is $(here.lib) on Julia $(here.julia). The local copy at $(copy.path) is at " *
        "slot $(h.slot) and stays readable. This machine cannot reproduce the chain from slot $hi, or the committer of " *
        "slot $hi wrote a wrong fingerprint: repair!(copy) confirms whether the head reproduces.";
        chain_id = h.chain_id, slot = Int64(hi), expected = record.state_fingerprint, computed,
        record_client = (; lib = record.client.lib, julia = record.client.julia), this_client = here))
end

# Every table file the head names hashed against its name, and the fingerprint over
# what they hash to against the head's (ADR-0007, ADR-0023).
function verify_files(copy::LocalCopy)
    h = copy.head
    hashed = Dict{Vector{UInt8},Union{Nothing,Vector{UInt8}}}()   # named hash => what the file hashes to
    problems = String[]
    for (hash, names) in files_of(h)
        file = table_path(copy, hash)
        got = isfile(file) ? hash_file(file) : nothing
        hashed[hash] = got
        got == hash && continue
        which = length(names) == 1 ? "table $(repr(names[1]))" : "tables " * join(repr.(names), ", ")
        push!(problems, "table file tables/$(bytes2hex(hash)) ($which) " *
                        (got === nothing ? "is missing" : "hashes to $(bytes2hex(got)), not its name"))
    end
    isempty(problems) && Model.state_fingerprint(h.tables) == h.state_fingerprint && return nothing
    computed = any(isnothing, values(hashed)) ? nothing :
        Model.state_fingerprint(name => hashed[hash] for (name, hash) in h.tables)
    files = computed === nothing ? "" : "its table files hash to $(bytes2hex(computed)): "
    throw(FingerprintMismatchError("state fingerprint mismatch at slot $(h.slot) (chain $(h.chain_id)): the head of the " *
        "local copy at $(copy.path) holds state_fingerprint $(bytes2hex(h.state_fingerprint)), $files" *
        join(problems, "; ") * ". The local copy is damaged (its files, not the chain): repair!(copy) rewrites every file " *
        "whose bytes do not hash to its name from the record cache.";
        chain_id = h.chain_id, slot = h.slot, expected = h.state_fingerprint, computed))
end

# The head's files with the tables that name each, in name order: two identical tables
# share one file (ADR-0023).
function files_of(h::Head)
    files = Pair{Vector{UInt8},Vector{String}}[]
    for (name, hash) in h.tables
        i = findfirst(p -> first(p) == hash, files)
        i === nothing ? push!(files, hash => [name]) : push!(files[i].second, name)
    end
    return files
end

# ---------------------------------------------------------------------------
# repair! (ADR-0014, ADR-0023, ADR-0020)
# ---------------------------------------------------------------------------

"""
    repair!(copy) -> (; slot, files_rewritten)

Repair a damaged copy in place (ADR-0014, ADR-0023): replay the chain from the record
cache to the head's slot in memory — a record the cache lacks is fetched through it —
encode and hash every table, and hold the list against the head's. All match: rewrite
only the files whose on-disk bytes do not hash to their name, or are missing, each
written to a `.tmp` and renamed into place; the head and the pin are untouched, there
is no temporary directory and no swap, and `files_rewritten` counts files (two tables
with identical content share one). Mismatch: `DivergenceError` naming the slot, both
fingerprints and the tables that differ, and **nothing is written** — this machine
cannot reproduce the chain, the copy stays readable, and the commit pre-check keeps it
from committing onto the chain. The one function on the surface that returns a report
rather than raising: it succeeded at something the user asked for (ADR-0020).

A copy with no readable head never opens, so it cannot reach here: the error at `open`
says to delete the directory and sync again. A fresh, unbound copy has nothing to repair.
"""
function repair!(copy::LocalCopy)
    check_open(copy)
    h = copy.head
    h === nothing && throw(ArgumentError("repair!(copy): the local copy at $(copy.path) has no head yet, so there is " *
        "nothing to repair; sync!(copy) binds it"))
    chain = chain_of(copy, "repair!")
    call = "repair!(copy)"
    hashes = cached_chain_hashes(copy, chain, call; fetch = true)
    content = Content()
    for s in 0:h.slot
        Ops.apply!(content, cached_record_at(chain, s, hashes, call))
    end
    replayed = sort!([name => Model.table_hash(t) for (name, t) in content]; by = first)
    computed = Model.state_fingerprint(replayed)
    if replayed != h.tables
        ours, theirs = Dict(replayed), Dict(h.tables)
        differ = String[]
        for name in sort!(unique!([first.(replayed); first.(h.tables)]))
            a, b = get(ours, name, nothing), get(theirs, name, nothing)
            a == b && continue
            push!(differ, "$name (replay $(a === nothing ? "absent" : bytes2hex(a)), head $(b === nothing ? "absent" : bytes2hex(b)))")
        end
        throw(DivergenceError("divergence at slot $(h.slot) (chain $(h.chain_id)): a fresh replay of the record cache from " *
            "slot 0 to slot $(h.slot) yields state fingerprint $(bytes2hex(computed)), the head of the local copy at " *
            "$(copy.path) carries $(bytes2hex(h.state_fingerprint)); tables that differ: $(join(differ, ", ")). This machine " *
            "cannot reproduce the chain — whether this client or the chain's committers are right is not decided here. " *
            "Nothing was written; the local copy stays readable and never commits onto this chain.";
            chain_id = h.chain_id, slot = h.slot, expected = h.state_fingerprint, computed))
    end
    rewritten = 0
    for (hash, names) in files_of(h)
        file = table_path(copy, hash)
        isfile(file) && hash_file(file) == hash && continue
        rewrite_table_file!(copy, content[names[1]], hash)
        rewritten += 1
    end
    return (; slot = h.slot, files_rewritten = rewritten)
end

# The one write that replaces a file: to a .tmp, checked to hash to the name it is
# about to take, then renamed over the damaged or missing file.
function rewrite_table_file!(copy::LocalCopy, t::Model.Table, hash)
    dir = tables_dir(copy)
    tmp = joinpath(dir, bytes2hex(rand(UInt8, 8)) * ".tmp")
    got = Base.open(io -> Model.write_table(io, t), tmp, "w")
    got == hash || (rm(tmp; force = true); error("repair!(copy): the replayed table encodes to $(bytes2hex(got)), the head " *
        "names $(bytes2hex(hash)); the replay was held against the head a moment ago, so the model changed under repair!"))
    mv(tmp, joinpath(dir, bytes2hex(hash)); force = true)
    return nothing
end

# ---------------------------------------------------------------------------
# as_of and slot_at (ADR-0015, ADR-0023)
# ---------------------------------------------------------------------------

"""
    as_of(chain, target; path = nothing) -> LocalCopy

A **pinned** local copy of the chain as of `target`: a slot, or the
[`TransactionHash`](@ref) of the record to stop at — never a time; [`slot_at`](@ref)
turns a time into a slot (ADR-0015). Built by replay from slot 0, checkpointed at the
target, whose record's state fingerprint is verified there (ADR-0007). The copy is
pinned: `sync!`, `write_builder` and `commit!` refuse it, and [`unpin!`](@ref) makes
it live. `as_of` never touches the live local copy.

`path = nothing`, the common case, builds a temporary copy whose directory `close`
deletes. A given `path` is kept: when it already holds a copy bound to this chain,
pinned at `target`, it is **opened rather than rebuilt** — ADR-0023's open checks are
what make that safe — and the head's own record is fetched and held against the head;
pinned below `target`, it is replayed forward (what an interrupted `as_of` leaves);
pinned above, or live, it is refused, since a copy never moves backwards and `as_of`
never touches a live copy. A `path` bound to another chain is `WrongChainError`.

A `target` the chain has no slot for is refused; a prefix with no slot 0 is
`ChainNotFoundError`. Addressing by hash scans the chain's records from slot 0 through
the record cache.
"""
function as_of(chain::Chain, target; path = nothing)
    slot = target_slot(chain, target)
    call = "as_of(chain, $slot)"
    temporary = path === nothing
    dir = temporary ? mktempdir(; prefix = "chaintables-as_of-", cleanup = false) : String(path)
    copy = try
        open(chain, dir)
    catch
        temporary && rm(dir; recursive = true, force = true)
        rethrow()
    end
    copy.temporary = temporary
    try
        h = copy.head
        if h !== nothing
            ispinned(copy) || throw(ArgumentError("$call: the local copy at $(copy.path) is live (slot $(h.slot), not " *
                "pinned); as_of never touches a live local copy. Give another path, or none for a temporary one."))
            h.slot > slot && throw(ArgumentError("$call: the local copy at $(copy.path) is pinned at slot $(h.slot), above " *
                "$slot; a local copy never moves backwards. Give another path, or delete this one."))
        end
        pin!(copy)
        if h === nothing || h.slot < slot
            check_slot_exists(chain, slot, call)
            h === nothing || check_head_slot(copy, chain)
            replay!(copy, h === nothing ? 0 : h.slot + 1, slot)      # the checkpoint at `slot` verifies its record
        else
            check_head_record(copy, chain, "The pinned copy does not match the record it claims to be the result of: " *
                "delete the directory, or repair!(copy) confirms whether this machine reproduces the chain.")
        end
    catch
        close(copy)
        rethrow()
    end
    return copy
end

function target_slot(chain::Chain, target::Integer)
    target >= 0 || throw(ArgumentError("as_of(chain, $target): slot $target is negative"))
    return Int64(target)
end
function target_slot(chain::Chain, target::TransactionHash)
    keyof(s) = slot_key(chain, s)
    top = gallop(chain.store, keyof, -1)
    top == -1 && throw(chain_not_found(chain, "as_of"))
    for s in 0:top
        bytes = fetch_record(chain.cache, chain.store, chain.bucket, keyof(s))
        bytes === nothing && throw(vanished(chain, s))
        Ops.transaction_hash(bytes) == target.bytes && return s
    end
    throw(ArgumentError("as_of(chain, $(repr(target))): no record of the chain at $(location(chain)) hashes to it " *
        "(slots 0 to $top scanned)"))
end
target_slot(chain::Chain, ::StateFingerprint) = throw(ArgumentError("as_of(chain, target): a StateFingerprint is not an " *
    "address; give a slot (an Integer) or a TransactionHash"))
target_slot(chain::Chain, target) = throw(ArgumentError("as_of(chain, target): target is a $(typeof(target)); give a slot " *
    "(an Integer) or a TransactionHash"))

function check_slot_exists(chain::Chain, slot, call)
    stat_object(chain.store, slot_key(chain, slot)) === nothing || return nothing
    (slot == 0 || stat_object(chain.store, slot_key(chain, 0)) === nothing) && throw(chain_not_found(chain, call))
    throw(ArgumentError("$call: the chain at $(location(chain)) has no slot $slot; its head is below it. " *
        "slot_at(chain, time_ms) finds a slot by time, and head(copy) after sync!(copy) is the chain's head"))
end

chain_not_found(chain::Chain, call) = ChainNotFoundError("chain not found: no slot 0 at $(location(chain)), so $call has " *
    "no chain to read. Either the bucket or prefix is not the chain's, or no chain was created there — create_chain(chain) " *
    "writes slot 0, and only that. The two cannot be told apart from here."; bucket = chain.bucket, prefix = chain.prefix)

vanished(chain::Chain, s) = RewrittenChainError("rewritten chain: slot $s at $(location(chain)) was there when head " *
    "discovery probed it and is absent now. The bucket is being written from outside the protocol and nothing heals it.";
    slot = Int64(s), found = nothing)

"""
    slot_at(chain, time_ms) -> Int64

The highest slot whose record's `client.time_ms` is at or below `time_ms` (milliseconds
since the Unix epoch, UTC), found by scanning every record of the chain from slot 0
through the record cache (ADR-0015). A scan, because `client.time_ms` is what the
committer asserted and is not monotone across clients with skewed clocks — which is
also why this is a separate, differently named lookup that returns a slot for
[`as_of`](@ref) rather than an address of its own. A time before the genesis record's
is an error: there is no state before slot 0.
"""
function slot_at(chain::Chain, time_ms)
    time_ms isa Integer || throw(ArgumentError("slot_at(chain, time_ms): time_ms is a $(typeof(time_ms)), not an Integer " *
        "of milliseconds since the Unix epoch"))
    keyof(s) = slot_key(chain, s)
    top = gallop(chain.store, keyof, -1)
    top == -1 && throw(chain_not_found(chain, "slot_at"))
    best = nothing
    genesis_ms = nothing
    for s in 0:top
        bytes = fetch_record(chain.cache, chain.store, chain.bucket, keyof(s))
        bytes === nothing && throw(vanished(chain, s))
        record = Ops.decode_record(bytes; slot = s)
        s == 0 && (genesis_ms = record.client.time_ms)
        record.client.time_ms <= time_ms && (best = s)
    end
    best === nothing && throw(ArgumentError("slot_at(chain, $time_ms): the time is before the genesis record's " *
        "client.time_ms, $genesis_ms; there is no state before slot 0 (ADR-0015)"))
    return Int64(best)
end
