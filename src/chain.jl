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
  [`Chain(bucket::Bucket, prefix)`](@ref Bucket) builds it from the bucket's profile.
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
bucket root. Each `/`-separated segment of the prefix, and the bucket name, is a
record-cache directory, so it must be portable to every filesystem: lowercase `a-z`,
`0-9`, `.`, `_`, `-`; not `.` or `..`; not ending in `.`; not a Windows device name such
as `con` or `nul`. The prefix is at most 100 characters, and the longest record-cache path
for the chain, `cache_dir` included, at most 259: Windows' `MAX_PATH` (ADR-0034).
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
    check_bucket_name(bucket)
    check_prefix(prefix)
    cache = RecordCache(; dir = cache_dir)
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
    record_path(cache, store, bucket, isempty(prefix) ? head_filename(0) : prefix * "/" * head_filename(0))   # every slot's path is as long (ADR-0034)
    (store isa GatewayObjectStore && !record_user) && throw(ArgumentError("Chain: record_user = false with a gateway " *
        "store: the gateway refuses a record with no author (ADR-0028), so this chain could never commit; leave record_user = true"))
    return Chain{typeof(store)}(String(bucket), String(prefix), region === nothing ? nothing : String(region), credentials,
                                endpoint === nothing ? nothing : String(endpoint), path_style, assume_first_writer_wins,
                                Int(read_ahead), cache, store, record_host, record_user)
end

# The bucket-name rules, shared with `Bucket` (bucket.jl, ADR-0029).
function check_bucket_name(bucket::AbstractString)
    isempty(bucket) && throw(ArgumentError("Chain: the bucket name is empty"))
    '.' in bucket && throw(ArgumentError("Chain: bucket name $(repr(bucket)) contains a dot, which breaks certificate " *
        "matching under the virtual-hosted URL ChainTables builds (ADR-0010); use a bucket without one"))
    problem = portable_segment_problem(bucket)
    problem === nothing || throw(ArgumentError("Chain: bucket name $(repr(bucket)) $problem; it is a record-cache " *
        "directory, and must be portable to every filesystem (ADR-0034)"))
    return nothing
end

# The prefix is opaque (ADR-0031), but each `/`-separated segment of a slot key becomes a
# record-cache directory, so it must be portable to every filesystem (ADR-0034). Refusing a
# bad one here, before any I/O, keeps `create_chain` from writing a slot 0 no client could cache.
# With a 63-character bucket (S3's longest) under the longest cache namespace (ADR-0040), the
# cache path below `cache_dir` is at most 12 + 1 + 63 + 1 + 100 + 1 + 20 = 198 characters,
# leaving 61 of MAX_PORTABLE_PATH for `cache_dir`.
const MAX_PREFIX_LENGTH = 100

function check_prefix(prefix::AbstractString)
    (startswith(prefix, "/") || endswith(prefix, "/")) && throw(ArgumentError(
        "Chain: prefix $(repr(prefix)) begins or ends with '/'; a slot key is <prefix>/<12 digits>, so give the prefix without them"))
    isempty(prefix) && return nothing
    length(prefix) <= MAX_PREFIX_LENGTH || throw(ArgumentError("Chain: prefix $(repr(prefix)) is $(length(prefix)) " *
        "characters, over $MAX_PREFIX_LENGTH; the record cache's paths must fit Windows' $MAX_PORTABLE_PATH under any " *
        "reasonable cache_dir (ADR-0034)"))
    for s in split(prefix, '/')
        problem = portable_segment_problem(s)
        problem === nothing || throw(ArgumentError("Chain: prefix $(repr(prefix)) has the segment $(repr(s)), which " *
            "$problem; each '/'-separated segment of a slot key is a record-cache directory, and must be portable to " *
            "every filesystem (ADR-0034)"))
    end
    return nothing
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
    path = record_path(chain.cache, chain.store, chain.bucket, slot_key(chain, slot))
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

# The same for a gateway that fills another bucket than the chain's (ADR-0029).
function refused_for(e::GatewayMismatchError, chain::Chain, chain_id, slot)
    key = something(e.key, slot_key(chain, slot))
    msg = "gateway mismatch for slot $slot of chain $chain_id at $(location(chain)): " * chopprefix(e.msg, "gateway mismatch: ")
    return GatewayMismatchError(msg; chain_id, slot, key, e.bucket, e.gateway)
end

# `put_record!`, with a gateway's refusal or mismatch enriched for the chain and the slot.
function put_record_for!(chain::Chain, chain_id, slot, bytes)
    try
        return put_record!(chain.store, chain.cache, chain.bucket, slot_key(chain, slot), bytes)
    catch e
        e isa Union{WriteRefusedError,GatewayMismatchError} ? throw(refused_for(e, chain, chain_id, slot)) : rethrow()
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


