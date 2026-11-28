using Test
using ChainTables: ChainTables, DivergenceError, RewrittenChainError, as_of, head,
    is_pinned, repair!, table, verify

include("fixtures/chain_copies.jl")
include("fixtures/object_stores.jl")
include("fixtures/damaged_copies.jl")

const NOTHING_TO_DO = (; slot = 2, files_rewritten = 0, attachments_repaired = 0)
const ONE_FILE = (; slot = 2, files_rewritten = 1, attachments_repaired = 0)
const REPLACED = (:debug, "the record cache held other bytes than the store")
const DEBUG = Base.CoreLogging.Debug

# A local copy at slot 2: the table `samples`, then one more row.
function with_two_slots(f)
    with_samples_copy() do local_copy
        commit_sample!(local_copy, 3)
        f(local_copy)
    end
    return nothing
end

table_files(local_copy) = sort(readdir(joinpath(local_copy.path, "tables")))

@testset "repair! writes nothing for a sound copy" begin
    with_two_slots() do local_copy
        files = table_files(local_copy)
        @test @inferred(repair!(local_copy)) == NOTHING_TO_DO
        @test table_files(local_copy) == files
    end
end

@testset "repair! writes a damaged table file again" begin
    with_two_slots() do local_copy
        damaged = damage_table_file!(local_copy, "samples")
        head_bytes = read(head_file_path(local_copy))
        files = table_files(local_copy)
        @test repair!(local_copy) == ONE_FILE
        @test read(damaged.file) == damaged.good
        # The head file stays as it is, and no temporary file is left.
        @test read(head_file_path(local_copy)) == head_bytes
        @test table_files(local_copy) == files
        @test verify(local_copy; full = true) === nothing
        @test table(local_copy, :samples)[3].mass == 3.0
    end
end

@testset "repair! leaves a pinned copy pinned" begin
    with_two_slots() do local_copy
        path = joinpath(dirname(local_copy.path), "pinned")
        pinned = as_of(local_copy.chain, 2; path)
        damage_table_file!(pinned, "samples")
        @test repair!(pinned) == ONE_FILE
        @test is_pinned(pinned)
        close(pinned)
    end
end

@testset "repair! writes a missing table file once for the two tables that share it" begin
    with_chain_copy() do local_copy
        commit_ops!(seed_twin_tables!, local_copy)
        file = table_file(local_copy, "tags")
        rm(file)
        @test repair!(local_copy).files_rewritten == 1
        @test isfile(file)
        @test verify(local_copy) === nothing
    end
end

@testset "repair! writes two damaged table files" begin
    with_tables_copy() do local_copy
        damage_table_file!(local_copy, "samples")
        damage_table_file!(local_copy, "pairs")
        @test repair!(local_copy).files_rewritten == 2
        @test verify(local_copy) === nothing
    end
end

@testset "repair! fetches a record that the record cache lacks" begin
    with_two_slots() do local_copy
        store = local_copy.chain.store
        rm(record_file(local_copy.chain, 1))
        n = length(store.calls)
        @test repair!(local_copy) == NOTHING_TO_DO
        @test store.calls[(n + 1):end] == [(:fetch_object, slot_key(1))]
        @test read(record_file(local_copy.chain, 1)) == store.objects[slot_key(1)]
    end
end

@testset "repair! replaces a cached record with other bytes" begin
    with_two_slots() do local_copy
        store = local_copy.chain.store
        write(record_file(local_copy.chain, 1), b"damaged")
        n = length(store.calls)
        @test (@test_logs REPLACED min_level = DEBUG repair!(local_copy)) == NOTHING_TO_DO
        @test store.calls[(n + 1):end] == [(:fetch_object, slot_key(1))]
        @test read(record_file(local_copy.chain, 1)) == store.objects[slot_key(1)]
    end
end

const REWRITTEN_CASES = [
    (slot = 1, detail = "the store does not hold the record that the slot above names"),
    (
        slot = 2,
        detail = "the store does not hold the record that the local copy's head names",
    ),
]

@testset "repair! throws RewrittenChainError for slot $(case.slot)" for case in
    REWRITTEN_CASES
    with_two_slots() do local_copy
        chain = local_copy.chain
        named = stored_hash(chain.store, case.slot)
        write(record_file(chain, case.slot), b"cached damage")
        plant!(chain.store, slot_key(case.slot), b"stored damage")
        damaged = damage_table_file!(local_copy, "samples")
        damaged_bytes = read(damaged.file)
        err = @test_throws RewrittenChainError case.detail repair!(local_copy)
        e = err.value
        @test (e.path, e.bucket, e.prefix, e.chain_id, e.slot) ==
            (local_copy.path, "bkt", "p", local_copy.head.chain_id, case.slot)
        @test e.expected == named
        @test e.found == ChainTables.Ops.transaction_hash(b"stored damage")
        # Nothing was written: the table file and the cached file stay as they were.
        @test read(damaged.file) == damaged_bytes
        @test read(record_file(chain, case.slot)) == b"cached damage"
    end
end

@testset "repair! throws DivergenceError when a replay does not give the head" begin
    with_tables_copy() do local_copy
        replayed = head(local_copy).state_fingerprint
        drop_tables_from_head!(local_copy, ("samples",))
        files = table_files(local_copy)
        err = @test_throws DivergenceError "does not give the head's state" repair!(
            local_copy
        )
        e = err.value
        @test (e.path, e.chain_id, e.slot) ==
            (local_copy.path, local_copy.head.chain_id, 1)
        @test e.expected == local_copy.head.state_fingerprint
        @test e.computed == replayed
        @test e.tables == ["blobs", "pairs"]
        @test table_files(local_copy) == files
    end
end

@testset "repair! throws ArgumentError for a copy with no head" begin
    with_chain_copy() do local_copy
        with_copy_beside(local_copy, "fresh") do fresh
            @test_throws ArgumentError "has no head yet" repair!(fresh)
        end
    end
end

@testset "repair! throws ArgumentError for a closed copy" begin
    with_samples_copy() do local_copy
        close(local_copy)
        @test_throws ArgumentError "is closed" repair!(local_copy)
    end
end
