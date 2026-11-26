using Test
using ChainTables: ChainTables, FingerprintMismatchError, LostRaceError, Ops,
    PinnedCopyError, RewrittenChainError, StaleHeadError, StateFingerprint,
    TransactionHash, TransportError, WriteBuilder, WriteBuilderError, WrongChainError,
    column!, commit!, create_chain, create_table!, delete_rows!, drop_table!, head,
    insert_rows!, primary_key!, sync!, tables, update_rows!, write_builder

include("fixtures/chain_copies.jl")
include("fixtures/object_stores.jl")
include("fixtures/forged_records.jl")

const TWO_SAMPLES = [(1, "a", 1.5), (2, "b", missing)]
const REFUSED_OPS = [
    (
        name = "an insert on a present key",
        build = w -> insert_rows!(w, :samples, [(id = 2, label = "dup", mass = 0.0)]),
        detail = "commit!(w): op 1 (insert on \"samples\"): insert names a key that " *
            "is present: (2,)",
    ),
    (
        name = "an update on an absent key, after an op that passes",
        build = w -> (
            delete_rows!(w, :samples, [(id = 1,)]);
            update_rows!(w, :samples, [(id = 9, mass = 1.0)])
        ),
        detail = "commit!(w): op 2 (update on \"samples\"): update names a key that " *
            "is absent: (9,)",
    ),
    (
        name = "delete rows at an absent key",
        build = w -> delete_rows!(w, :samples, [(id = 9,)]),
        detail = "commit!(w): op 1 (delete on \"samples\"): delete rows names a key that " *
            "is absent: (9,)",
    ),
]

head_files(local_copy) = sort(readdir(joinpath(local_copy.path, "heads")))
table_files(local_copy) = sort(readdir(joinpath(local_copy.path, "tables")))

# What a refused commit must leave as it was.
on_disk(local_copy) = (head_files(local_copy), table_files(local_copy), head(local_copy))

# The rival's record lands, once, while another put is on its way.
function land_rival!(store, rival)
    store.fault = no_fault
    commit!(rival)
    return nothing
end

function delete_one(local_copy)
    w = write_builder(local_copy)
    delete_rows!(w, :samples, [(id = 1,)])
    return w
end

@testset "write_builder gives a builder at the head of the copy" begin
    with_samples_copy() do local_copy
        w = @inferred write_builder(local_copy)
        @test w isa WriteBuilder
        @test isempty(w.ops)
    end
end

@testset "write_builder refuses a copy with no head" begin
    mktempdir() do dir
        with_copy(chain_in(dir), joinpath(dir, "fresh")) do fresh
            no_head = "has no head yet; sync!(copy) binds it"
            @test_throws ArgumentError no_head write_builder(fresh)
        end
    end
end

@testset "write_builder refuses a pinned copy" begin
    with_samples_copy() do local_copy
        touch(joinpath(local_copy.path, "pin"))
        pinned = "the call was `write_builder`"
        err = @test_throws PinnedCopyError pinned write_builder(local_copy)
        @test (err.value.path, err.value.slot) == (local_copy.path, 1)
    end
end

@testset "commit! writes one record at the slot above the head" begin
    with_chain_copy() do local_copy
        chain = local_copy.chain
        genesis = head(local_copy).transaction_hash
        w = write_builder(local_copy)
        seed_samples!(w)
        committed = @inferred commit!(w; comment = "first samples")
        @test committed.slot == 1
        @test committed.transaction_hash isa TransactionHash
        @test committed.state_fingerprint isa StateFingerprint
        @test head(local_copy) == committed
        @test head_files(local_copy) == ["000000000001"]
        @test length(table_files(local_copy)) == 1
        @test isequal(sample_rows(local_copy), TWO_SAMPLES)
        bytes = chain.store.objects[slot_key(1)]
        @test committed.transaction_hash == Ops.transaction_hash(bytes)
        record = Ops.decode_record(bytes; slot = 1)
        @test record.prev_hash == genesis
        @test record.comment == "first samples"
        @test committed.state_fingerprint == record.state_fingerprint
        @test length(record.ops) == 2
        @test ChainTables.chain_id_string(record.chain_id) == bound_chain_id(local_copy)
    end