"""
    try_create_chain(chain) -> (; chain_id, slot, transaction_hash) or nothing

Run [`create_chain`](@ref) and return what it returns, or `nothing` when a chain is
already at `chain`'s bucket and prefix — the `LostRaceError` slot 0 raises, and nothing
else, is swallowed (ADR-0033). For setup that runs more than once. It is still a
creation: a typo'd prefix mints a chain in silence, which is why `create_chain` itself
raises (ADR-0019). Every other error propagates unchanged.
"""
function try_create_chain(chain::Chain)
    try
        return create_chain(chain)
    catch e
        e isa LostRaceError || rethrow()
        return nothing
    end
end


# ---------------------------------------------------------------------------
# sync! (ADR-0013, ADR-0012, ADR-0014)
# ---------------------------------------------------------------------------

# The head's own slot, fetched through the record cache and held against the head
# (ADR-0014): absent, or bytes of another hash, is a rewritten chain — or, when the
# record there names another chain, the wrong chain. Cached bytes of another hash are
# fetched again past the cache first, and replace the file if they are the head's: a
# damaged cache file is not the chain's word (ADR-0040). Returns the record's bytes.
function check_head_slot(copy::LocalCopy, chain::Chain)
    h = copy.head
    where = location(chain)
    key = slot_key(chain, h.slot)
    bytes, cached = fetch_record_from(chain.cache, chain.store, chain.bucket, key)
    if cached && Ops.transaction_hash(bytes) != h.transaction_hash
        bytes = fetch_object(chain.store, key)
        bytes === nothing || Ops.transaction_hash(bytes) != h.transaction_hash ||
            heal_record!(chain.cache, chain.store, chain.bucket, key, bytes)
    end
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
each record in slot order once [`read_forward`](@ref) has held it against the chain
(ADR-0040: a cached record waits for a record the store returned to name it, and a hit
that fails is fetched again before the chain is blamed), and checkpoint — always at the
end, and mid-replay whenever the apply time since the last checkpoint exceeds the last
checkpoint's duration (ADR-0023).
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

# ---------------------------------------------------------------------------
# The forward reader (ADR-0040, ADR-0013, ADR-0014): the chain's records in slot order,
# each held against its parent and yielded only once the store vouches for its bytes.
# ---------------------------------------------------------------------------

# How many stored bytes of cached records `read_forward` keeps decoded while it waits for
# the store to vouch for them; records past it are read from the cache again when vouched.
const PENDING_BYTES = 64 * 2^20

