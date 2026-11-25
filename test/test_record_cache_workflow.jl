using Test
using ChainTables: ChainTables, ChainNotFoundError, MalformedRecordError, Ops,
    RewrittenChainError,
    TransportError, as_of, cache_namespace, create_chain, head, slot_at, sync!
using ChainTables.Ops: Client, Record
using ChainTables.Testing: InMemoryObjectStore

include("fixtures/chain_copies.jl")
include("fixtures/object_stores.jl")
include("fixtures/forged_records.jl")
include("fixtures/forked_chains.jl")

const DEBUG = Base.CoreLogging.Debug
# The record that `sync!` leaves for each cached file that it replaces.
const REPLACED = (:debug, "the record cache held other bytes than the store")


# A local copy at slot 3 of a chain whose four records are all in the record cache.
function with_four_slots(f)
    with_samples_copy() do local_copy
        commit_sample!(local_copy, 3)
        commit_sample!(local_copy, 4)
        f(local_copy)
    end
    return nothing
end

# The record of `slot` again with another clock reading: it decodes, is of this chain
# and names the right parent, and its bytes are not the chain's.
function twin_record(chain, slot)
    record = Ops.decode_record(chain.store.objects[slot_key(slot)]; slot)
    client = Client(nothing, nothing, record.client.lib, record.client.julia, 0)
    twin = Record(
        record.chain_id, slot, record.prev_hash, record.state_fingerprint, client,
        record.comment, record.ops,
    )
    return Ops.encode_record(twin)
end

# A fresh local copy beside `local_copy`, synced, with what the sync fetched.
function synced_beside(local_copy, name)
    store = local_copy.chain.store
    return with_copy_beside(local_copy, name) do fresh
        n = length(store.calls)
        sync!(fresh)
        (; head = head(fresh), fetched = sort(fetched_after(store, n)))
    end
end

@testset "two stores under one bucket name and key have two cache files" begin
    mktempdir() do dir
        a = chain_in(dir)
        b = chain_in(dir)
        create_chain(a)
        create_chain(b)
        @test record_file(a, 0) != record_file(b, 0)
        @test read(record_file(a, 0)) == a.store.objects[slot_key(0)]
        @test read(record_file(b, 0)) == b.store.objects[slot_key(0)]
    end
end

@testset "a record is cached under the store's namespace, the bucket and the key" begin
    mktempdir() do dir
        chain = chain_in(dir; prefix = "exp/run-7")
        create_chain(chain)
        namespace = cache_namespace(chain.store)
        cached = joinpath(dir, "cache", namespace, "bkt", "exp", "run-7", "000000000000")
        @test isfile(cached)
        @test readdir(dirname(cached)) == ["000000000000"]
    end
end

@testset "a slot that is absent leaves nothing in the record cache" begin
    mktempdir() do dir
        chain = chain_in(dir)
        with_copy(chain, joinpath(dir, "copy")) do local_copy
            @test_throws ChainNotFoundError "the call was `sync!`" sync!(local_copy)
        end
        @test !ispath(joinpath(dir, "cache", cache_namespace(chain.store), "bkt"))
    end
end

@testset "a fetch that fails caches nothing" begin
    with_four_slots() do local_copy
        store = local_copy.chain.store
        cold = chain_in(dirname(local_copy.path); store, cache = "cache_cold")
        down = () -> throw(TransportError("down"))
        store.fault = FaultAt(:fetch_object, slot_key(1), :before, down)
        with_copy_beside(local_copy, "fresh"; chain = cold) do fresh
            @test_throws TransportError "TransportError: down" sync!(fresh)
        end
        @test !isfile(record_file(cold, 1))
    end
end

@testset "a write that stops part-way caches neither the record nor a temporary file" begin
    with_four_slots() do local_copy
        dir = dirname(local_copy.path)
        cut = chain_in(dir; store = CutStore(local_copy.chain.store, slot_key(1)))
        with_copy_beside(local_copy, "fresh"; chain = cut) do fresh
            @test_throws ErrorException "write interrupted at byte 11" sync!(fresh)
        end
        cached = readdir(dirname(record_file(cut, 1)))
        @test "000000000001" ∉ cached
        @test isempty(filter(endswith(".tmp"), cached))
    end
end

@testset "a warm cache serves every record but the first and the last of a read" begin
    with_four_slots() do local_copy
        synced = @test_logs min_level = DEBUG synced_beside(local_copy, "warm")
        @test synced.fetched == slot_key.([0, 3])
        @test synced.head == head(local_copy)
    end
end

@testset "a cached record with the store's bytes is not written again" begin
    with_four_slots() do local_copy
        cached = record_file(local_copy.chain, 3)
        written = mtime(cached)
        @test_logs min_level = DEBUG sync!(local_copy)
        @test mtime(cached) == written
    end
end

@testset "an empty cached genesis is replaced" begin
    with_four_slots() do local_copy
        chain = local_copy.chain
        write(record_file(chain, 0), UInt8[])
        synced = @test_logs REPLACED min_level = DEBUG synced_beside(local_copy, "fresh")
        @test synced.head == head(local_copy)
        @test read(record_file(chain, 0)) == chain.store.objects[slot_key(0)]
    end
