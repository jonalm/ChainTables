using Test
using ChainTables: ChainTables, FingerprintMismatchError, Model, Ops, RecordCacheError,
    StateFingerprint, head, verify
using SHA: sha256

include("fixtures/chain_copies.jl")
include("fixtures/object_stores.jl")
include("fixtures/damaged_copies.jl")

# A local copy at slot 6: the table `samples`, then one row per record.
function with_six_slots(f)
    with_samples_copy() do local_copy
        foreach(id -> commit_sample!(local_copy, id), 3:7)
        f(local_copy)
    end
    return nothing
end

# The state fingerprint of the head's tables, with the file of `name` as it hashes now.
function fingerprint_with_file(local_copy, name)
    tables = [
        table => (table == name ? sha256(read(table_file(local_copy, name))) : hash)
            for (table, hash) in local_copy.head.tables
    ]
    return Model.state_fingerprint(tables)
end

@testset "verify returns nothing for a sound copy" begin
    with_samples_copy() do local_copy
        @test @inferred(verify(local_copy)) === nothing
        @test @inferred(verify(local_copy; full = true)) === nothing
    end
end

@testset "verify makes no request to the store" begin
    with_six_slots() do local_copy
        store = local_copy.chain.store
        n = length(store.calls)
        verify(local_copy)
        verify(local_copy; full = true)
        @test length(store.calls) == n
    end
end

@testset "verify finds a table file that does not hash to its name" begin
    with_samples_copy() do local_copy
        damaged = damage_table_file!(local_copy, "samples")
        name = basename(damaged.file)
        found = bytes2hex(sha256(read(damaged.file)))
        fault = "table file tables/$name of \"samples\" hashes to $found"
        err = @test_throws FingerprintMismatchError fault verify(local_copy)
        e = err.value
        @test (e.path, e.chain_id, e.slot) ==
            (local_copy.path, local_copy.head.chain_id, 1)
        @test e.expected == head(local_copy).state_fingerprint
        @test e.computed == fingerprint_with_file(local_copy, "samples")
        @test_throws FingerprintMismatchError fault verify(local_copy; full = true)
        # The copy stays readable.
        @test head(local_copy).slot == 1
    end
end

@testset "verify finds a table file that is missing" begin
    with_samples_copy() do local_copy
        file = table_file(local_copy, "samples")
        rm(file)
        missing_file = "table file tables/$(basename(file)) of \"samples\" is missing"
        err = @test_throws FingerprintMismatchError missing_file verify(local_copy)
        @test err.value.computed === nothing
    end
end

@testset "verify names both tables of a shared table file" begin
    with_chain_copy() do local_copy
        commit_ops!(seed_twin_tables!, local_copy)
        damage_table_file!(local_copy, "tags")
        both = "of \"tags\" and \"twin\" hashes to"
        @test_throws FingerprintMismatchError both verify(local_copy)
    end
end

const DIVERGED_CASES = [
    (liar = 4, detail = "a replay of the record cache reproduces slots 0 to 3"),
    (liar = 6, detail = "a replay of the record cache reproduces slots 0 to 5"),
    (liar = 0, detail = "a replay of the record cache fails at its first record"),
]

@testset "verify full finds slot $(case.liar), the first not reproduced" for case in
    DIVERGED_CASES
    with_six_slots() do local_copy
        fingerprints = diverge_from!(local_copy, case.liar)
        # The table files are sound: it is the records that do not reproduce.
        @test verify(local_copy) === nothing
        store = local_copy.chain.store
        n = length(store.calls)
        err = @test_throws FingerprintMismatchError case.detail verify(
            local_copy; full = true
        )
        @test length(store.calls) == n
        e = err.value
        @test (e.path, e.chain_id, e.slot) ==
            (local_copy.path, local_copy.head.chain_id, case.liar)
        @test e.expected == fill(UInt8(case.liar), 32)
        @test e.computed == fingerprints[case.liar + 1]
        @test e.record_client == (; lib = "L", julia = "J")
        @test e.this_client.julia == string(VERSION)
    end
end

@testset "verify full finds a record that the record cache lacks" begin
    with_six_slots() do local_copy
        chain = local_copy.chain
        rm(record_file(chain, 2))
        err = @test_throws RecordCacheError "the file is missing" verify(
            local_copy; full = true
        )
        e = err.value
        @test (e.chain_id, e.slot, e.path) ==
            (local_copy.head.chain_id, 2, record_file(chain, 2))
        @test (e.expected, e.found) == (stored_hash(chain.store, 2), nothing)
    end
end

@testset "verify full finds a cached record of slot $slot with other bytes" for slot in
    (3, 6)
    with_six_slots() do local_copy
        chain = local_copy.chain
        good = read(record_file(chain, slot))
        bad = copy(good)
        bad[end] ⊻= 0x01
        write(record_file(chain, slot), bad)
        err = @test_throws RecordCacheError "the file holds other bytes" verify(
            local_copy; full = true
        )
        e = err.value
        @test e.slot == slot
        @test e.expected == Ops.transaction_hash(good)
        @test e.found == Ops.transaction_hash(bad)
        # The check is local: nothing is written to the record cache.
        @test read(record_file(chain, slot)) == bad
    end
end

@testset "verify throws ArgumentError for a copy with no head" begin
    with_chain_copy() do local_copy
        with_copy_beside(local_copy, "fresh") do fresh
            @test_throws ArgumentError "has no head yet" verify(fresh)
        end
    end
end

@testset "verify throws ArgumentError for a closed copy" begin
    with_samples_copy() do local_copy
        close(local_copy)
        @test_throws ArgumentError "is closed" verify(local_copy)
    end
end
