using Test
using ChainTables: ChainTables, Chain, MalformedRecordError, RewrittenChainError,
    TransactionHash, commit!, create_chain, create_table!, column!, head, insert_rows!,
    primary_key!, sync!, table, write_builder
using ChainTables.Testing: InMemoryObjectStore

include("fixtures/chains.jl")
include("fixtures/seeded_chains.jl")

# read_forward is internal: sync!, as_of and slot_at read through it. Its keep_bytes
# limit and its parent Guard are reached only by calling it.
const CT = ChainTables

function plant!(store, key, bytes)
    store.objects[key] = bytes
    store.modified[key] = 0
    return nothing
end

# A copy of every object of `from` in a new store, as a bucket copied by hand.
function copied_store(from)
    store = InMemoryObjectStore()
    foreach(((k, v),) -> plant!(store, k, Base.copy(v)), from.objects)
    return store
end

function add_row!(copy, i, tag)
    w = write_builder(copy)
    i == 1 && create_table!(w, :samples) do t
        column!(t, :id, Int64)
        primary_key!(t, :id)
    end
    insert_rows!(w, :samples, [(id = tag + i,)])
    return commit!(w)
end

# Two stores holding one chain: A's slots below `at`, then each its own records to slot 5.
function forked_stores(dir, at)
    a = InMemoryObjectStore()
    create_chain(chain_over(a, joinpath(dir, "ca$at")))
    wa = CT.open(chain_over(a, joinpath(dir, "ca$at")), joinpath(dir, "wa$at"))
    sync!(wa)
    foreach(i -> add_row!(wa, i, 100), 1:(at - 1))
    b = copied_store(a)
    wb = CT.open(chain_over(b, joinpath(dir, "cb$at")), joinpath(dir, "wb$at"))
    sync!(wb)
    foreach(i -> (add_row!(wa, i, 100); add_row!(wb, i, 200)), at:5)
    head_a = head(wa)
    close(wa)
    close(wb)
    return a, b, head_a
end

# A store that held B and was read whole into the cache `name`, then emptied and refilled
# with A: B's records are a cached run that names itself all the way down.
function refilled_store(dir, a, b, name; kw...)
    store = copied_store(b)
    chain = chain_over(store, joinpath(dir, name); kw...)
    with_copy(sync!, chain, joinpath(dir, "rb_$name"))
    empty!(store.objects)
    empty!(store.modified)
    foreach(((k, v),) -> plant!(store, k, Base.copy(v)), a.objects)
    return store, chain
end

fetched(store, n) = sort([k for (v, k) in store.calls[(n + 1):end] if v === :fetch_object])

function is_cached_from(chain, k, from)
    return read(CT.record_path(chain, slotkey(k))) == from.objects[slotkey(k)]
end

# A clock on which every record is followed by a checkpoint: apply 10, checkpoint 1.
function checkpoint_every_record()
    t, step = Ref(0), Ref(0)
    return () -> (step[] += 1; t[] += (10, 0, 1, 0)[mod1(step[] - 1, 4)])
end

transaction_hash_of(store, k) = CT.Ops.transaction_hash(store.objects[slotkey(k)])

function head_file_hashes(copy)
    files = readdir(joinpath(copy.path, "heads"))
    heads = joinpath(copy.path, "heads")
    return [CT.decode_head(read(joinpath(heads, f))).transaction_hash for f in files]
end

@testset "read_forward never applies a cached fork: read_ahead $n" for n in (1, 8)
    mktempdir() do dir
        a, b, head_a = forked_stores(dir, 2)
        store, chain = refilled_store(dir, a, b, "shared"; read_ahead = n)
        with_copy(chain, joinpath(dir, "ra")) do ra
            n = length(store.calls)
            got = CT.replay!(ra, 0, 5; clock = checkpoint_every_record())
            @test got == (; applied = 6, checkpoints = collect(0:5))
            @test fetched(store, n) == slotkey.(0:5)
            @test head(ra) == head_a
            @test head_file_hashes(ra) == [transaction_hash_of(a, 5)]
        end
        @testset "slot $k is A's in the cache" for k in 0:5
            @test is_cached_from(chain, k, a)
        end
        with_copy(chain, joinpath(dir, "rb_shared")) do rb
            @test_throws RewrittenChainError "contradicts" sync!(rb)
        end
    end
end

@testset "read_forward settles down to the anchor when the store agrees with none" begin
    mktempdir() do dir
        a, b, head_a = forked_stores(dir, 1)
        store, chain = refilled_store(dir, a, b, "down")
        with_copy(chain, joinpath(dir, "ra")) do ra
            n = length(store.calls)
            sync!(ra)
            @test fetched(store, n) == slotkey.(0:5)
            @test head(ra) == head_a
        end
        @testset "slot $k is A's in the cache" for k in 0:5
            @test is_cached_from(chain, k, a)
        end
    end
end

@testset "read_forward with keep_bytes = 0 fetches the run again on the way up" begin
    mktempdir() do dir
        a, b, _ = forked_stores(dir, 2)
        store, chain = refilled_store(dir, a, b, "kept")
        n = length(store.calls)
        got = Tuple{Int64, Vector{UInt8}}[]
        record_hash! = (k, r, th) -> (push!(got, (k, th)); false)
        CT.read_forward(record_hash!, chain, 0, 5; keep_bytes = 0)
        @test got == [(k, transaction_hash_of(a, k)) for k in 0:5]
        @test fetched(store, n) == slotkey.([0, 1, 2, 2, 3, 3, 4, 4, 5])
    end
