# Over 400 lines: one test file per src file, and sync! has this many behaviours.
using Test
using ChainTables: ChainTables, Chain, ChainNotFoundError, MalformedRecordError,
    PinnedCopyError, RewrittenChainError, TransactionHash, TransportError, WrongChainError,
    commit!, create_chain, create_table!, column!, head, insert_rows!, primary_key!,
    put_object_if_absent, sync!, table, write_builder
using ChainTables.Testing: InMemoryObjectStore

include("fixtures/chains.jl")
include("fixtures/seeded_chains.jl")

const CT = ChainTables

function insert_sample!(copy, i)
    w = write_builder(copy)
    insert_rows!(w, :samples, [(id = i, label = string(i), mass = Float64(i))])
    return commit!(w)
end

sample_ids(copy) = [row.id for row in table(copy, :samples)]

fetches(store, n) = [k for (v, k) in store.calls[(n + 1):end] if v === :fetch_object]

function plant!(store, key, bytes)
    store.objects[key] = bytes
    store.modified[key] = 0
    return nothing
end

@testset "sync! binds a fresh copy at slot 0, slot 0 from the store" begin
    with_chain() do dir, store, chain
        created = create_chain(chain)
        with_copy(chain, joinpath(dir, "copy")) do copy
            @test length(store.calls) == 1                     # open does no I/O
            @test sync!(copy) == (; applied = 1, slot = 0, created.transaction_hash)
            @test head(copy).slot == 0 && copy.head.chain_id == created.chain_id
            @test CT.tables(copy) == String[]
            @test store.calls[2:end] == [
                (:stat_object, slotkey(0)), (:stat_object, slotkey(1)),
                (:fetch_object, slotkey(0)),
            ]
        end
    end
end

@testset "sync! with nothing new asks for the head's slot and probes once" begin
    with_chain() do dir, store, chain
        created = create_chain(chain)
        with_copy(chain, joinpath(dir, "copy")) do copy
            sync!(copy)
            empty!(store.calls)
            @test sync!(copy) == (; applied = 0, slot = 0, created.transaction_hash)
            @test store.calls == [(:fetch_object, slotkey(0)), (:stat_object, slotkey(1))]
        end
    end
end

@testset "sync! on a copy with no head and no slot 0 is ChainNotFoundError" begin
    with_chain() do dir, store, chain
        with_copy(chain, joinpath(dir, "copy")) do copy
            msg = "no chain at this bucket"
            err = (@test_throws ChainNotFoundError msg sync!(copy)).value
            @test (err.bucket, err.prefix) == ("bkt", "p")
            @test copy.head === nothing
            create_chain(chain)                                # a miss is never cached
            @test sync!(copy).slot == 0
        end
    end
end

@testset "sync! replays a second client's records to the same head" begin
    with_seeded(commit_samples!) do dir, store, chain, copy, _
        with_copy(chain, joinpath(dir, "two")) do copy2
            th = TransactionHash(copy.head.transaction_hash)
            @test sync!(copy2) == (; applied = 2, slot = 1, transaction_hash = th)
            @test head(copy2) == head(copy)
            @test isequal(collect(table(copy2, :samples)), collect(table(copy, :samples)))
        end
    end
end

@testset "sync! caches what it fetched, and never a probe's miss" begin
    with_seeded(commit_samples!) do dir, store, chain, copy, _
        sync!(copy)
        @test !isfile(CT.record_path(chain, slotkey(2)))
        with_copy(chain, joinpath(dir, "other")) do other
            sync!(other)
            insert_sample!(other, 3)
        end
        @test sync!(copy).applied == 1
        @test isfile(CT.record_path(chain, slotkey(2)))
        # Slot 1 was asked of the store by copy's two syncs, other's commit, and as the
        # top of other's sync, which nothing above vouched for (ADR-0040, ADR-0041).
        @test count(==((:fetch_object, slotkey(1))), store.calls) == 4
    end
end

@testset "sync! refuses a pinned copy" begin
    with_seeded(commit_samples!) do dir, store, chain, copy, _
        CT.pin!(copy)
        err = (@test_throws PinnedCopyError "the local copy is pinned" sync!(copy)).value
        @test (err.path, err.slot, err.call) == (copy.path, 1, "sync!")
        CT.unpin!(copy)
        @test sync!(copy).applied == 0
    end
end

@testset "sync! refuses a copy opened over something that is not a Chain" begin
    mktempdir() do dir
        copy = CT.open(:not_a_chain, joinpath(dir, "x"))
        @test_throws ArgumentError "sync!: the local copy at" sync!(copy)
    end
end

