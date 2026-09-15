# #34 step 7 — ADR-0019, ADR-0011, ADR-0002, ADR-0009, ADR-0010, ADR-0012, ADR-0013,
# ADR-0014, ADR-0007, ADR-0020: `Chain`, slot keys, `create_chain`, `sync!`,
# `write_builder(copy)` and `commit!`. The lanes converge here: everything runs against
# the port through `chain.store`; the S3 client behind `store = nothing` is step 9's.

using .Ops: Client

# ---------------------------------------------------------------------------
# Chain (ADR-0019): location and configuration, no I/O
# ---------------------------------------------------------------------------

"""
    Chain(bucket, prefix; store = nothing, gateway = nothing, region = nothing, credentials = nothing,
          endpoint = nothing, path_style = false, assume_first_writer_wins = false, read_ahead = 8,
          cache_dir = default_cache_dir(), record_host = true, record_user = true)

Where a chain lives and how this client talks to it (ADR-0019): `bucket` and `prefix`
are location, never identity — the chain id is in every record (ADR-0011). Constructing
one performs no I/O.

- `store`: the [`AbstractObjectStore`](@ref) the chain is reached through —
  `Testing.InMemoryObjectStore` in tests. `nothing`, the default, is the S3 client,
  [`S3ObjectStore`](@ref), built from the four keywords below.
- `gateway`: the function URL of a gateway bucket's gateway, `https://host[:port]`
  (ADR-0028). Builds a [`GatewayObjectStore`](@ref) from the bucket and the four keywords
  below: commits go through the gateway, reads go to S3 directly, the record cap is 4 MiB,
  and `client.user` is the caller's name from `sts:GetCallerIdentity`, fetched at the first
  write. An `ArgumentError` together with `store` (two stores), with `record_user = false`
  (the gateway refuses a record with no author), or with a `region` that disagrees with
  the one in a `*.lambda-url.<region>.on.aws` host.
- `region`: what SigV4 signs for; required by the S3 client — the keyword, else
  `AWS_REGION`, else `AWS_DEFAULT_REGION`, never guessed (ADR-0019) — and ignored by a
  supplied `store`.
- `credentials`: resolved now, for the S3 client only (ADR-0019, ADR-0010): `nothing` reads
  `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` and `AWS_SESSION_TOKEN` and errors if the
  keys are absent; a [`Credentials`](@ref) is taken as is; a callable returning one is
  called before every request, so a long-lived reader outlives an aws-vault session.
  [`sso_credentials(profile)`](@ref) is that callable over an `aws sso login` session.
- `endpoint`, `path_style`: the S3 client's URL. `endpoint = nothing` is AWS; an endpoint
  whose host is not `.amazonaws.com` / `.amazonaws.com.cn` warns at `open` and refuses
  at `commit!` (ADR-0016).
- `assume_first_writer_wins`: lifts the commit-time refusal on a store that is not AWS
  S3 (ADR-0016); the promise it asserts is the minimum backend contract.
- `read_ahead`: how many records `sync!` fetches ahead of apply, at least 1 — v1's one
  performance knob (ADR-0013).
- `cache_dir`: the record cache's directory (ADR-0010); [`default_cache_dir`](@ref) reads
  `CHAINTABLES_CACHE_DIR` or uses the depot.
- `record_host`, `record_user`: whether a record this client writes carries
  `client.host` / `client.user`, each individually suppressible (ADR-0006).

A bucket name containing a dot is refused: it breaks certificate matching under
virtual-hosted URLs (ADR-0010). A prefix beginning or ending in `/` is refused, because
the slot key is `<prefix>/<12 digits>` (ADR-0011); an empty prefix puts the slots at the
bucket root.
"""
struct Chain{S<:AbstractObjectStore}
    bucket::String
    prefix::String
    region::Union{Nothing,String}
    credentials::Any
    endpoint::Union{Nothing,String}
    path_style::Bool
    assume_first_writer_wins::Bool
    read_ahead::Int
    cache::RecordCache
    store::S
    record_host::Bool
    record_user::Bool
end

