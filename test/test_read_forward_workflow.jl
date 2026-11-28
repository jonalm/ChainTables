using Test
using ChainTables: ChainTables, Ops, RewrittenChainError, TransactionHash, as_of, head,
    sync!

# `read_forward` and `replay!` are internal. They are called here for what no API name
# can set: `keep_bytes`, which production reaches only with 64 MiB of records waiting,
# and the clock that places the checkpoints of a replay.
include("fixtures/chain_copies.jl")
include("fixtures/object_stores.jl")
include("fixtures/forged_records.jl")
include("fixtures/forked_chains.jl")

const DEBUG = Base.CoreLogging.Debug
const REPLACED = (:debug, "the record cache held other bytes than the store")
const VANISHED = "the slot was there when head discovery probed it and is absent now"
const READS_AHEAD = [1, 8]

stored_hashes(store, slots) = [(Int64(slot), stored_hash(store, slot)) for slot in slots]
function is_cached_from(chain, slot, store)
    return read(record_file(chain, slot)) == store.objects[slot_key(slot)]
end


# The slots and transaction hashes that a read of slots 0 to `last` yields.
function yielded(chain, last; keywords...)
    seen = Tuple{Int64, Vector{UInt8}}[]
    collect_record = (slot, record, hash) -> (push!(seen, (slot, hash)); false)
    ChainTables.read_forward(collect_record, chain, 0, last; keywords...)
    return seen
end

# A chain of four records, read with `read_ahead = 1` through a warm record cache.
function with_one_ahead(f)
    with_samples_copy() do local_copy
        commit_sample!(local_copy, 3)
        commit_sample!(local_copy, 4)
        chain = local_copy.chain
        f(chain_in(dirname(local_copy.path); chain.store, read_ahead = 1))
    end
    return nothing
end

# The cached file of slot 2 and the store's record of slot 2 both change.
function change_cache_and_store(chain)
    write(record_file(chain, 2), b"changed")
    plant!(chain.store, slot_key(2), b"rewritten")
    return nothing
end

# A step of the six-tick clock of the amortized rule: apply takes 1 tick, and the
# checkpoints at slots 0, 6 and 11 take 5.
function five_tick_checkpoints()
    readings = Int[]
    time = 0
    for slot in 0:11
        push!(readings, time, time + 1)
        time += 1
        slot in (0, 6, 11) || continue
        push!(readings, time, time + 5)
        time += 5
    end
    return ScriptedClock(readings)
end

@testset "a replay writes a checkpoint when apply has taken longer than the last one" begin
    with_samples_copy() do local_copy
        foreach(id -> commit_sample!(local_copy, id), 3:12)
        with_copy_beside(local_copy, "fresh") do fresh
            # Apply takes one tick and a checkpoint one tick: after the first record,
            # then at every second one, and at the end.
            replayed = ChainTables.replay!(fresh, 0, 11; clock = CyclingClock([1]))
            @test replayed == (; applied = 12, checkpoints = [0, 2, 4, 6, 8, 10, 11])
            @test head(fresh) == head(local_copy)
        end
    end
end

@testset "a replay waits out a checkpoint that took as long as five applies" begin
    with_samples_copy() do local_copy
        foreach(id -> commit_sample!(local_copy, id), 3:12)
        with_copy_beside(local_copy, "fresh") do fresh
            # A checkpoint at any other slot would read the script out of step.
            clock = five_tick_checkpoints()
            replayed = ChainTables.replay!(fresh, 0, 11; clock)
            @test replayed == (; applied = 12, checkpoints = [0, 6, 11])
            @test isempty(clock.readings)
            @test head(fresh) == head(local_copy)
        end
    end
end

@testset "a cached fork is never applied" begin
    @testset "read_ahead = $read_ahead" for read_ahead in READS_AHEAD
        mktempdir() do dir
            fork = forked_stores(dir, 2)
            chain = refilled_chain(dir, fork, "shared"; read_ahead)
            store = chain.store
            # The cached slots 2 to 4 of `b` name each other all the way down.
            with_copy(chain, joinpath(dir, "reader")) do reader
                n = length(store.calls)
                # A checkpoint after every record: a record applied before it was
                # vouched for would reach the disk.
                clock = checkpoint_every_record()
                replayed = @test_logs(
                    REPLACED, REPLACED, REPLACED, REPLACED, min_level = DEBUG,
                    ChainTables.replay!(reader, 0, 5; clock)
                )
                @test replayed == (; applied = 6, checkpoints = collect(0:5))
                # Slot 0 and the top, then the run below the top down to slot 1, where
                # the store agrees with the cache.
                @test sort(fetched_after(store, n)) == slot_key.(0:5)
                @test head(reader) == fork.head
                @test isequal(sample_rows(reader), fork.rows)
            end
            @testset "slot $slot" for slot in 0:5
                @test is_cached_from(chain, slot, fork.a)
            end
        end
    end
end

@testset "a copy that was built on the fork finds a rewritten chain" begin
    mktempdir() do dir
        fork = forked_stores(dir, 2)
        chain = refilled_chain(dir, fork, "shared")
        with_copy(chain, joinpath(dir, "reader_of_b_shared")) do built_on_b
            rewritten = "the slot of the local copy's head holds another record"
            @test_throws RewrittenChainError rewritten sync!(built_on_b)
        end
    end
end