@testset "sync! throws RewrittenChainError when the head's slot holds another record" begin
    with_seeded(commit_samples!) do dir, store, chain, copy, _
        cid, th1 = copy.head.chain_id, copy.head.transaction_hash
        good = store.objects[slotkey(1)]
        other = with_comment(good, 1, "rewritten")
        plant!(store, slotkey(1), other)
        err = (@test_throws RewrittenChainError "contradicts" sync!(copy)).value
        @test (err.chain_id, err.slot) == (cid, 1)
        @test (err.expected, err.found) == (th1, CT.Ops.transaction_hash(other))
        @test read(CT.record_path(chain, slotkey(1))) == good    # not cached
        @test sample_ids(copy) == [1, 2]                          # still readable
        plant!(store, slotkey(1), b"not a record")
        err = (@test_throws RewrittenChainError "contradicts" sync!(copy)).value
        @test err.found == CT.Ops.transaction_hash(b"not a record")
    end
end

@testset "sync! throws RewrittenChainError when the head's slot is absent" begin
    with_seeded(commit_samples!) do dir, store, chain, copy, _
        good = store.objects[slotkey(1)]
        delete!(store.objects, slotkey(1))
        msg = "the head's slot is absent"
        err = (@test_throws RewrittenChainError msg sync!(copy)).value
        @test (err.chain_id, err.slot, err.found) == (copy.head.chain_id, 1, nothing)
        @test err.expected == copy.head.transaction_hash
        plant!(store, slotkey(1), good)
        @test sync!(copy).applied == 0
    end
end

@testset "sync! throws RewrittenChainError for a record naming another parent" begin
    with_seeded(commit_samples!) do dir, store, chain, copy, _
        cid, th1 = copy.head.chain_id, copy.head.transaction_hash
        ops = [CT.Ops.Insert("samples", [Any[3, "c", 3.0]])]
        fp = copy.head.state_fingerprint
        forged = forged_record(CT.chain_id_bytes(cid), 2, fill(0xaa, 32), fp; ops)
        plant!(store, slotkey(2), forged)
        err = (@test_throws RewrittenChainError "does not name" sync!(copy)).value
        @test (err.chain_id, err.slot) == (cid, 2)
        @test (err.expected, err.found) == (th1, fill(0xaa, 32))
        @test head(copy).slot == 1 && isempty(copy.content)
        @test !isfile(CT.record_path(chain, slotkey(2)))
    end
end

@testset "sync! throws MalformedRecordError for a record of another chain" begin
    with_seeded(commit_samples!) do dir, store, chain, copy, _
        cid, th1 = copy.head.chain_id, copy.head.transaction_hash
        ops = [CT.Ops.Insert("samples", [Any[3, "c", 3.0]])]
        fp = copy.head.state_fingerprint
        plant!(store, slotkey(2), forged_record(fill(0x11, 16), 2, th1, fp; ops))
        other = CT.chain_id_string(fill(0x11, 16))
        err = (@test_throws MalformedRecordError "its chain id is $other" sync!(copy)).value
        @test (err.chain_id, err.slot) == (cid, 2)
        @test head(copy).slot == 1 && !isfile(CT.record_path(chain, slotkey(2)))
    end
end

@testset "sync! throws RewrittenChainError for a slot gone after the probe" begin
    with_seeded(commit_samples!) do dir, store, chain, copy, _
        th1 = copy.head.transaction_hash
        ops = [CT.Ops.Insert("samples", [Any[3, "c", 3.0]])]
        record = forged_record(CT.chain_id_bytes(copy.head.chain_id), 2, th1, th1; ops)
        plant!(store, slotkey(2), record)
        store.fault = (verb, key, phase) -> verb === :fetch_object && key == slotkey(2) &&
            phase === :before && delete!(store.objects, key)
        err = (@test_throws RewrittenChainError "absent now" sync!(copy)).value
        @test (err.chain_id, err.slot, err.found) == (copy.head.chain_id, 2, nothing)
    end
end

@testset "sync! over another chain's prefix with a cold cache is WrongChainError" begin
    with_seeded(commit_samples!) do dir, store, chain, copy, _
        chainq = Chain("bkt", "q"; store, cache_dir = joinpath(dir, "qcache"))
        createdq = create_chain(chainq)
        with_copy(chainq, joinpath(dir, "q")) do q
            sync!(q)
            commit_samples!(q)
        end
        close(copy)
        cold = Chain("bkt", "q"; store, cache_dir = joinpath(dir, "coldcache"))
        with_copy(cold, copy.path) do wrong
            err = (@test_throws WrongChainError "bound to another chain" sync!(wrong)).value
            @test (err.path, err.bound) == (copy.path, copy.head.chain_id)
            @test err.opened == createdq.chain_id
            @test head(wrong).slot == 1
        end
        @test_throws WrongChainError "bound to another chain" CT.open(chainq, copy.path)
    end