function Chain(bucket::AbstractString, prefix::AbstractString;
               store = nothing, gateway = nothing, region = nothing, credentials = nothing, endpoint = nothing,
               path_style = false, assume_first_writer_wins = false, read_ahead = 8, cache_dir = default_cache_dir(),
               record_host = true, record_user = true)
    isempty(bucket) && throw(ArgumentError("Chain: the bucket name is empty"))
    '.' in bucket && throw(ArgumentError("Chain: bucket name $(repr(bucket)) contains a dot, which breaks certificate " *
        "matching under the virtual-hosted URL ChainTables builds (ADR-0010); use a bucket without one"))
    (startswith(prefix, "/") || endswith(prefix, "/")) && throw(ArgumentError(
        "Chain: prefix $(repr(prefix)) begins or ends with '/'; a slot key is <prefix>/<12 digits>, so give the prefix without them"))
    read_ahead >= 1 || throw(ArgumentError("Chain: read_ahead is $read_ahead; at least 1 record is fetched ahead"))
    if gateway !== nothing                   # the gateway store (gateway.jl, ADR-0028): the S3 client plus a function URL
        store === nothing || throw(ArgumentError("Chain: gateway and store were both given; a chain has one store, and " *
            "the gateway keyword builds it from the bucket, region and credentials (ADR-0028)"))
        record_user || throw(ArgumentError("Chain: record_user = false with a gateway: the gateway refuses a record " *
            "with no author (ADR-0028), so this chain could never commit; leave record_user = true"))
        region = resolve_region(region)
        credentials = resolve_credentials(credentials)
        store = GatewayObjectStore(bucket, gateway; region, credentials, endpoint, path_style)
    elseif store === nothing                 # the S3 client (s3.jl): region and credentials resolve now, no I/O
        region = resolve_region(region)
        credentials = resolve_credentials(credentials)
        store = S3ObjectStore(bucket; region, credentials, endpoint, path_style)
    end
    store isa AbstractObjectStore || throw(ArgumentError("Chain: store is a $(typeof(store)), not an AbstractObjectStore"))
    (store isa GatewayObjectStore && !record_user) && throw(ArgumentError("Chain: record_user = false with a gateway " *
        "store: the gateway refuses a record with no author (ADR-0028), so this chain could never commit; leave record_user = true"))
    return Chain{typeof(store)}(String(bucket), String(prefix), region === nothing ? nothing : String(region), credentials,
                                endpoint === nothing ? nothing : String(endpoint), path_style, assume_first_writer_wins,
                                Int(read_ahead), RecordCache(; dir = cache_dir), store, record_host, record_user)
end

Base.show(io::IO, c::Chain) = print(io, "Chain(", repr(c.bucket), ", ", repr(c.prefix), "; store = ", nameof(typeof(c.store)), ")")

"""
    slot_key(chain, slot) -> String

The key of `slot` under the chain's prefix: `<prefix>/<12-digit zero-padded slot>`,
flat (ADR-0011, ADR-0002). The one place the slot-to-key mapping lives.
"""
slot_key(chain::Chain, slot::Integer) = isempty(chain.prefix) ? head_filename(slot) : chain.prefix * "/" * head_filename(slot)

"""
    cached_record(chain, slot) -> Vector{UInt8} | nothing

The record cache's copy of `slot`, read from disk without consulting the store, or
`nothing` when it is not cached. What `open` may consult: no network I/O.
"""
function cached_record(chain::Chain, slot::Integer)
    path = record_path(chain.cache, chain.bucket, slot_key(chain, slot))
    return isfile(path) ? read(path) : nothing
end

# `open` checks a bound copy's head against the chain when the chain knows its id
# (ADR-0023). A chain knows it from slot 0 in the record cache and from nowhere else at
# open, so a cold cache leaves the check to the first sync!, which fetches slot N.
function expected_chain_id(chain::Chain)
    bytes = cached_record(chain, 0)
    bytes === nothing && return nothing
    record = try
        Ops.decode_record(bytes; slot = 0)
    catch e
        e isa MalformedRecordError || rethrow()
        return nothing                   # a damaged cache file is sync!'s to report, not open's
    end
    return chain_id_string(record.chain_id)
end

chain_of(copy::LocalCopy, call) = copy.chain isa Chain ? copy.chain :
    throw(ArgumentError("$call: the local copy at $(copy.path) was opened over a $(typeof(copy.chain)), not a ChainTables.Chain"))

function refuse_pinned(copy::LocalCopy, call)
    ispinned(copy) || return nothing
    slot = copy.head === nothing ? "no slot" : "slot $(copy.head.slot)"
    throw(PinnedCopyError("pinned copy: the local copy at $(copy.path) is pinned at $slot, so $call refuses to move it " *
        "(ADR-0015). unpin!(copy) makes it live, or use a live copy.";
        path = copy.path, slot = copy.head === nothing ? nothing : copy.head.slot))
