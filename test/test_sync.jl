using Test
using ChainTables: ChainTables, ChainNotFoundError, MalformedRecordError, Ops,
    PinnedCopyError, RewrittenChainError, TransportError, WrongChainError, create_chain,
    head, put_object_if_absent, sync!, tables
using ChainTables.Ops: Insert

include("fixtures/chain_copies.jl")
include("fixtures/object_stores.jl")
include("fixtures/forged_records.jl")

const TWO_SAMPLES = [(1, "a", 1.5), (2, "b", missing)]
const ABSENT_HEAD = "the slot of the local copy's head is absent"
const OTHER_HEAD = "the slot of the local copy's head holds another record"

table_files(local_copy) = sort(readdir(joinpath(local_copy.path, "tables")))

# The record at `slot` again, with another comment: of this chain, with the right
# parent, and with another transaction hash.
function rewritten_record(local_copy, slot)
    store = local_copy.chain.store
    record = Ops.decode_record(store.objects[slot_key(slot)]; slot)
    return forged_record(
        local_copy, slot, record.prev_hash; comment = "rewritten", record.ops,
        fingerprint = record.state_fingerprint,
    )
end

@testset "sync! binds a fresh copy at slot 0" begin
    mktempdir() do dir
        chain = chain_in(dir)
        created = create_chain(chain)
        with_copy(chain, joinpath(dir, "copy")) do local_copy
            # `open` made no request.
            @test length(chain.store.calls) == 1
            @test @inferred(sync!(local_copy)) ==
                (; applied = 1, slot = 0, created.transaction_hash)
            @test head(local_copy).slot == 0
            @test tables(local_copy) == String[]
            # Head discovery probed slots 0 and 1. Slot 0 comes from the store, though
            # `create_chain` cached it: nothing vouches for a cached genesis.
            @test chain.store.calls[2:end] == [
                (:stat_object, slot_key(0)), (:stat_object, slot_key(1)),
                (:fetch_object, slot_key(0)),
            ]
            @test isfile(record_file(chain, 0))
        end
    end
end

@testset "sync! applies nothing when the chain has not moved" begin
    with_chain_copy() do local_copy
        store = local_copy.chain.store
        n = length(store.calls)
        synced = sync!(local_copy)
        @test (synced.applied, synced.slot) == (0, 0)
        @test synced.transaction_hash == head(local_copy).transaction_hash
        # The head's own slot is asked of the store, past the cache, then one probe.
        @test store.calls[(n + 1):end] ==
            [(:fetch_object, slot_key(0)), (:stat_object, slot_key(1))]
    end
end

@testset "sync! finds no chain for a fresh copy where there is no slot 0" begin
    mktempdir() do dir
        chain = chain_in(dir)
        with_copy(chain, joinpath(dir, "copy")) do local_copy
            err = @test_throws ChainNotFoundError "the call was `sync!`" sync!(local_copy)
            @test (err.value.bucket, err.value.prefix) == ("bkt", "p")
            @test_throws ArgumentError "has no head yet" head(local_copy)
            # A miss is not cached: a chain created afterwards is seen at once.
            create_chain(chain)
            @test sync!(local_copy).slot == 0
        end
    end
end

@testset "sync! replays the records of another client to the same state" begin
    with_samples_copy() do local_copy
        with_copy_beside(local_copy, "two") do second
            synced = sync!(second)
            @test (synced.applied, synced.slot) == (2, 1)
            @test head(second) == head(local_copy)
            @test isequal(sample_rows(second), TWO_SAMPLES)
            @test table_files(second) == table_files(local_copy)
        end
    end
end

@testset "sync! refuses a pinned copy" begin
    with_samples_copy() do local_copy
        touch(joinpath(local_copy.path, "pin"))
        err = @test_throws PinnedCopyError "the call was `sync!`" sync!(local_copy)
        @test (err.value.path, err.value.slot) == (local_copy.path, 1)
        rm(joinpath(local_copy.path, "pin"))
        @test sync!(local_copy).applied == 0
    end
end

@testset "sync! refuses a closed copy" begin
    with_chain_copy() do local_copy
        close(local_copy)
        @test_throws ArgumentError "is closed" sync!(local_copy)
    end
end

@testset "sync! refuses a copy that was opened over no Chain" begin
    mktempdir() do dir
        with_copy(:not_a_chain, dir) do local_copy
            not_a_chain = "sync!: the local copy at $(local_copy.path) was opened over"
            @test_throws ArgumentError not_a_chain sync!(local_copy)
        end
    end
end