end

@testset "cached bytes that do not decode are fetched again" begin
    with_four_slots() do local_copy
        chain = local_copy.chain
        write(record_file(chain, 1), b"not a record")
        synced = @test_logs REPLACED min_level = DEBUG synced_beside(local_copy, "fresh")
        @test synced.fetched == slot_key.([0, 1, 3])
        @test synced.head == head(local_copy)
        @test read(record_file(chain, 1)) == chain.store.objects[slot_key(1)]
    end
end

@testset "a cached record that the slot above does not name is asked of the store" begin
    with_four_slots() do local_copy
        chain = local_copy.chain
        write(record_file(chain, 1), twin_record(chain, 1))
        # Slot 2 does not name the twin's hash, so slot 2 and then slot 1 are fetched
        # before anything of either is applied.
        synced = @test_logs REPLACED min_level = DEBUG synced_beside(local_copy, "fresh")
        @test synced.fetched == slot_key.(0:3)
        @test synced.head == head(local_copy)
        @test read(record_file(chain, 1)) == chain.store.objects[slot_key(1)]
    end
end

@testset "a cached record at the top of a read comes from the store" begin
    with_four_slots() do local_copy
        chain = local_copy.chain
        write(record_file(chain, 1), twin_record(chain, 1))
        pinned = @test_logs REPLACED min_level = DEBUG as_of(chain, 1)
        @test head(pinned).transaction_hash == stored_hash(chain.store, 1)
        close(pinned)
    end
end

@testset "a damaged cached record of the head's own slot is replaced" begin
    with_four_slots() do local_copy
        cached = record_file(local_copy.chain, 3)
        write(cached, b"")
        synced = @test_logs REPLACED min_level = DEBUG sync!(local_copy)
        @test synced.applied == 0
        write(cached, b"")
        committed = @test_logs REPLACED min_level = DEBUG commit_sample!(local_copy, 5)
        @test committed.slot == 4
    end
end

@testset "a scan of the chain replaces a damaged cached record" begin
    with_four_slots() do local_copy
        chain = local_copy.chain
        write(record_file(chain, 2), twin_record(chain, 2))
        top = @test_logs REPLACED min_level = DEBUG slot_at(chain, typemax(Int64))
        @test top == 3
        @test read(record_file(chain, 2)) == chain.store.objects[slot_key(2)]
    end
end

@testset "a scan of a chain that is broken in the store throws" begin
    with_four_slots() do local_copy
        chain = local_copy.chain
        applied = head(local_copy).transaction_hash
        plant!(chain.store, slot_key(4), forged_record(local_copy, 4, fill(0xaa, 32)))
        other_parent = "the record names another parent than the record of slot 3"
        err = @test_throws RewrittenChainError other_parent slot_at(chain, typemax(Int64))
        e = err.value
        @test (e.path, e.bucket, e.prefix, e.slot) == (nothing, "bkt", "p", 4)
        @test (e.expected, e.found) == (applied, fill(0xaa, 32))
    end
end

@testset "a damaged cached record over a store that is bad there too stays as it was" begin
    with_four_slots() do local_copy
        chain = local_copy.chain
        good = chain.store.objects[slot_key(2)]
        write(record_file(chain, 2), b"damaged")
        plant!(chain.store, slot_key(2), b"not a record either")
        with_copy_beside(local_copy, "fresh") do fresh
            # `replay!` is internal. It is called for its clock: with a checkpoint after
            # every record, the head says which records were applied.
            clock = checkpoint_every_record()
            not_cbor = "not deterministic CBOR"
            err = @test_logs min_level = DEBUG (
                @test_throws MalformedRecordError not_cbor ChainTables.replay!(
                    fresh, 0, 3; clock
                )
            )
            @test err.value.slot == 2
            # The cached file is evidence. Slot 1 came from the cache and was applied:
            # the store was asked for it and agreed.
            @test read(record_file(chain, 2)) == b"damaged"
            @test head(fresh).slot == 1
            plant!(chain.store, slot_key(2), good)
            synced = @test_logs REPLACED min_level = DEBUG sync!(fresh)
            @test synced.slot == 3
            @test read(record_file(chain, 2)) == good
        end
    end
end

@testset "the cached records of an earlier chain under the prefix are all replaced" begin
    with_four_slots() do local_copy
        dir = dirname(local_copy.path)
        store = local_copy.chain.store
        empty_store!(store)
        other = chain_in(dir; store, cache = "cache_other")
        create_chain(other)
        written = with_copy_beside(local_copy, "writer"; chain = other) do writer
            sync!(writer)
            commit_ops!(seed_samples!, writer)
            commit_sample!(writer, 10)
            (; head = head(writer), rows = sample_rows(writer))
        end
        # The reader's cache holds slots 0 to 3 of the earlier chain.
        with_copy_beside(local_copy, "reader") do reader
            synced = @test_logs REPLACED REPLACED REPLACED min_level = DEBUG sync!(reader)
            @test synced.slot == 2
            @test head(reader) == written.head
            @test isequal(sample_rows(reader), written.rows)
        end
    end
end