end

@testset "commit! puts its record once, reads nothing back and caches it" begin
    with_samples_copy() do local_copy
        chain = local_copy.chain
        @test n_requests(chain.store, :put_object_if_absent, slot_key(1)) == 1
        @test n_requests(chain.store, :fetch_object, slot_key(1)) == 0
        @test read(record_file(chain, 1)) == chain.store.objects[slot_key(1)]
    end
end

@testset "commit! spends its builder" begin
    with_samples_copy() do local_copy
        w = delete_one(local_copy)
        commit!(w)
        spent = "commit!(w): this builder is spent; a builder is used once"
        @test_throws WriteBuilderError spent commit!(w)
    end
end

@testset "commit! refuses an op that the tables do not allow, and writes nothing" begin
    @testset "$(case.name)" for case in REFUSED_OPS
        with_samples_copy() do local_copy
            store = local_copy.chain.store
            before = on_disk(local_copy)
            w = write_builder(local_copy)
            case.build(w)
            err = @test_throws WriteBuilderError case.detail commit!(w)
            @test err.value.detail == case.detail
            @test on_disk(local_copy) == before
            @test isequal(sample_rows(local_copy), TWO_SAMPLES)
            # The pre-check and the preflight ran, and no put was made.
            @test n_requests(store, :stat_object, slot_key(2)) == 1
            @test n_requests(store, :put_object_if_absent, slot_key(2)) == 0
        end
    end
end

@testset "commit! refuses an empty builder" begin
    with_samples_copy() do local_copy
        no_ops = "commit!(w): the builder has no ops; a record after genesis carries at " *
            "least one, and genesis is create_chain's. Add ops, or do not commit."
        err = @test_throws WriteBuilderError no_ops commit!(write_builder(local_copy))
        @test err.value.detail == no_ops
    end
end

@testset "commit! refuses a comment that is not text" begin
    with_samples_copy() do local_copy
        not_text = "commit!(w): comment is a Int64, not text"
        @test_throws WriteBuilderError not_text commit!(delete_one(local_copy); comment = 1)
    end
end

@testset "commit! refuses a comment with U+0000, and leaves the copy as it was" begin
    with_samples_copy() do local_copy
        before = on_disk(local_copy)
        w = delete_one(local_copy)
        nul = "commit!(w): comment contains U+0000"
        @test_throws WriteBuilderError nul commit!(w; comment = "a\0b")
        @test on_disk(local_copy) == before
        @test isequal(sample_rows(local_copy), TWO_SAMPLES)
    end
end

@testset "commit! loads a table at the first op that names it" begin
    with_samples_copy() do local_copy
        # A copy that is opened again has no table loaded.
        close(local_copy)
        with_copy(local_copy.chain, local_copy.path) do reopened
            w = write_builder(reopened)
            create_table!(w, :tags) do t
                column!(t, :k, Vector{UInt8})
                primary_key!(t, :k)
            end
            insert_rows!(w, :tags, [(k = UInt8[1],)])
            @test isempty(reopened.loaded)
            insert_rows!(w, :samples, [(id = 3, label = "c", mass = 3.0)])
            @test reopened.loaded == Set(["samples"])
            @test commit!(w).slot == 2
            @test tables(reopened) == ["samples", "tags"]
            @test isequal(sample_rows(reopened), [TWO_SAMPLES..., (3, "c", 3.0)])
        end
    end
end