end

@testset "sync! over an emptied prefix is RewrittenChainError, the cache warm" begin
    with_seeded(commit_samples!) do dir, store, chain, copy, _
        empty!(store.objects)
        empty!(store.modified)
        err = (@test_throws RewrittenChainError "absent" sync!(copy)).value
        @test (err.chain_id, err.slot, err.found) == (copy.head.chain_id, 1, nothing)
    end
end

@testset "sync! over a prefix refilled by another chain is WrongChainError" begin
    with_seeded(commit_samples!) do dir, store, chain, copy, _
        empty!(store.objects)
        empty!(store.modified)
        cache_dir = joinpath(dir, "c2cache")
        c2 = Chain("bkt", "p"; store, cache_dir, record_user = false)
        created2 = create_chain(c2)
        with_copy(c2, joinpath(dir, "c2")) do writer
            sync!(writer)
            commit_samples!(writer)
        end
        held = Dict(store.objects)
        err = (@test_throws WrongChainError "bound to another chain" sync!(copy)).value
        @test (err.bound, err.opened) == (copy.head.chain_id, created2.chain_id)
        @test store.objects == held
    end
end

@testset "sync! over a warm cache asks the store only for slot 0 and the top" begin
    with_seeded(commit_samples!) do dir, store, chain, copy, _
        foreach(i -> insert_sample!(copy, i), 3:4)
        with_copy(chain, joinpath(dir, "warm")) do fresh
            n = length(store.calls)
            @test (@test_logs sync!(fresh)).slot == 3
            @test sort(fetches(store, n)) == [slotkey(0), slotkey(3)]
            @test head(fresh) == head(copy)
        end
    end
end

const DAMAGED_CASES = [
    (name = "an empty genesis", slot = 0, bytes = _ -> UInt8[], fetched = [0, 3]),
    (
        name = "garbage mid-read",
        slot = 1,
        bytes = _ -> b"not a record",
        fetched = [0, 1, 3],
    ),
    (
        name = "a twin record",
        slot = 1,
        bytes = good -> with_comment(good, 1, "first samplez"),
        fetched = [0, 1, 2, 3],
    ),
]

@testset "sync! fetches a damaged cached record: $(case.name)" for case in DAMAGED_CASES
    with_seeded(commit_samples!) do dir, store, chain, copy, _
        foreach(i -> insert_sample!(copy, i), 3:4)
        good = store.objects[slotkey(case.slot)]
        write(CT.record_path(chain, slotkey(case.slot)), case.bytes(good))
        with_copy(chain, joinpath(dir, "fresh")) do fresh
            n = length(store.calls)
            @test sync!(fresh).slot == 3
            @test sort(fetches(store, n)) == slotkey.(case.fetched)
            @test read(CT.record_path(chain, slotkey(case.slot))) == good
            @test head(fresh) == head(copy)
        end
    end
end

@testset "sync! fetches again a damaged cached head slot" begin
    with_seeded(commit_samples!) do dir, store, chain, copy, _
        write(CT.record_path(chain, slotkey(1)), b"")
        @test sync!(copy).applied == 0
        @test read(CT.record_path(chain, slotkey(1))) == store.objects[slotkey(1)]
    end
end

function sync_and_commit_samples!(copy)
    sync!(copy)
    return commit_samples!(copy)
end

# Another chain at the same prefix, written through its own cache; returns its head.
function refill_with_another_chain!(dir, store)
    empty!(store.objects)
    empty!(store.modified)
    cache_dir = joinpath(dir, "other")
    other = Chain("bkt", "p"; store, cache_dir, record_user = false)
    create_chain(other)
    writer = CT.open(other, joinpath(dir, "writer"))
    sync_and_commit_samples!(writer)
    insert_sample!(writer, 3)
    written = head(writer)
    close(writer)
    return written
end

@testset "sync! replaces a whole cached chain the bucket no longer holds" begin
    with_chain() do dir, store, chain
        create_chain(chain)
        with_copy(sync_and_commit_samples!, chain, joinpath(dir, "old"))
        written = refill_with_another_chain!(dir, store)
        with_copy(chain, joinpath(dir, "reader")) do reader
            @test sync!(reader).slot == 2
            @test head(reader) == written
            @test sample_ids(reader) == [1, 2, 3]
        end
    end
end