end

location(chain::Chain) = isempty(chain.prefix) ? chain.bucket : "$(chain.bucket)/$(chain.prefix)"

# ---------------------------------------------------------------------------
# What a write needs of the store beyond the put (ADR-0028): the author, fetched before
# anything is applied, and the cap, checked after encoding and before the put.
# ---------------------------------------------------------------------------

# The author for this write — `record_author(store)`: the environment on a plain bucket,
# the STS caller's name on a gateway bucket, `nothing` when the chain suppresses it. A
# refusal raised on the way (the principal is not a user) is enriched with the chain and slot.
function write_author(chain::Chain, chain_id, slot)
    chain.record_user || return nothing
    try
        return record_author(chain.store)
    catch e
        e isa WriteRefusedError ? throw(refused_for(e, chain, chain_id, slot)) : rethrow()
    end
end

# A record over the store's cap: `WriteBuilderError` naming the byte count, the cap and the
# store, and the next move. `encode_record` has already enforced the 64 MiB format cap.
function check_record_cap(store::AbstractObjectStore, bytes, call)
    cap = record_cap(store)
    length(bytes) <= cap || throw(WriteBuilderError("$call: record is $(length(bytes)) bytes; the cap on a " *
        "$(nameof(typeof(store))) is $cap bytes ($(cap ÷ (1024 * 1024)) MiB): split the write into more than one commit"))
    return nothing
end

# The store's refusal, told for the chain and the slot it was for (ADR-0020: the evidence
# as fields; the store knew only the key and the caller).
function refused_for(e::WriteRefusedError, chain::Chain, chain_id, slot)
    key = something(e.key, slot_key(chain, slot))
    msg = "write refused for slot $slot of chain $chain_id at $(location(chain)): " * chopprefix(e.msg, "write refused: ")
    return WriteRefusedError(msg; chain_id, slot, key, e.caller, e.reason)
end

# `put_record!`, with a gateway's refusal enriched for the chain and the slot.
function put_record_for!(chain::Chain, chain_id, slot, bytes)
    try
        return put_record!(chain.store, chain.cache, chain.bucket, slot_key(chain, slot), bytes)
    catch e
        e isa WriteRefusedError ? throw(refused_for(e, chain, chain_id, slot)) : rethrow()
    end
end

# ---------------------------------------------------------------------------
# create_chain (ADR-0019, ADR-0002): the only writer of slot 0
# ---------------------------------------------------------------------------

"""
    create_chain(chain) -> (; chain_id, slot, transaction_hash)

Create the chain at `chain`'s bucket and prefix: mint the chain id, commit a genesis
record carrying zero ops to slot 0, and return its id (base32 text), `slot = 0` and the
record's [`TransactionHash`](@ref) — **not** a local copy: every local copy is built by replay,
so `open` and `sync!` follow (ADR-0019). The only thing that may write slot 0. Two
clients creating one prefix are resolved like any commit (ADR-0002): the second raises
`LostRaceError` naming the chain already there, and is never retried. Like `commit!`, it
refuses a store that is not AWS S3 unless `assume_first_writer_wins` (ADR-0016), fetches
the author from the store next (`record_author`; STS on a gateway bucket, ADR-0028),
holds the record to the store's cap, and raises `WriteRefusedError` when a gateway
refuses the slot.
"""
function create_chain(chain::Chain)
    refuse_unsupported_store(chain, "create_chain(chain)")     # ADR-0016: before anything is written
    chain_id = rand(UInt8, 16)
    cid = chain_id_string(chain_id)
    user = write_author(chain, cid, 0)                         # ADR-0028: the author, before anything is written
    record = Record(chain_id, 0, nothing, Model.state_fingerprint(Content()),
                    Ops.local_client(; chain.record_host, user), nothing, Ops.Op[])
    bytes = Ops.encode_record(record)
    check_record_cap(chain.store, bytes, "create_chain(chain)")
    found = put_record_for!(chain, cid, 0, bytes)
    if found !== nothing
        th = Ops.transaction_hash(found)
        theirs = try
            Ops.decode_record(found; slot = 0)
        catch e
            e isa MalformedRecordError || rethrow()
            nothing
        end
        cid = theirs === nothing ? nothing : chain_id_string(theirs.chain_id)
        throw(LostRaceError("lost race for slot 0 at $(location(chain)): a chain already exists there " *
            "(chain $(something(cid, "unknown: its genesis record is malformed")), transaction hash $(bytes2hex(th))). " *
            "create_chain writes slot 0 once and is never retried: open(chain, path) and sync!(copy) to use the " *
            "existing chain, or create under another prefix."; chain_id = cid, slot = 0, transaction_hash = th))
    end
    return (; chain_id = cid, slot = 0, transaction_hash = TransactionHash(Ops.transaction_hash(bytes)))