"""
    read_forward(f, chain, first, last; prev = nothing, chain_id = nothing, holder = nothing, tail = "",
                 keep_bytes = PENDING_BYTES) -> nothing

Call `f(slot, record, transaction_hash)` for the records of slots `first:last` in slot
order, stopping early when `f` returns `true`. Records are fetched through the record
cache `read_ahead` ahead, and each is checked: it decodes, carries the chain's id —
`chain_id`, else slot 0's — and names its parent's hash: `prev`, the hash `holder` (in
words: "the local copy at …") holds for slot `first - 1`, or, from slot 0, none. `prev`,
`holder` and `chain_id` are given together, exactly when `first > 0`.

The record cache is not the chain's word (ADR-0040). A record the store returned is
yielded once checked; a cached one only once a record the store returned names it,
directly or through a run of cached records naming each other. The last record of the
read, and slot 0, are fetched from the store past the cache, so every read ends vouched.
A check that fails is asked of the store: the slot's own bytes, then, from the top down,
the cached run below it, until the store agrees with the cache. Bytes the store returned
replace a cache file that differs ([`heal_record!`](@ref)) once they pass. Only the
store's bytes raise `RewrittenChainError` (a slot vanished, a parent not named) or
`MalformedRecordError` (bytes that do not decode, another chain's id), and what the store
vouched for below the failing slot is yielded first. `tail` closes the rewritten-chain
messages. Up to `keep_bytes` of the stored bytes of records waiting to be vouched for are
kept decoded, and as much again of the store's bytes while a cached run is asked of the
store; the rest is read again when needed — a cache file that changed meanwhile is read
from the store, which must hold the bytes the chain names.
"""
function read_forward(f, chain::Chain, first::Integer, last::Integer;
                      prev = nothing, chain_id = nothing, holder = nothing, tail = "", keep_bytes = PENDING_BYTES)
    first, last = Int64(first), Int64(last)
    given = (prev !== nothing, holder !== nothing, chain_id !== nothing)
    (all(given) || !any(given)) && all(given) == (first > 0) ||
        error("read_forward: prev, holder and chain_id are given together, exactly when the read starts above slot 0")
    where = location(chain)
    key(s) = slot_key(chain, s)
    cid = chain_id
    # `bytes` as slot `s`, whose parent is `parent` (`(; th, is)`: the hash and the words
    # naming who holds it): the record, or the error to raise once the store agrees
    function check(bytes, s, parent)
        bytes === nothing && return RewrittenChainError("rewritten chain: slot $s at $where was there when head " *
            "discovery probed it and is absent now. The bucket is being written from outside the protocol and nothing " *
            "heals it.$tail"; chain_id = cid, slot = s, found = nothing)
        record = try
            Ops.decode_record(bytes; slot = s)
        catch e
            e isa MalformedRecordError || rethrow()
            return e
        end
        rcid = chain_id_string(record.chain_id)
        cid === nothing || rcid == cid || return MalformedRecordError("malformed record at slot $s: it carries chain id " *
            "$rcid, the chain is $cid (a record of another chain was written into this prefix). No client can apply it: " *
            "the chain is dead beyond this slot; a new chain is the recovery (ADR-0025)."; chain_id = cid, slot = s)
        (parent === nothing || record.prev_hash == parent.th) && return record
        return RewrittenChainError("rewritten chain: slot $s of chain $cid at $where names parent " *
            "$(bytes2hex(record.prev_hash)), $(parent.is) $(bytes2hex(parent.th)). The chain below was rewritten from " *
            "outside the protocol, or the committer of slot $s had a bug; nothing heals it.$tail";
            chain_id = cid, slot = s, expected = parent.th, found = record.prev_hash)
    end
    hashed(s, th) = (; th, is = "slot $s hashes to")
    anchor = prev === nothing ? nothing : (; th = prev, is = "$holder holds slot $(first - 1) as")   # the last record vouched for
    # checked, not yet yielded: a cached run waiting to be vouched for, or, after `settle!`, one the store vouched for;
    # `size` is what the record counts against `keep_bytes`, 0 when it was not kept
    pending = @NamedTuple{slot::Int64, th::Vector{UInt8}, record::Any, size::Int}[]
    pending_bytes = 0
    function hold!(s, th, record, n)
        keep = pending_bytes + n <= keep_bytes
        push!(pending, (; slot = s, th, record = keep ? record : nothing, size = keep ? n : 0))
        keep && (pending_bytes += n)
        return nothing
    end
    # The cached run in `pending` failed to vouch for what follows it: ask the store for it
    # from the top down until the store agrees with the cache — that record vouches for
    # the run below it — then check the store's bytes above that point upwards, holding
    # them as the run. The walk down keeps up to `keep_bytes` of the store's bytes and
    # fetches the rest again on the way up. Returns the run's top as a parent, or the
    # store's error, `pending` then holding the part of the run the store vouched for.
    function settle!()
        fresh = Dict{Int,Any}()          # index in `pending` => the store's bytes, or nothing
        fresh_bytes = 0
        agree = length(pending)
        while agree >= 1
            bytes = fetch_object(chain.store, key(pending[agree].slot))
            bytes !== nothing && Ops.transaction_hash(bytes) == pending[agree].th && break
            n = bytes === nothing ? 0 : length(bytes)
            fresh_bytes + n <= keep_bytes && (fresh[agree] = bytes; fresh_bytes += n)
            agree -= 1
        end
        above = [p.slot for p in pending[agree+1:end]]
        resize!(pending, agree)
        pending_bytes = sum((p.size for p in pending); init = 0)
        parent = agree == 0 ? anchor : hashed(pending[agree].slot, pending[agree].th)
        for (j, s) in zip(agree+1:agree+length(above), above)
            bytes = haskey(fresh, j) ? pop!(fresh, j) : fetch_object(chain.store, key(s))
            got = check(bytes, s, parent)
            got isa Exception && return got
            heal_record!(chain.cache, chain.store, chain.bucket, key(s), bytes)
            th = Ops.transaction_hash(bytes)
            hold!(s, th, got, length(bytes))
            parent = hashed(s, th)
        end
        return parent
    end
    # A vouched-for record that was not kept: from the cache again, or, when the file
    # changed meanwhile (damaged, or written by another process), from the store, which
    # must hold the bytes the chain names; they replace the file.
    function reread(s, th)
        bytes = cached_record(chain, s)
        if bytes === nothing || Ops.transaction_hash(bytes) != th
            bytes = fetch_object(chain.store, key(s))
            found = bytes === nothing ? nothing : Ops.transaction_hash(bytes)
            found == th || throw(RewrittenChainError("rewritten chain: slot $s of chain $cid at $where " *
                (found === nothing ? "is absent" : "holds a record hashing to $(bytes2hex(found))") * "; the record " *
                "above it names $(bytes2hex(th)). The bucket is being written from outside the protocol and nothing " *
                "heals it.$tail"; chain_id = cid, slot = s, expected = th, found))
            heal_record!(chain.cache, chain.store, chain.bucket, key(s), bytes)
        end
        return Ops.decode_record(bytes; slot = s)
    end
    # Yield the vouched-for run in `pending`; `true` when `f` stopped the read.
    function flush!()
        for p in pending
            f(p.slot, p.record === nothing ? reread(p.slot, p.th) : p.record, p.th) === true && return true
        end
        anchor = isempty(pending) ? anchor : hashed(pending[end].slot, pending[end].th)
        empty!(pending)
        pending_bytes = 0
        return false
    end
    tasks = Dict{Int64,Task}()
    next = first
    try
        for s in first:last
            while next <= min(last, s + chain.read_ahead - 1)
                k = next
                tasks[k] = k == last || k == 0 ? @async((fetch_object(chain.store, key(k)), false)) :
                    @async(fetch_record_from(chain.cache, chain.store, chain.bucket, key(k)))
                next += 1
            end
            bytes, cached = await(pop!(tasks, s))
            parent = isempty(pending) ? anchor : hashed(pending[end].slot, pending[end].th)
            got = check(bytes, s, parent)
            if got isa Exception && cached          # the store's word before the chain is blamed: this slot's bytes…
                bytes, cached = fetch_object(chain.store, key(s)), false
                got = check(bytes, s, parent)
            end
            if got isa Exception && !isempty(pending)   # … then the cached run below, which nothing has vouched for
                settled = settle!()
                got = settled isa Exception ? settled : check(bytes, s, settled)
                if got isa Exception        # the store's word raises, after what it vouched for below the failure
                    flush!() && return nothing
                    throw(got)
                end
            end
            got isa Exception && throw(got)
            cid === nothing && (cid = chain_id_string(got.chain_id))
            th = Ops.transaction_hash(bytes)
            if cached
                hold!(s, th, got, length(bytes))
            else
                heal_record!(chain.cache, chain.store, chain.bucket, key(s), bytes)
                flush!() && return nothing
                f(s, got, th) === true && return nothing
                anchor = hashed(s, th)
            end
        end
    finally
        for t in values(tasks)      # reads ahead of an early stop or a failure: let them land, unawaited
            try
                wait(t)
            catch
            end
        end
    end
    isempty(pending) || error("read_forward: slot $last was fetched from the store, so nothing is left unvouched")
    return nothing
