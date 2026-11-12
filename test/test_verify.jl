using Test
using ChainTables: ChainTables, Chain, FingerprintMismatchError, LocalCopyInconsistentError,
    RecordCacheError, StateFingerprint, commit!, create_chain, create_table!, column!, head,
    insert_rows!, primary_key!, put_object_if_absent, repair!, sync!, update_rows!, verify,
    write_builder
using ChainTables.Testing: InMemoryObjectStore
using SHA: sha256

include("fixtures/chains.jl")

const CT = ChainTables

function chain_over(store, cache_dir, prefix = "p")
    return Chain("bkt", prefix; store, cache_dir, record_host = false, record_user = false)
end

function with_copy(f, chain, path)
    copy = CT.open(chain, path)
    try
        f(copy)
    finally
        close(copy)
    end
    return nothing
end

function create_keyed!(w, name)
    create_table!(w, name) do t
        column!(t, :k, Int64)
        primary_key!(t, :k)
    end
    insert_rows!(w, name, [(k = 1,), (k = 2,)])
    return nothing
end

# Samples at slot 1; tags and its twin, sharing one table file, at slot 2; an update at 3.
function commit_three!(copy)
    w = write_builder(copy)
    create_table!(w, :samples) do t
        column!(t, :id, Int64)
        column!(t, :label, String)
        column!(t, :mass, Float64; nullable = true)
        primary_key!(t, :id)
    end
    insert_rows!(w, :samples, SAMPLE_ROWS)
    commit!(w; comment = "first samples")
    w = write_builder(copy)
    foreach(name -> create_keyed!(w, name), (:tags, :twin))
    commit!(w)
    w = write_builder(copy)
    update_rows!(w, :samples, [(id = 2, mass = 2.5)])
    commit!(w)
    return nothing
end

function with_seeded(f)
    mktempdir() do dir
        store = InMemoryObjectStore()
        chain = chain_over(store, joinpath(dir, "cache"))
        create_chain(chain)
        with_copy(chain, joinpath(dir, "one")) do copy
            sync!(copy)
            commit_three!(copy)
            f(dir, store, chain, copy)
        end
    end
    return nothing
end

function table_file(copy, name)
    return joinpath(copy.path, "tables", bytes2hex(Dict(copy.head.tables)[name]))
end

# Flip the last bit of a table's file; return the file and its good bytes.
function damage!(copy, name)
    file = table_file(copy, name)
    good = read(file)
    write(file, flipped(good))
    return file, good
end

function plant!(store, key, bytes)
    store.objects[key] = bytes
    store.modified[key] = 0
    return nothing
end

# A copy at `last` of a forged chain whose records from `liar` on are then rewritten, in
# the store and the cache, to carry fingerprints this client does not reproduce, the head
# naming the rewritten record: a copy built on committers that diverged from this client.
function with_diverged(f, last, liar)
    mktempdir() do dir
        store = InMemoryObjectStore()
        chain = chain_over(store, joinpath(dir, "cache"))
        chain_id = rand(UInt8, 16)
        honest = forged_chain(chain_id, last)
        foreach(s -> put_object_if_absent(store, slotkey(s), honest.records[s + 1]), 0:last)
        with_copy(chain, joinpath(dir, "copy")) do copy
            @test CT.replay!(copy, 0, last; clock = () -> 0).checkpoints == [last]
            lies = forged_chain(chain_id, last; liars = liar:last).records
            foreach(s -> plant_record!(store, chain, s, lies[s + 1]), 0:last)
            copy.head = with_transaction_hash(copy.head, CT.Ops.transaction_hash(lies[end]))
            f(store, chain, copy, honest.fingerprints)
        end
    end
    return nothing
end

function plant_record!(store, chain, slot, bytes)
    plant!(store, slotkey(slot), bytes)
    write(CT.record_path(chain, slotkey(slot)), bytes)
    return nothing
end

function with_transaction_hash(h, th)
    return CT.Head(
        h.chain_id, h.format_version, h.slot, th, h.state_fingerprint, h.tables,
        h.written_at_ms, h.written_by
    )
end

cached(chain, s) = CT.record_path(chain, slotkey(s))

@testset "verify passes a sound copy with no request" begin
    with_seeded() do dir, store, chain, copy
        n = length(store.calls)
        @test verify(copy) === nothing
        @test verify(copy; full = true) === nothing
        @test length(store.calls) == n
    end
end

@testset "verify names a table file that does not hash to its name" begin
    with_seeded() do dir, store, chain, copy
        file, good = damage!(copy, "samples")
        bad = bytes2hex(sha256(read(file)))
        found = Dict(copy.head.tables)
        found["samples"] = sha256(read(file))
        computed = CT.state_fingerprint(sort!(collect(found); by = first))
        msg = "tables/$(basename(file)) (table \"samples\") hashes to $bad, not its name"
        err = (@test_throws FingerprintMismatchError msg verify(copy)).value
        @test (err.chain_id, err.slot) == (copy.head.chain_id, 3)
        @test (err.expected, err.computed) == (copy.head.state_fingerprint, computed)
        @test err.expected isa StateFingerprint && err.computed isa StateFingerprint
        @test_throws FingerprintMismatchError "hashes to" verify(copy; full = true)
        @test head(copy).slot == 3                                       # still readable
        with_copy(chain, copy.path) do again
            msg = "damaged"
            @test_throws LocalCopyInconsistentError msg CT.load_table!(again, "samples")
        end
    end