end

# ---------------------------------------------------------------------------
# sync! (ADR-0013, ADR-0012, ADR-0014)
# ---------------------------------------------------------------------------

# The head's own slot, fetched through the record cache and held against the head
# (ADR-0014): absent, or bytes of another hash, is a rewritten chain — or, when the
# record there names another chain, the wrong chain. Returns the record's bytes.
function check_head_slot(copy::LocalCopy, chain::Chain)
    h = copy.head
    where = location(chain)
    bytes = fetch_record(chain.cache, chain.store, chain.bucket, slot_key(chain, h.slot))
    bytes === nothing && throw(RewrittenChainError("rewritten chain: slot $(h.slot) — the head of the local copy at " *
        "$(copy.path), chain $(h.chain_id) — is absent at $where. Either the chain was truncated from outside the " *
        "protocol, or this is not the chain's bucket and prefix; neither is healed. The local copy stays readable; " *
        "open it over the chain it was built from, or delete it and sync!(copy) a fresh one.";
        chain_id = h.chain_id, slot = h.slot, expected = h.transaction_hash, found = nothing))
    th = Ops.transaction_hash(bytes)
    th == h.transaction_hash && return bytes
    theirs = try
        Ops.decode_record(bytes; slot = h.slot)
    catch e
        e isa MalformedRecordError || rethrow()
        nothing
    end
    if theirs !== nothing && chain_id_string(theirs.chain_id) != h.chain_id
        opened = chain_id_string(theirs.chain_id)
        throw(WrongChainError("wrong chain: the local copy at $(copy.path) is bound to chain $(h.chain_id), the chain " *
            "at $where is $opened: open a different path for this chain.";
            path = copy.path, bound = h.chain_id, opened))
    end
    throw(RewrittenChainError("rewritten chain: slot $(h.slot) of chain $(h.chain_id) at $where holds a record hashing to " *
        "$(bytes2hex(th)); the local copy at $(copy.path) applied $(bytes2hex(h.transaction_hash)) there. The bucket was " *
        "written from outside the protocol and nothing heals it. The local copy stays readable and never commits onto " *
        "this chain.";
        chain_id = h.chain_id, slot = h.slot, expected = h.transaction_hash, found = th))
end

"""
    sync!(copy) -> (; applied, slot, transaction_hash::TransactionHash)

Bring the local copy up to the chain's head (ADR-0013): fetch the head's own slot and
hold it against the head (ADR-0014 — `RewrittenChainError`, or `WrongChainError` when
the record there names another chain), gallop for the chain head from the slot above
(ADR-0012), fetch the tail through the record cache `read_ahead` records ahead, apply
each record in slot order, and checkpoint — always at the end, and mid-replay whenever
the apply time since the last checkpoint exceeds the last checkpoint's duration (ADR-0023).
Every checkpoint's fingerprint is verified against its record. Nothing new is
`applied = 0`, never an error, once the copy has a head; a copy with no head against a
prefix with no slot 0 raises `ChainNotFoundError`, which names both a wrong location and
a chain never created (ADR-0019). A pinned copy raises `PinnedCopyError` (ADR-0015).

A record that fails to decode or apply is a malformed record (`MalformedRecordError`);
one whose `prev_hash` is not the hash the copy holds for the slot below is a rewritten
chain. A failed sync leaves the copy at its last checkpoint, consistent and verified.
"""
function sync!(copy::LocalCopy)
    check_open(copy)
    chain = chain_of(copy, "sync!")
    refuse_pinned(copy, "sync!")
    h = copy.head
    h === nothing || check_head_slot(copy, chain)
    lo = h === nothing ? -1 : h.slot
    top = gallop(chain.store, s -> slot_key(chain, s), lo)
    if top == lo
        h === nothing && throw(ChainNotFoundError("chain not found: no slot 0 at $(location(chain)), so there is no " *
            "chain to sync the local copy at $(copy.path) from. Either the bucket or prefix is not the chain's, or no " *
            "chain was created there — create_chain(chain) writes slot 0, and only that. The two cannot be told apart " *
            "from here.";
            bucket = chain.bucket, prefix = chain.prefix))
        return (; applied = 0, slot = h.slot, transaction_hash = TransactionHash(h.transaction_hash))
    end
    applied = replay!(copy, lo + 1, top).applied
    return (; applied, slot = copy.head.slot, transaction_hash = TransactionHash(copy.head.transaction_hash))