@testset "a fork down to slot 1 is settled by the genesis record" begin
    mktempdir() do dir
        fork = forked_stores(dir, 1)
        chain = refilled_chain(dir, fork, "down")
        with_copy(chain, joinpath(dir, "reader")) do reader
            n = length(chain.store.calls)
            @test_logs REPLACED REPLACED REPLACED REPLACED REPLACED min_level = DEBUG sync!(
                reader
            )
            @test sort(fetched_after(chain.store, n)) == slot_key.(0:5)
            @test head(reader) == fork.head
            @test isequal(sample_rows(reader), fork.rows)
        end
        @testset "slot $slot" for slot in 0:5
            @test is_cached_from(chain, slot, fork.a)
        end
    end
end

@testset "a settled fork is fetched again on the way up when nothing is kept" begin
    mktempdir() do dir
        fork = forked_stores(dir, 2)
        chain = refilled_chain(dir, fork, "kept")
        n = length(chain.store.calls)
        seen = @test_logs REPLACED REPLACED REPLACED REPLACED min_level = DEBUG yielded(
            chain, 5; keep_bytes = 0
        )
        @test seen == stored_hashes(fork.a, 0:5)
        @test sort(fetched_after(chain.store, n)) == slot_key.([0, 1, 2, 2, 3, 3, 4, 4, 5])
    end
end

@testset "a slot that vanishes while a fork is settled throws after the vouched part" begin
    mktempdir() do dir
        fork = forked_stores(dir, 2)
        chain = refilled_chain(dir, fork, "gone")
        store = chain.store
        vanish = () -> delete!(store.objects, slot_key(3))
        store.fault = FaultAt(:fetch_object, slot_key(5), :after, vanish)
        with_copy(chain, joinpath(dir, "reader")) do reader
            clock = checkpoint_every_record()
            # Slot 5 is never cached: the read fails below it.
            err = @test_logs REPLACED min_level = DEBUG (
                @test_throws RewrittenChainError VANISHED ChainTables.replay!(
                    reader, 0, 5; clock
                )
            )
            @test (err.value.slot, err.value.found) == (3, nothing)
            # Slot 1 is vouched for by the store's agreeing bytes, and slot 2 by the
            # store's own: both are applied.
            @test head(reader).slot == 2
            @test head(reader).transaction_hash == stored_hash(fork.a, 2)
        end
        @test is_cached_from(chain, 2, fork.a)
        @test is_cached_from(chain, 3, fork.b)
        @test is_cached_from(chain, 4, fork.b)
    end
end

@testset "a scan for a record of the cached fork does not find it" begin
    mktempdir() do dir
        fork = forked_stores(dir, 2)
        chain = refilled_chain(dir, fork, "stop")
        # Files of the cache layout before the namespace are never read.
        old_layout = joinpath(dir, "stop", "bkt", "p")
        mkpath(old_layout)
        foreach(slot -> write(joinpath(old_layout, lpad(slot, 12, '0')), b"old"), 0:5)
        of_fork = TransactionHash(stored_hash(fork.b, 2))
        not_found = "no record of the chain at bkt/p has the transaction hash"
        @test_logs REPLACED REPLACED REPLACED REPLACED min_level = DEBUG (
            @test_throws ArgumentError not_found as_of(
                chain, of_fork
            )
        )
        pinned = as_of(chain, TransactionHash(stored_hash(fork.a, 2)))
        @test head(pinned).slot == 2
        close(pinned)
    end
end

@testset "a record that was not kept is read again once it is vouched for" begin
    with_one_ahead() do chain
        expected = stored_hashes(chain.store, 0:3)
        @test yielded(chain, 3) == expected
        @test yielded(chain, 3; keep_bytes = 0) == expected
    end
end

@testset "a cache file that changes during a read is read from the store" begin
    with_one_ahead() do chain
        store = chain.store
        change = () -> write(record_file(chain, 2), b"changed")
        store.fault = FaultAt(:fetch_object, slot_key(3), :before, change)
        seen = @test_logs REPLACED min_level = DEBUG yielded(chain, 3; keep_bytes = 0)
        @test seen == stored_hashes(store, 0:3)
        @test is_cached_from(chain, 2, store)
    end
end

@testset "a changed cache file over a store that changed too is a rewritten chain" begin
    with_one_ahead() do chain
        store = chain.store
        named = stored_hash(store, 2)
        change = () -> change_cache_and_store(chain)
        store.fault = FaultAt(:fetch_object, slot_key(3), :before, change)
        gone = "the store does not hold the record that the slot above names"
        err = @test_logs min_level = DEBUG (
            @test_throws RewrittenChainError gone yielded(
                chain, 3; keep_bytes = 0
            )
        )
        e = err.value
        @test (e.bucket, e.prefix, e.slot) == ("bkt", "p", 2)
        @test (e.expected, e.found) == (named, Ops.transaction_hash(b"rewritten"))
        # The file stays as it was, as evidence.
        @test read(record_file(chain, 2)) == b"changed"
    end
end

@testset "a read has a parent exactly when it starts above slot 0" begin
    with_one_ahead() do chain
        parent = ChainTables.ParentLink(stored_hash(chain.store, 0), "A"^26)
        ignore = (slot, record, hash) -> false
        mismatch = "a read has a parent exactly when it starts above slot 0"
        @test_throws ArgumentError mismatch ChainTables.read_forward(ignore, chain, 1, 3)
        @test_throws ArgumentError mismatch ChainTables.read_forward(
            ignore, chain, 0, 3; parent
        )
    end
end