end

@testset "verify names a missing table file" begin
    with_seeded() do dir, store, chain, copy
        file = table_file(copy, "samples")
        rm(file)
        msg = "table file tables/$(basename(file)) (table \"samples\") is missing"
        err = (@test_throws FingerprintMismatchError msg verify(copy)).value
        @test err.computed === nothing
    end
end

@testset "verify names both tables of a shared file" begin
    with_seeded() do dir, store, chain, copy
        file, good = damage!(copy, "tags")
        msg = "(tables \"tags\", \"twin\") hashes to"
        @test_throws FingerprintMismatchError msg verify(copy)
        write(file, good)
        @test verify(copy) === nothing
    end
end

@testset "verify refuses a copy with no head, and a closed copy" begin
    with_seeded() do dir, store, chain, copy
        with_copy(chain, joinpath(dir, "fresh")) do fresh
            msg = "verify(copy): the local copy at $(fresh.path) has no head yet"
            @test_throws ArgumentError msg verify(fresh)
        end
        fresh = CT.open(chain, joinpath(dir, "closed"))
        close(fresh)
        @test_throws ArgumentError "is closed" verify(fresh)
    end
end

@testset "verify full bisects to the first slot this client does not reproduce" begin
    with_diverged(6, 4) do store, chain, copy, fingerprints
        # the files are sound
        @test head(copy).slot == 6 && verify(copy) === nothing
        n = length(store.calls)
        msg = "slots below it reproduce"
        err = (@test_throws FingerprintMismatchError msg verify(copy; full = true)).value
        @test length(store.calls) == n                                  # local only
        @test (err.chain_id, err.slot) == (copy.head.chain_id, 4)
        @test (err.expected, err.computed) == (fill(0x04, 32), fingerprints[5])
        @test err.record_client == (; lib = "L4", julia = "J")
        @test err.this_client.julia == string(VERSION)
        @test repair!(copy) == (; slot = 6, files_rewritten = 0, attachments_repaired = 0)
    end
end

const FIRST_LIAR_CASES = [
    (name = "the head", last = 5, liar = 5, msg = "slots below it reproduce"),
    (name = "the genesis", last = 3, liar = 0, msg = "it is the first record"),
]

@testset "verify full finds the first liar: $(case.name)" for case in FIRST_LIAR_CASES
    with_diverged(case.last, case.liar) do store, chain, copy, fingerprints
        verify_full = () -> verify(copy; full = true)
        err = (@test_throws FingerprintMismatchError case.msg verify_full()).value
        @test err.slot == case.liar
        @test err.computed == fingerprints[case.liar + 1]
    end
end

@testset "verify full stops at a record the cache lacks" begin
    with_diverged(6, 4) do store, chain, copy, fingerprints
        rm(cached(chain, 2))
        msg = "the record is not cached, and verify(copy; full = true) is local"
        err = (@test_throws RecordCacheError msg verify(copy; full = true)).value
        @test (err.chain_id, err.slot) == (copy.head.chain_id, 2)
        @test (err.path, err.found) == (cached(chain, 2), nothing)
    end
end

@testset "verify full blames a damaged cached record on the cache" begin
    with_diverged(6, 4) do store, chain, copy, fingerprints
        three = read(cached(chain, 3))
        write(cached(chain, 3), flipped(three))
        msg = "the cached record is not the one slot 4 names"
        err = (@test_throws RecordCacheError msg verify(copy; full = true)).value
        @test (err.slot, err.path) == (3, cached(chain, 3))
        @test err.expected == CT.Ops.transaction_hash(three)
        @test err.found == CT.Ops.transaction_hash(flipped(three))
        write(cached(chain, 3), three)
        six = read(cached(chain, 6))
        write(cached(chain, 6), flipped(six))
        msg = "the cached record is not the one the head of the local copy names"
        @test_throws RecordCacheError msg verify(copy; full = true)
    end
end

@testset "verify full notices a cached record that changes while it reads" begin
    with_diverged(6, 4) do store, chain, copy, fingerprints
        three = read(cached(chain, 3))
        walk = CT.BackwardWalk(copy, chain, "verify(copy; full = true)", false)
        hashes = CT.walked_hashes(walk)
        write(cached(chain, 3), flipped(three))
        msg = "the cached record changed while verify(copy; full = true) read it"
        read_three = () -> CT.walked_record_at(walk, 3, hashes[4])
        err = (@test_throws RecordCacheError msg read_three()).value
        @test (err.chain_id, err.slot) == (copy.head.chain_id, 3)
        @test err.path == cached(chain, 3)
        @test err.expected == CT.Ops.transaction_hash(three)
        @test err.found == CT.Ops.transaction_hash(flipped(three))
    end
end

@testset "sync! of a lying chain stops at the checkpoint" begin
    with_diverged(5, 5) do store, chain, copy, fingerprints
        cold = chain_over(store, joinpath(dirname(chain.cache.dir), "cold"))
        with_copy(cold, joinpath(dirname(chain.cache.dir), "fresh")) do fresh
            @test_throws FingerprintMismatchError "differs" sync!(fresh)
            @test fresh.head === nothing || head(fresh).slot < 5
        end
    end
end

@testset "verify infers" begin
    with_seeded() do dir, store, chain, copy
        @test @inferred(verify(copy)) === nothing
    end
end