end

@testset "read_forward yields what the store vouched for before a slot gone" begin
    mktempdir() do dir
        a, b, _ = forked_stores(dir, 2)
        store, chain = refilled_store(dir, a, b, "gone")
        store.fault = (verb, key, phase) -> verb === :fetch_object && key == slotkey(5) &&
            phase === :after && (delete!(store.objects, slotkey(3)); nothing)
        with_copy(chain, joinpath(dir, "ra")) do ra
            replay = () -> CT.replay!(ra, 0, 5; clock = checkpoint_every_record())
            err = (@test_throws RewrittenChainError "absent now" replay()).value
            @test err.slot == 3 && err.found === nothing
            @test head(ra).slot == 2
            @test head(ra).transaction_hash == transaction_hash_of(a, 2)
        end
        @test is_cached_from(chain, 2, a)
        @test is_cached_from(chain, 3, b) && is_cached_from(chain, 4, b)
    end
end

@testset "read_forward stops early at a target in a cached fork once vouched" begin
    mktempdir() do dir
        a, b, _ = forked_stores(dir, 2)
        store, chain = refilled_store(dir, a, b, "stop")
        # Files of the layout before the namespace existed are never read.
        old = joinpath(dir, "stop", "bkt", "p", "000000000000")
        mkpath(dirname(old))
        write(old, b"cached before the namespace")
        theirs = TransactionHash(transaction_hash_of(b, 2))
        msg = "no record of the chain at bkt/p hashes to"
        @test_throws ArgumentError msg CT.target_slot(chain, theirs)
        @test CT.target_slot(chain, TransactionHash(transaction_hash_of(a, 2))) == 2
    end
end

function with_four_records(f)
    mktempdir() do dir
        store = InMemoryObjectStore()
        chain = chain_over(store, joinpath(dir, "cache"))
        create_chain(chain)
        with_copy(chain, joinpath(dir, "one")) do copy
            sync!(copy)
            foreach(i -> add_row!(copy, i, 0), 1:3)
            f(dir, store, chain, copy)
        end
    end
    return nothing
end

@testset "read_forward raises the store's word over a damaged cache, keeping the file" begin
    with_four_records() do dir, store, chain, copy
        two = store.objects[slotkey(2)]
        write(CT.record_path(chain, slotkey(2)), b"damaged")
        plant!(store, slotkey(2), b"not a record either")
        with_copy(chain, joinpath(dir, "bad")) do fresh
            @test_throws MalformedRecordError "cannot be applied" sync!(fresh)
            @test read(CT.record_path(chain, slotkey(2))) == b"damaged"
            @test head(fresh).slot == 0          # slot 1 came from the cache, unvouched
            plant!(store, slotkey(2), two)
            @test sync!(fresh).slot == 3
            @test read(CT.record_path(chain, slotkey(2))) == two
        end
    end
end

function seen(chain; kw...)
    got = Tuple{Int64, Vector{UInt8}}[]
    CT.read_forward((s, r, th) -> (push!(got, (s, th)); false), chain, 0, 3; kw...)
    return got
end

@testset "read_forward past keep_bytes reads a vouched run again" begin
    with_four_records() do dir, store, chain, copy
        one = chain_over(store, chain.cache.dir; read_ahead = 1)
        expected = [(k, transaction_hash_of(store, k)) for k in 0:3]
        @test seen(one; keep_bytes = 0) == seen(one) == expected
        store.fault = (verb, key, phase) -> verb === :fetch_object && key == slotkey(3) &&
            phase === :before && write(CT.record_path(chain, slotkey(2)), b"changed")
        @test seen(one; keep_bytes = 0) == expected
        @test read(CT.record_path(chain, slotkey(2))) == store.objects[slotkey(2)]
    end
end

# While slot 3 is fetched, another process changes the cached slot 2 and an actor outside
# the protocol rewrites the stored one.
function rewrite_two_before_three(chain, store)
    return function (verb, key, phase)
        verb === :fetch_object && key == slotkey(3) && phase === :before || return nothing
        write(CT.record_path(chain, slotkey(2)), b"changed")
        plant!(store, slotkey(2), b"rewritten")
        return nothing
    end
end

@testset "read_forward past keep_bytes raises when the store lost the record" begin
    with_four_records() do dir, store, chain, copy
        one = chain_over(store, chain.cache.dir; read_ahead = 1)
        two = transaction_hash_of(store, 2)
        store.fault = rewrite_two_before_three(chain, store)
        msg = "no longer holds"
        err = (@test_throws RewrittenChainError msg seen(one; keep_bytes = 0)).value
        @test (err.slot, err.expected) == (2, two)
        @test err.found == CT.Ops.transaction_hash(b"rewritten")
        @test read(CT.record_path(chain, slotkey(2))) == b"changed"
    end
end

@testset "read_forward takes a parent exactly when it starts above slot 0" begin
    with_four_records() do dir, store, chain, copy
        msg = "a parent is given exactly when first > 0"
        @test_throws ArgumentError msg CT.read_forward((s, r, th) -> false, chain, 1, 3)
        parent = CT.ParentLink(transaction_hash_of(store, 0), copy.head.chain_id, "x")
        never = (s, r, th) -> false
        @test_throws ArgumentError msg CT.read_forward(never, chain, 0, 3; parent)
    end
end