end

"""
    replay!(copy, first, last; clock = time_ns) -> (; applied, checkpoints)

Apply slots `first:last` of the chain to the copy, each record as [`read_forward`](@ref)
yields it — fetched `read_ahead` ahead through the record cache and checked against the
chain — and checkpoint by the amortized rule (ADR-0013, ADR-0023): at `last`, and after
any record once the apply time since the last checkpoint exceeds that checkpoint's
duration, both measured on `clock` (nanoseconds; a test may script it). `checkpoints`
lists the slots checkpointed. `sync!`'s inner loop; a fresh copy binds to the chain at
slot 0.
"""
function replay!(copy::LocalCopy, first::Integer, last::Integer; clock = time_ns)
    chain = chain_of(copy, "sync!")
    h = copy.head
    (h === nothing && first != 0) && error("replay!: a copy with no head replays from slot 0, not $first")
    checkpoints = Int64[]
    last_checkpoint_ns = 0
    applying_ns = 0
    try
        read_forward(chain, first, last; prev = h === nothing ? nothing : h.transaction_hash,
                     chain_id = h === nothing ? nothing : h.chain_id,
                     holder = h === nothing ? nothing : "the local copy at $(copy.path)",
                     tail = " The local copy at $(copy.path) stays at its last checkpoint and readable.") do s, record, th
            t0 = clock()
            load_tables!(copy, record)
            Ops.apply!(copy.content, record)
            applying_ns += clock() - t0
            if applying_ns > last_checkpoint_ns || s == last
                t1 = clock()
                checkpoint!(copy, record.chain_id, s, th, record.state_fingerprint; client = record.client)
                last_checkpoint_ns = clock() - t1
                applying_ns = 0
                push!(checkpoints, s)
            end
            return false
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
                Ops.apply!(copy.content, op, slot)   # the target slot; a lost race never re-applies, the builder is spent
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