@testset "commit! drops a table that was never loaded and creates it again" begin
    with_tables_copy() do local_copy
        close(local_copy)
        with_copy(local_copy.chain, local_copy.path) do reopened
            w = write_builder(reopened)
            drop_table!(w, :blobs)
            @test isempty(reopened.loaded)
            create_table!(w, :blobs) do t
                column!(t, :n, Int64)
                primary_key!(t, :n)
            end
            insert_rows!(w, :blobs, [(n = 7,)])
            @test commit!(w).slot == 2
            @test ChainTables.table(reopened, :blobs).columns.n == [7]
        end
    end
end

@testset "commit! finds the copy behind the chain before anything is applied" begin
    with_samples_copy() do local_copy
        store = local_copy.chain.store
        with_copy_beside(local_copy, "two") do second
            sync!(second)
            commit_ops!(w -> update_rows!(w, :samples, [(id = 2, mass = 2.5)]), second)
        end
        before = (on_disk(local_copy), length(store.objects))
        w = delete_one(local_copy)
        behind = "Run `sync!(copy)`, recompute the row set"
        err = @test_throws StaleHeadError behind commit!(w)
        e = err.value
        @test (e.path, e.chain_id) == (local_copy.path, bound_chain_id(local_copy))
        @test (e.slot, e.chain_slot, e.reason) == (1, 2, :copy_behind_chain)
        @test (on_disk(local_copy), length(store.objects)) == before
        @test n_requests(store, :put_object_if_absent, slot_key(2)) == 1
        @test isequal(sample_rows(local_copy), TWO_SAMPLES)
        @test_throws WriteBuilderError "this builder is spent" commit!(w)
        @test sync!(local_copy).applied == 1
        @test commit!(delete_one(local_copy)).slot == 3
        @test isequal(sample_rows(local_copy), [(2, "b", 2.5)])
    end
end

@testset "commit! finds a builder behind its copy without asking the store" begin
    with_samples_copy() do local_copy
        store = local_copy.chain.store
        w = delete_one(local_copy)
        with_copy_beside(local_copy, "two") do second
            sync!(second)
            commit_sample!(second, 3)
        end
        @test sync!(local_copy).slot == 2
        n = length(store.calls)
        err = @test_throws StaleHeadError "A `sync!` moved the local copy" commit!(w)
        e = err.value
        @test (e.path, e.chain_id) == (local_copy.path, bound_chain_id(local_copy))
        @test (e.slot, e.chain_slot, e.reason) == (1, 2, :builder_behind_copy)
        @test length(store.calls) == n
    end
end

@testset "commit! loses the race to a record that lands during its put" begin
    with_samples_copy() do first
        store = first.chain.store
        with_copy_beside(first, "two") do second
            sync!(second)
            rival = write_builder(first)
            insert_rows!(rival, :samples, [(id = 3, label = "from first", mass = missing)])
            w = write_builder(second)
            insert_rows!(w, :samples, [(id = 4, label = "from second", mass = missing)])
            # The preflight of `second` passes, and then the rival's record lands first.
            land = () -> land_rival!(store, rival)
            store.fault = FaultAt(:put_object_if_absent, nothing, :before, land)
            before = on_disk(second)
            lost = "The write is never retried. Run `sync!(copy)`"
            err = @test_throws LostRaceError lost commit!(w)
            winner = head(first).transaction_hash
            e = err.value
            @test (e.bucket, e.prefix, e.chain_id) == ("bkt", "p", bound_chain_id(first))
            @test (e.slot, e.transaction_hash, e.reason) == (2, winner, :slot_taken)
            # One put each. The read-back asked the store, though the rival's commit
            # had cached its record in the same record cache.
            @test n_requests(store, :put_object_if_absent, slot_key(2)) == 2
            @test n_requests(store, :fetch_object, slot_key(2)) == 1
            @test on_disk(second) == before
            @test winner == Ops.transaction_hash(store.objects[slot_key(2)])
            @test_throws WriteBuilderError "this builder is spent" commit!(w)
            # The winner is the last record of the next sync, so nothing vouches for
            # the cached copy, and it is asked of the store once more.
            synced = sync!(second)
            @test (synced.applied, synced.slot, synced.transaction_hash) == (1, 2, winner)
            @test n_requests(store, :fetch_object, slot_key(2)) == 2
            @test isequal(sample_rows(second), [TWO_SAMPLES..., (3, "from first", missing)])
        end
    end