end

# A task's result, with the task's own exception rather than the TaskFailedException
# around it, so a transport failure in a read-ahead fetch reads as what it is.
function await(t::Task)
    try
        return fetch(t)
    catch e
        e isa TaskFailedException || rethrow()
        throw(e.task.exception)
    end
end

"""
    replay!(copy, first, last; clock = time_ns) -> (; applied, checkpoints)

Apply slots `first:last` of the chain to the copy, fetching `read_ahead` records ahead
through the record cache, and checkpoint by the amortized rule (ADR-0013, ADR-0023):
at `last`, and after any record once the apply time since the last checkpoint exceeds
that checkpoint's duration, both measured on `clock` (nanoseconds; a test may script
it). `checkpoints` lists the slots checkpointed. `sync!`'s inner loop; a fresh copy
binds to the chain at slot 0.
"""
function replay!(copy::LocalCopy, first::Integer, last::Integer; clock = time_ns)
    chain = chain_of(copy, "sync!")
    store, cache, bucket = chain.store, chain.cache, chain.bucket
    h = copy.head
    prev = h === nothing ? nothing : h.transaction_hash
    cid = h === nothing ? nothing : h.chain_id
    (h === nothing && first != 0) && error("replay!: a copy with no head replays from slot 0, not $first")
    tasks = Dict{Int64,Task}()
    next = Int64(first)
    checkpoints = Int64[]
    last_checkpoint_ns = 0
    applying_ns = 0
    try
        for s in Int64(first):Int64(last)
            while next <= min(last, s + chain.read_ahead - 1)
                key = slot_key(chain, next)
                tasks[next] = @async fetch_record(cache, store, bucket, key)
                next += 1
            end
            bytes = await(pop!(tasks, s))
            bytes === nothing && throw(RewrittenChainError("rewritten chain: slot $s at $(location(chain)) was there " *
                "when head discovery probed it and is absent now. The bucket is being written from outside the " *
                "protocol and nothing heals it. The local copy at $(copy.path) stays at its last checkpoint.";
                chain_id = cid, slot = s, found = nothing))
            th = Ops.transaction_hash(bytes)
            record = Ops.decode_record(bytes; slot = s)
            rcid = chain_id_string(record.chain_id)
            if cid === nothing
                cid = rcid
            elseif rcid != cid
                throw(MalformedRecordError("malformed record at slot $s: it carries chain id $rcid, the chain is $cid " *
                    "(a record of another chain was written into this prefix). No client can apply it: the chain is dead " *
                    "beyond this slot; a new chain is the recovery (ADR-0025).";
                    chain_id = cid, slot = s))
            end
            if s > 0 && record.prev_hash != prev
                throw(RewrittenChainError("rewritten chain: slot $s of chain $cid at $(location(chain)) names parent " *
                    "$(bytes2hex(record.prev_hash)), the local copy at $(copy.path) holds slot $(s - 1) as " *
                    "$(bytes2hex(prev)). The chain below was rewritten from outside the protocol, or the committer of " *
                    "slot $s had a bug; nothing heals it. The local copy stays at its last checkpoint and readable.";
                    chain_id = cid, slot = s, expected = prev, found = record.prev_hash))
            end
            t0 = clock()
            load_tables!(copy, record)
            Ops.apply!(copy.content, record)
            applying_ns += clock() - t0
            prev = th
            if applying_ns > last_checkpoint_ns || s == last
                t1 = clock()
                checkpoint!(copy, record.chain_id, s, th, record.state_fingerprint; client = record.client)
                last_checkpoint_ns = clock() - t1
                applying_ns = 0
                push!(checkpoints, s)
            end
        end
    catch
        discard!(copy)      # the copy stays at its last checkpoint; the model reloads from it
        rethrow()
    end
    return (; applied = Int64(last) - Int64(first) + 1, checkpoints)