@testset "sync! reports a rewritten chain when the head's slot holds another record" begin
    with_samples_copy() do local_copy
        chain = local_copy.chain
        applied = head(local_copy).transaction_hash
        good = chain.store.objects[slot_key(1)]
        other = rewritten_record(local_copy, 1)
        plant!(chain.store, slot_key(1), other)
        err = @test_throws RewrittenChainError OTHER_HEAD sync!(local_copy)
        e = err.value
        @test (e.path, e.bucket, e.prefix) == (local_copy.path, "bkt", "p")
        @test (e.chain_id, e.slot) == (bound_chain_id(local_copy), 1)
        @test (e.expected, e.found) == (applied, Ops.transaction_hash(other))
        # The store's bytes failed the check, so they are not cached.
        @test read(record_file(chain, 1)) == good
        # The copy stays readable, and nothing heals the chain.
        @test head(local_copy).slot == 1
        @test isequal(sample_rows(local_copy), TWO_SAMPLES)
        @test_throws RewrittenChainError OTHER_HEAD sync!(local_copy)
    end
end

@testset "sync! reports a rewritten chain when the head's slot holds no record" begin
    with_samples_copy() do local_copy
        plant!(local_copy.chain.store, slot_key(1), b"not a record")
        err = @test_throws RewrittenChainError OTHER_HEAD sync!(local_copy)
        @test err.value.found == Ops.transaction_hash(b"not a record")
    end
end

@testset "sync! reports a rewritten chain when the head's slot is absent" begin
    with_samples_copy() do local_copy
        store = local_copy.chain.store
        good = store.objects[slot_key(1)]
        delete!(store.objects, slot_key(1))
        err = @test_throws RewrittenChainError ABSENT_HEAD sync!(local_copy)
        @test err.value.slot == 1
        @test err.value.expected == head(local_copy).transaction_hash
        @test err.value.found === nothing
        @test isequal(sample_rows(local_copy), TWO_SAMPLES)
        plant!(store, slot_key(1), good)
        @test sync!(local_copy).applied == 0
    end
end

@testset "sync! reports a rewritten chain when the prefix was emptied" begin
    with_samples_copy() do local_copy
        empty_store!(local_copy.chain.store)
        err = @test_throws RewrittenChainError ABSENT_HEAD sync!(local_copy)
        @test (err.value.slot, err.value.found) == (1, nothing)
    end
end

@testset "sync! refuses a record that names another parent" begin
    with_samples_copy() do local_copy
        chain = local_copy.chain
        applied = head(local_copy).transaction_hash
        plant!(chain.store, slot_key(2), forged_record(local_copy, 2, fill(0xaa, 32)))
        other_parent = "the record names another parent than the record of slot 1"
        err = @test_throws RewrittenChainError other_parent sync!(local_copy)
        e = err.value
        @test (e.path, e.slot) == (local_copy.path, 2)
        @test e.chain_id == bound_chain_id(local_copy)
        @test (e.expected, e.found) == (applied, fill(0xaa, 32))
        @test head(local_copy).slot == 1
        @test !isfile(record_file(chain, 2))
    end
end

@testset "sync! refuses a record of another chain in the prefix" begin
    with_samples_copy() do local_copy
        chain = local_copy.chain
        parent = head(local_copy).transaction_hash.bytes
        foreign = forged_record(local_copy, 2, parent; chain_id = fill(0x11, 16))
        plant!(chain.store, slot_key(2), foreign)
        other_chain = "the record carries chain id " *
            "$(ChainTables.chain_id_string(fill(0x11, 16))): a record of another chain"
        err = @test_throws MalformedRecordError other_chain sync!(local_copy)
        @test (err.value.chain_id, err.value.slot) == (bound_chain_id(local_copy), 2)
        @test head(local_copy).slot == 1
        @test !isfile(record_file(chain, 2))
    end
end

@testset "sync! reports a slot that vanished between the probe and the fetch" begin
    with_samples_copy() do local_copy
        store = local_copy.chain.store
        parent = head(local_copy).transaction_hash.bytes
        plant!(store, slot_key(2), forged_record(local_copy, 2, parent))
        vanish = () -> delete!(store.objects, slot_key(2))
        store.fault = FaultAt(:fetch_object, slot_key(2), :before, vanish)
        vanished = "the slot was there when head discovery probed it and is absent now"
        err = @test_throws RewrittenChainError vanished sync!(local_copy)
        @test (err.value.slot, err.value.found) == (2, nothing)
    end
end