end

@testset "commit! succeeds when only the acknowledgement of its put is lost" begin
    with_samples_copy() do local_copy
        chain = local_copy.chain
        reset = TransportError("connection reset by peer")
        chain.store.fault =
            FaultAt(:put_object_if_absent, nothing, :after, () -> throw(reset))
        committed = commit_sample!(local_copy, 3)
        @test committed.slot == 2
        @test head(local_copy).slot == 2
        # The put is not issued again: the read-back found the record.
        @test n_requests(chain.store, :put_object_if_absent, slot_key(2)) == 1
        @test n_requests(chain.store, :fetch_object, slot_key(2)) == 1
        @test committed.transaction_hash == stored_hash(chain.store, 2)
        @test isfile(record_file(chain, 2))
    end
end

@testset "commit! refuses to build on a head that its own record contradicts" begin
    with_samples_copy() do local_copy
        chain = local_copy.chain
        held = head(local_copy)
        record = Ops.decode_record(chain.store.objects[slot_key(1)]; slot = 1)
        lie = forged_record(
            local_copy, 1, record.prev_hash; fingerprint = fill(0xee, 32), record.ops
        )
        plant!(chain.store, slot_key(1), lie)
        # The head file names the lying record: only its fingerprint contradicts it.
        head_file = local_copy.head
        local_copy.head = ChainTables.Head(
            head_file.chain_id, head_file.format_version, 1, Ops.transaction_hash(lie),
            head_file.state_fingerprint, head_file.tables, head_file.written_at_ms,
            head_file.written_by,
        )
        w = delete_one(local_copy)
        diverged = "the local copy diverged from the chain after its head was applied"
        err = @test_throws FingerprintMismatchError diverged commit!(w)
        e = err.value
        @test (e.path, e.chain_id, e.slot) == (local_copy.path, head_file.chain_id, 1)
        @test (e.expected, e.computed) == (fill(0xee, 32), held.state_fingerprint)
        @test e.record_client == (; lib = "L", julia = "J")
        @test e.this_client.julia == string(VERSION)
        @test !haskey(chain.store.objects, slot_key(2))
    end
end

@testset "commit! refuses a pinned copy, after it has spent the builder" begin
    with_samples_copy() do local_copy
        w = delete_one(local_copy)
        touch(joinpath(local_copy.path, "pin"))
        err = @test_throws PinnedCopyError "the call was `commit!`" commit!(w)
        @test (err.value.path, err.value.slot) == (local_copy.path, 1)
        rm(joinpath(local_copy.path, "pin"))
        @test_throws WriteBuilderError "this builder is spent" commit!(w)
        @test !haskey(local_copy.chain.store.objects, slot_key(2))
    end
end

@testset "commit! refuses a head that the store contradicts" begin
    with_samples_copy() do local_copy
        store = local_copy.chain.store
        w = delete_one(local_copy)
        empty_store!(store)
        absent = "the slot of the local copy's head is absent"
        @test_throws RewrittenChainError absent commit!(w)
        @test isempty(store.objects)
    end
end

@testset "commit! refuses a copy whose prefix holds another chain" begin
    with_samples_copy() do local_copy
        store = local_copy.chain.store
        w = delete_one(local_copy)
        empty_store!(store)
        other = chain_in(dirname(local_copy.path); store, cache = "cache_other")
        create_chain(other)
        with_copy_beside(local_copy, "writer"; chain = other) do writer
            sync!(writer)
            commit_ops!(seed_samples!, writer)
            held = Dict(store.objects)
            @test_throws WrongChainError "names the other chain" commit!(w)
            @test store.objects == held
            # The other chain lives on.
            @test commit_sample!(writer, 10).slot == 2
        end
    end
end