end

# ---------------------------------------------------------------------------
# write_builder and commit! (ADR-0019, ADR-0002, ADR-0009, ADR-0007, ADR-0001)
# ---------------------------------------------------------------------------

"""
    write_builder(copy) -> WriteBuilder

A single-use write builder bound to the copy's current head (ADR-0019). The copy must
have a head — `sync!(copy)` binds a fresh one — and be live, not pinned. See
[`WriteBuilder`](@ref) for what the builder holds and [`commit!`](@ref) for what
consumes it.
"""
function write_builder(copy::LocalCopy)
    check_open(copy)
    h = copy.head
    h === nothing && throw(ArgumentError("write_builder(copy): the local copy at $(copy.path) has no head yet; " *
        "sync!(copy) binds it to the chain first"))
    refuse_pinned(copy, "write_builder")
    pending = Set{String}(name for name in keys(copy.tables) if name ∉ copy.loaded)
    return WriteBuilder(copy.content; copy, head = (; slot = h.slot, transaction_hash = h.transaction_hash), pending)
end

"""
    commit!(w; comment = nothing) -> (; slot, transaction_hash::TransactionHash, state_fingerprint::StateFingerprint)

Commit the builder's ops as one transaction record at the slot above the copy's head
(ADR-0002, ADR-0009). In order: the builder is spent (a second `commit!` is
`WriteBuilderError`, the forbidden retry written by hand); an empty builder is refused
(only genesis carries zero ops, and `create_chain` writes it); a builder taken before a
`sync!` moved the copy raises `StaleHeadError`; the head's own slot is fetched and held
against the head (ADR-0014) and its record's fingerprint against the head's (ADR-0007's
pre-check); a probe of the next slot finding it taken is `StaleHeadError` naming the
chain's head — nothing applied, nothing written. Then the ops are applied to the model —
the state gate: insert on a present key, update or delete on an absent one, refused as
`WriteBuilderError` naming the op, through the same checks apply runs (ADR-0025) — the
touched tables' files are written, the fingerprint is taken from them, the record is
built (over the store's cap — 64 MiB, 4 MiB on a gateway bucket — is `WriteBuilderError`
with the byte count) and put conditionally with the retry loop and read-back of
ADR-0010. Our record at the slot — created, or found after a lost acknowledgement —
writes the head; another client's there is `LostRaceError`, never retried; a gateway's
refusal is `WriteRefusedError`, never retried (ADR-0028). Anything short of the head
write leaves the copy at its head with the model dropped (`discard!`). Before any of it,
an S3 client at a host that is not AWS is refused with `UnsupportedStoreError` unless the
chain's `assume_first_writer_wins` is set (ADR-0016), and right after that the author is
fetched from the store (`record_author`: the environment on a plain bucket, the STS
caller's name on a gateway bucket).

`comment` is free text carried in the record, never read (ADR-0006).
"""
function commit!(w::WriteBuilder; comment = nothing)
    spend!(w)
    copy = w.copy
    copy === nothing && throw(WriteBuilderError("commit!(w): this builder was not taken over a local copy; " *
        "take one with write_builder(copy)"))
    check_open(copy)
    chain = chain_of(copy, "commit!")
    refuse_pinned(copy, "commit!")
    refuse_unsupported_store(chain, "commit!(w)")             # ADR-0016: before anything is applied
    h = copy.head
    h === nothing && throw(ArgumentError("commit!(w): the local copy at $(copy.path) has no head; sync!(copy) binds it first"))
    user = write_author(chain, h.chain_id, h.slot + 1)         # ADR-0028: the author, before anything is applied
    isempty(w.ops) && throw(WriteBuilderError("commit!(w): the builder has no ops; a record after genesis carries at least " *
        "one, and genesis is create_chain's (ADR-0019). Add ops, or do not commit."))
    if w.head.slot != h.slot || w.head.transaction_hash != h.transaction_hash
        throw(StaleHeadError("stale head: this builder was taken at slot $(w.head.slot) of chain $(h.chain_id), and the " *
            "local copy at $(copy.path) has since moved to slot $(h.slot) (a sync!). The row set was computed against a " *
            "state that has moved: recompute it and build again with write_builder(copy); this builder is spent and is " *
            "never re-run (ADR-0002).";
            chain_id = h.chain_id, slot = w.head.slot, chain_slot = h.slot))
    end
    comment === nothing || comment isa AbstractString ||
        throw(WriteBuilderError("commit!(w): comment is a $(typeof(comment)), not text"))
    store = chain.store
    # the commit pre-check (ADR-0007, ADR-0014): the head against its own record
    check_head_record(copy, chain, "The copy drifted from the chain since it was applied, and commits nothing onto it: " *
        "repair!(copy) confirms whether this machine reproduces the chain.")
    slot = h.slot + 1
    key = slot_key(chain, slot)
    # the preflight (ADR-0002): a taken next slot is a stale head, before anything is applied
    if stat_object(store, key) !== nothing
        top = gallop(store, s -> slot_key(chain, s), slot)
        throw(StaleHeadError("stale head: the local copy at $(copy.path) is at slot $(h.slot) of chain $(h.chain_id), " *
            "the chain is at slot $top. sync!(copy), recompute the row set against the fresh state, and build again with " *
            "write_builder(copy); this builder is spent and is never re-run (ADR-0002).";
            chain_id = h.chain_id, slot = h.slot, chain_slot = top))
    end
    th, staged, chain_id = try
        load_tables!(copy, unique(op.table for op in w.ops))
        for (i, op) in enumerate(w.ops)              # the state gate, through apply's own checks (ADR-0025)
            try
                Ops.apply!(copy.content, op)
            catch e
                e isa ModelError || rethrow()
                throw(WriteBuilderError("commit!(w): op $i ($(Ops.op_name(op)) on $(repr(op.table))): $(e.msg)"))
            end
        end
        staged = stage!(copy)
        chain_id = chain_id_bytes(h.chain_id)
        record = try
            Record(chain_id, slot, h.transaction_hash, staged.state_fingerprint,
                   Ops.local_client(; chain.record_host, user), comment === nothing ? nothing : String(comment), w.ops)
        catch e
            e isa ModelError || rethrow()
            throw(WriteBuilderError("commit!(w): $(e.msg)"))
        end
        bytes = Ops.encode_record(record)
        check_record_cap(store, bytes, "commit!(w)")            # ADR-0028: the store's cap, before the put
        th = Ops.transaction_hash(bytes)
        found = put_record_for!(chain, h.chain_id, slot, bytes)
        if found !== nothing
            throw(LostRaceError("lost race for slot $slot of chain $(h.chain_id) at $(location(chain)): another client's " *
                "record is there (transaction hash $(bytes2hex(Ops.transaction_hash(found)))). sync!(copy), recompute the " *
                "row set against the fresh state, and build again with write_builder(copy); this builder is spent and is " *
                "never re-run (ADR-0002).";
                chain_id = h.chain_id, slot, transaction_hash = Ops.transaction_hash(found)))
        end
        th, staged, chain_id
    catch
        discard!(copy)      # nothing was committed locally: the old head and its files stand (ADR-0009)
        rethrow()
    end
    write_head!(copy, chain_id, slot, th, staged)
    return (; slot, transaction_hash = TransactionHash(th), state_fingerprint = StateFingerprint(staged.state_fingerprint))
end

# The head against its own record (ADR-0007, ADR-0014): the slot is fetched through the
# cache and held against the head (`check_head_slot`), then the record's fingerprint
# against the head's. Returns the record; `next` is the caller's next move for the message.
function check_head_record(copy::LocalCopy, chain::Chain, next)
    h = copy.head
    bytes = check_head_slot(copy, chain)
    record = Ops.decode_record(bytes; slot = h.slot)
    record.state_fingerprint == h.state_fingerprint && return record
    here = written_by_here()
    throw(FingerprintMismatchError("state fingerprint mismatch at slot $(h.slot) (chain $(h.chain_id)): the record's " *
        "state_fingerprint is $(bytes2hex(record.state_fingerprint)), the head of the local copy at $(copy.path) " *
        "holds $(bytes2hex(h.state_fingerprint)). The record was written by $(record.client.lib) on Julia " *
        "$(record.client.julia); this client is $(here.lib) on Julia $(here.julia). $next";
        chain_id = h.chain_id, slot = h.slot, expected = record.state_fingerprint, computed = h.state_fingerprint,
        record_client = (; lib = record.client.lib, julia = record.client.julia), this_client = here))
end