@testset "sync! applies our own record after a crash between the put and the head" begin
    with_seeded(commit_samples!) do dir, store, chain, copy, _
        head1 = read(joinpath(copy.path, "heads", "000000000001"))
        tables_dir = joinpath(copy.path, "tables")
        files1 = Dict(f => read(joinpath(tables_dir, f)) for f in readdir(tables_dir))
        r = insert_sample!(copy, 3)
        close(copy)
        rm(joinpath(copy.path, "heads", "000000000002"))
        write(joinpath(copy.path, "heads", "000000000001"), head1)
        foreach(((f, b),) -> write(joinpath(copy.path, "tables", f), b), files1)
        with_copy(chain, copy.path) do again
            @test head(again).slot == 1
            @test sync!(again) == (; applied = 1, slot = 2, r.transaction_hash)
            @test head(again).state_fingerprint == r.state_fingerprint
            @test sample_ids(again) == [1, 2, 3]
        end
    end
end

@testset "replay! checkpoints by the amortized rule on a scripted clock" begin
    with_seeded(commit_samples!) do dir, store, chain, copy, _
        foreach(i -> insert_sample!(copy, i), 3:12)
        ticks = Ref(0)
        clock = () -> (ticks[] += 1)               # apply and checkpoint each take one tick
        with_copy(chain, joinpath(dir, "fresh")) do fresh
            got = CT.replay!(fresh, 0, 11; clock)
            @test got == (; applied = 12, checkpoints = [0, 2, 4, 6, 8, 10, 11])
            @test head(fresh) == head(copy)
        end
    end
end

# A checkpoint costing five applies waits for six applies' worth before the next one; a
# checkpoint anywhere else would desynchronise the script.
function five_tick_checkpoints()
    durations = reduce(vcat, [s in (0, 6, 11) ? [1, 5] : [1] for s in 0:11])
    ends = cumsum(durations)
    return vec(permutedims(hcat(ends .- durations, ends)))
end

@testset "replay! waits as long as the last checkpoint took" begin
    with_seeded(commit_samples!) do dir, store, chain, copy, _
        foreach(i -> insert_sample!(copy, i), 3:12)
        script = five_tick_checkpoints()
        with_copy(chain, joinpath(dir, "fresh")) do fresh
            got = CT.replay!(fresh, 0, 11; clock = () -> popfirst!(script))
            @test got == (; applied = 12, checkpoints = [0, 6, 11])
            @test isempty(script) && head(fresh) == head(copy)
        end
    end
end

@testset "sync! that fails leaves the copy at its last checkpoint and resumes" begin
    with_seeded(commit_samples!) do dir, store, chain, copy, _
        foreach(i -> insert_sample!(copy, i), 3:12)
        store.fault = (verb, key, phase) -> verb === :fetch_object && key == slotkey(7) &&
            phase === :before && throw(TransportError("timeout"))
        cold = Chain("bkt", "p"; store, cache_dir = joinpath(dir, "cold"))
        failed = CT.open(cold, joinpath(dir, "failed"))
        @test_throws TransportError "timeout" sync!(failed)
        @test 0 <= head(failed).slot < 7 && isempty(failed.content)
        reached = head(failed)
        close(failed)
        store.fault = (verb, key, phase) -> nothing
        with_copy(cold, failed.path) do again
            @test head(again) == reached
            @test sync!(again).applied == 11 - reached.slot
            @test head(again) == head(copy)
        end
    end
end

@testset "sync! with read_ahead = 1 fetches one slot at a time, in order" begin
    with_seeded(commit_samples!) do dir, store, chain, copy, _
        foreach(i -> insert_sample!(copy, i), 3:5)
        one = Chain("bkt", "p"; store, cache_dir = joinpath(dir, "cache1"), read_ahead = 1)
        with_copy(one, joinpath(dir, "one_ahead")) do c1
            n = length(store.calls)
            @test sync!(c1).slot == 4
            @test fetches(store, n) == slotkey.(0:4)
        end
    end
end

@testset "sync! stops at a malformed record, the copy at its last checkpoint" begin
    with_seeded(commit_samples!) do dir, store, chain, copy, _
        h = copy.head
        ops = [CT.Ops.Insert("samples", [Any[13.0, "x", 1.0]])]
        cid = CT.chain_id_bytes(h.chain_id)
        bad = forged_record(cid, 2, h.transaction_hash, h.state_fingerprint; ops)
        put_object_if_absent(store, slotkey(2), bad)
        err = (@test_throws MalformedRecordError "column \"id\" is int64" sync!(copy)).value
        @test (err.chain_id, err.slot, err.op) == (h.chain_id, 2, 1)
        @test head(copy).slot == 1 && isempty(copy.content)
    end
end

@testset "sync! infers" begin
    with_seeded(commit_samples!) do dir, store, chain, copy, _
        @test @inferred(sync!(copy)).applied == 0
    end
end