@testset "sync! refuses a malformed record and stays at its head" begin
    with_samples_copy() do local_copy
        store = local_copy.chain.store
        parent = head(local_copy).transaction_hash.bytes
        float_key = [Insert("samples", [Any[13.0, "x", 1.0]])]
        malformed = forged_record(local_copy, 2, parent; ops = float_key)
        put_object_if_absent(store, slot_key(2), malformed)
        wrong_cell = "op 1 (insert on \"samples\"): column \"id\" is int64, got a value " *
            "of type Float64"
        err = @test_throws MalformedRecordError wrong_cell sync!(local_copy)
        e = err.value
        @test (e.chain_id, e.slot, e.op) == (bound_chain_id(local_copy), 2, 1)
        @test head(local_copy).slot == 1
        @test isequal(sample_rows(local_copy), TWO_SAMPLES)
    end
end

@testset "sync! reports the wrong chain for a copy that is bound to another" begin
    with_samples_copy() do local_copy
        dir = dirname(local_copy.path)
        store = local_copy.chain.store
        other = chain_in(dir; store, prefix = "q", cache = "cache_q")
        created = create_chain(other)
        with_copy_beside(local_copy, "q"; chain = other) do writer
            sync!(writer)
            commit_ops!(seed_samples!, writer)
        end
        # With a cold cache `open` cannot tell, and the first `sync!` does.
        cold = chain_in(dir; store, prefix = "q", cache = "cache_cold")
        with_copy(cold, local_copy.path) do wrong
            err = @test_throws WrongChainError "names the other chain" sync!(wrong)
            e = err.value
            @test (e.path, e.bucket, e.prefix) == (local_copy.path, "bkt", "q")
            @test (e.bound, e.opened) == (bound_chain_id(local_copy), created.chain_id)
            @test head(wrong).slot == 1
        end
        # With the genesis of `q` in the cache, `open` itself refuses.
        @test_throws WrongChainError "bound to another chain" ChainTables.open(
            other, local_copy.path
        )
        # A damaged cached genesis tells `open` nothing: the check is left to `sync!`.
        genesis = ChainTables.record_path(other.cache, store, "bkt", "q/000000000000")
        write(genesis, b"not a record")
        with_copy(other, local_copy.path) do wrong
            @test head(wrong).slot == 1
        end
    end
end

@testset "sync! reports the wrong chain when the prefix holds another chain" begin
    with_samples_copy() do local_copy
        dir = dirname(local_copy.path)
        store = local_copy.chain.store
        empty_store!(store)
        other = chain_in(dir; store, cache = "cache_other")
        created = create_chain(other)
        with_copy_beside(local_copy, "writer"; chain = other) do writer
            sync!(writer)
            commit_ops!(seed_samples!, writer)
            held = Dict(store.objects)
            err = @test_throws WrongChainError "names the other chain" sync!(local_copy)
            @test (err.value.bound, err.value.opened) ==
                (bound_chain_id(local_copy), created.chain_id)
            @test store.objects == held
        end
    end
end

@testset "sync! stays at its last checkpoint when a fetch fails, and resumes" begin
    with_samples_copy() do local_copy
        dir = dirname(local_copy.path)
        store = local_copy.chain.store
        foreach(id -> commit_sample!(local_copy, id), 3:6)
        cold = chain_in(dir; store, cache = "cache_cold")
        failure = TransportError(;
            method = "GET", url = slot_key(4), status = nothing, detail = "timeout"
        )
        time_out = () -> throw(failure)
        store.fault = FaultAt(:fetch_object, slot_key(4), :before, time_out)
        path = joinpath(dir, "failed")
        reached = with_copy(cold, path) do failed
            @test_throws TransportError "timeout" sync!(failed)
            head(failed)
        end
        @test 0 <= reached.slot < 4
        store.fault = no_fault
        # The checkpoint is what is on disk.
        with_copy(cold, path) do failed
            @test head(failed) == reached
            @test sync!(failed).applied == 5 - reached.slot
            @test head(failed) == head(local_copy)
            @test isequal(sample_rows(failed), sample_rows(local_copy))
        end
    end
end

@testset "sync! fetches one slot at a time with read_ahead = 1" begin
    with_samples_copy() do local_copy
        dir = dirname(local_copy.path)
        store = local_copy.chain.store
        foreach(id -> commit_sample!(local_copy, id), 3:6)
        one_ahead = chain_in(dir; store, cache = "cache_one", read_ahead = 1)
        with_copy(one_ahead, joinpath(dir, "one_ahead")) do second
            n = length(store.calls)
            @test sync!(second).slot == 5
            @test fetched_after(store, n) == slot_key.(0:5)
            @test head(second) == head(local_copy)
        end
    end
end
