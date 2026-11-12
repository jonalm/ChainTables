# Over 400 lines: one test file per src file, and commit! has this many behaviours.
using Test
using ChainTables: ChainTables, Chain, CommitOutcomeUnknownError, FingerprintMismatchError,
    LostRaceError, PinnedCopyError, RewrittenChainError, StaleHeadError, StateFingerprint,
    TransactionHash, TransportError, WrongChainError, WriteBuilderError, commit!,
    commit_log, create_chain, create_table!, column!, delete_rows!, drop_table!, head,
    insert_rows!, primary_key!, sync!, table, tables, update_rows!, write_builder
using ChainTables.Testing: InMemoryObjectStore

include("fixtures/chains.jl")

const CT = ChainTables

function with_chain(f; kw...)
    mktempdir() do dir
        store = InMemoryObjectStore()
        cache_dir = joinpath(dir, "cache")
        chain = Chain(
            "bkt", "p"; store, cache_dir, record_host = false, record_user = false, kw...
        )
        f(dir, store, chain)
    end
    return nothing
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

function declare_samples!(w)
    create_table!(w, :samples) do t
        column!(t, :id, Int64)
        column!(t, :label, String)
        column!(t, :mass, Float64; nullable = true)
        primary_key!(t, :id)
    end
    return nothing
end

function commit_samples!(copy)
    w = write_builder(copy)
    declare_samples!(w)
    insert_rows!(w, :samples, SAMPLE_ROWS)
    return commit!(w; comment = "first samples")
end

# A chain with genesis and the samples table at slot 1, and a copy at its head.
function with_seeded(f; kw...)
    with_chain(; kw...) do dir, store, chain
        create_chain(chain)
        with_copy(chain, joinpath(dir, "one")) do copy
            sync!(copy)
            commit_samples!(copy)
            f(dir, store, chain, copy)
        end
    end
    return nothing
end

function builder_inserting(copy, i)
    w = write_builder(copy)
    insert_rows!(w, :samples, [(id = i, label = string(i), mass = Float64(i))])
    return w
end

rows_of(copy) = [(row.id, row.label, row.mass) for row in table(copy, :samples)]

puts(store, key) = count(==((:put_object_if_absent, key)), store.calls)

function local_state(copy)
    heads, tables = joinpath(copy.path, "heads"), joinpath(copy.path, "tables")
    return (readdir(heads), readdir(tables), head(copy))
end

function plant!(store, key, bytes)
    store.objects[key] = bytes
    store.modified[key] = 0
    return nothing
end

function commit_first(store, w, result)
    return function (verb, key, phase)
        verb === :put_object_if_absent && phase === :before && result[] === nothing ||
            return nothing
        store.fault = (verb, key, phase) -> nothing
        result[] = commit!(w)
        return nothing
    end
end

function refill_with_another_chain(dir, store)
    cache_dir = joinpath(dir, "other")
    other = Chain("bkt", "p"; store, cache_dir, record_user = false)
    create_chain(other)
    with_copy(sync_and_commit_samples!, other, joinpath(dir, "writer"))
    return nothing
end

function sync_and_commit_samples!(copy)
    sync!(copy)
    return commit_samples!(copy)
end

@testset "commit! puts one record at the next slot and moves the head" begin
    with_chain() do dir, store, chain
        created = create_chain(chain)
        with_copy(chain, joinpath(dir, "one")) do copy
            sync!(copy)
            r1 = commit_samples!(copy)
            @test r1.slot == 1 && r1.transaction_hash isa TransactionHash
            @test r1.state_fingerprint isa StateFingerprint
            @test head(copy) == (; slot = 1, r1.transaction_hash, r1.state_fingerprint)
            @test isequal(rows_of(copy), [(1, "a", 1.5), (2, "b", missing)])
            record = CT.Ops.decode_record(store.objects[slotkey(1)]; slot = 1)
            @test record.prev_hash == created.transaction_hash
            @test record.comment == "first samples" && length(record.ops) == 2
            @test CT.chain_id_string(record.chain_id) == created.chain_id
        end
    end
end

@testset "commit! lands with one put, no read-back, and caches its record" begin
    with_seeded() do dir, store, chain, copy
        @test puts(store, slotkey(1)) == 1
        @test (:fetch_object, slotkey(1)) ∉ store.calls
        @test read(CT.record_path(chain, slotkey(1))) == store.objects[slotkey(1)]
    end
end

@testset "commit! spends the builder" begin
    with_seeded() do dir, store, chain, copy
        w = builder_inserting(copy, 3)
        commit!(w)
        @test w.spent
        @test_throws WriteBuilderError "this builder is spent" commit!(w)
    end
end

@testset "commit! behind the chain is StaleHeadError, before anything is applied" begin
    with_seeded() do dir, store, chain, copy
        with_copy(chain, joinpath(dir, "two")) do copy2
            sync!(copy2)
            r2 = commit!(builder_inserting(copy2, 3))
            w = write_builder(copy)
            delete_rows!(w, :samples, [(id = 1,)])
            before = (local_state(copy), length(store.objects))
            err = (@test_throws StaleHeadError "behind the chain" commit!(w)).value
            @test (err.chain_id, err.slot, err.chain_slot) == (copy.head.chain_id, 1, 2)
            @test err.path == copy.path
            @test (local_state(copy), length(store.objects)) == before
            @test puts(store, slotkey(2)) == 1
            @test sync!(copy) == (; applied = 1, slot = 2, r2.transaction_hash)
        end
    end
end

@testset "commit! of a builder taken before a sync! is StaleHeadError, no request" begin
    with_seeded() do dir, store, chain, copy
        w = builder_inserting(copy, 4)
        with_copy(chain, joinpath(dir, "two")) do copy2
            sync!(copy2)
            commit!(builder_inserting(copy2, 3))
        end
        sync!(copy)
        n = length(store.calls)
        err = (@test_throws StaleHeadError "a sync! moved the local copy" commit!(w)).value
        @test (err.chain_id, err.slot, err.chain_slot) == (copy.head.chain_id, 1, 2)
        @test length(store.calls) == n
    end
end

const STATE_GATE_CASES = [
    (
        name = "insert on a present key",
        rows = [(:insert, (id = 2, label = "dup", mass = 0.0))],
        msg = "op 1 (insert on \"samples\"): insert names a key that is present: (2,)",
    ),
    (
        name = "update on an absent key",
        rows = [(:delete, (id = 1,)), (:update, (id = 9, mass = 1.0))],
        msg = "op 2 (update on \"samples\"): update names a key that is absent: (9,)",
    ),
    (
        name = "delete on an absent key", rows = [(:delete, (id = 9,))],
        msg = "op 1 (delete on \"samples\"): delete names a key that is absent: (9,)",
    ),
]

const ADD_ROWS = (insert = insert_rows!, update = update_rows!, delete = delete_rows!)

@testset "commit! refuses a forbidden op: $(case.name)" for case in STATE_GATE_CASES
    with_seeded() do dir, store, chain, copy
        w = write_builder(copy)
        foreach(((verb, row),) -> ADD_ROWS[verb](w, :samples, [row]), case.rows)
        before = (local_state(copy), length(store.objects))
        @test_throws WriteBuilderError case.msg commit!(w)
        @test (local_state(copy), length(store.objects)) == before
        @test isempty(copy.content) && isempty(copy.loaded)
        @test isequal(rows_of(copy), [(1, "a", 1.5), (2, "b", missing)])
        @test puts(store, slotkey(2)) == 0
    end
end

const BAD_BUILDER_CASES = [
    (name = "no ops", ops = false, comment = nothing, msg = "the builder has no ops"),
    (
        name = "a comment that is not text",
        ops = true,
        comment = 1,
        msg = "comment is a Int64, not text",
    ),
    (
        name = "a comment with U+0000",
        ops = true,
        comment = "a\0b",
        msg = "comment contains U+0000",
    ),
]

@testset "commit! refuses a builder with $(case.name)" for case in BAD_BUILDER_CASES
    with_seeded() do dir, store, chain, copy
        w = write_builder(copy)
        case.ops && delete_rows!(w, :samples, [(id = 1,)])
        before = local_state(copy)
        @test_throws WriteBuilderError case.msg commit!(w; case.comment)
        @test local_state(copy) == before && puts(store, slotkey(2)) == 0
    end
end

@testset "write_builder refuses a copy with no head" begin
    with_seeded() do dir, store, chain, copy
        with_copy(chain, joinpath(dir, "fresh")) do fresh
            msg = "write_builder: the local copy at $(fresh.path) has no head yet"
            @test_throws ArgumentError msg write_builder(fresh)
        end
    end
end

function declare_tags!(w)
    create_table!(w, :tags) do t
        column!(t, :k, Vector{UInt8})
        primary_key!(t, :k)
    end
    return nothing
end

@testset "write_builder loads a table only when the builder names it" begin
    with_seeded() do dir, store, chain, copy
        close(copy)
        with_copy(chain, copy.path) do again
            w = write_builder(again)
            @test w.pending == Set(["samples"]) && isempty(again.loaded)
            declare_tags!(w)
            insert_rows!(w, :tags, [(k = UInt8[1],)])
            @test isempty(again.loaded)
            insert_rows!(w, :samples, [(id = 3, label = "c", mass = 3.0)])
            @test again.loaded == Set(["samples"]) && isempty(w.pending)
            @test commit!(w).slot == 2
            @test tables(again) == ["samples", "tags"]
        end
    end
end

@testset "write_builder drops an unread table without reading it" begin
    with_seeded() do dir, store, chain, copy
        close(copy)
        with_copy(chain, copy.path) do again
            w = write_builder(again)
            drop_table!(w, :samples)
            @test isempty(again.loaded)
            @test commit!(w).slot == 2
            @test tables(again) == String[]
        end
    end
end

@testset "commit! loses a race to another client's record, never retried" begin
    with_seeded() do dir, store, chain, a
        with_copy(chain, joinpath(dir, "two")) do b
            sync!(b)
            wa, wb = builder_inserting(a, 3), builder_inserting(b, 4)
            ra = Ref{Any}(nothing)
            # a lands while b's put is in flight
            store.fault = commit_first(store, wa, ra)
            before = local_state(b)
            err = (@test_throws LostRaceError "already fills the slot" commit!(wb)).value
            @test (err.chain_id, err.slot) == (a.head.chain_id, 2)
            @test err.transaction_hash == ra[].transaction_hash
            @test puts(store, slotkey(2)) == 2
            @test count(==((:fetch_object, slotkey(2))), store.calls) == 1
            @test local_state(b) == before
            @test sync!(b) == (; applied = 1, slot = 2, ra[].transaction_hash)
        end
    end
end

@testset "commit! succeeds when only the acknowledgement was lost" begin
    with_seeded() do dir, store, chain, copy
        store.fault = (verb, key, phase) -> verb === :put_object_if_absent &&
            phase === :after && throw(TransportError("connection reset by peer"))
        r = commit!(builder_inserting(copy, 3))
        @test r.slot == 2 && head(copy).slot == 2
        @test puts(store, slotkey(2)) == 1
        @test count(==((:fetch_object, slotkey(2))), store.calls) == 1
    end
end

@testset "commit! throws a refusal of the put at once, the copy at its head" begin
    with_seeded() do dir, store, chain, copy
        store.fault = (verb, key, phase) -> verb === :put_object_if_absent &&
            phase === :before && throw(TransportError("forbidden"; status = 403))
        before = local_state(copy)
        @test_throws TransportError "forbidden" commit!(builder_inserting(copy, 3))
        @test puts(store, slotkey(2)) == 1 && !haskey(store.objects, slotkey(2))
        @test local_state(copy) == before && isempty(copy.content)
    end
end

@testset "commit! whose retries are spent is CommitOutcomeUnknownError" begin
    with_seeded() do dir, store, chain, copy
        store.fault = (verb, key, phase) -> verb === :put_object_if_absent &&
            phase === :before && throw(TransportError("service unavailable"; status = 503))
        before = local_state(copy)
        msg = "may or may not"
        w = builder_inserting(copy, 3)
        err = (@test_throws CommitOutcomeUnknownError msg commit!(w)).value
        @test err.cause isa TransportError && err.cause.status == 503
        @test puts(store, slotkey(2)) == CT.PUT_ATTEMPTS
        @test local_state(copy) == before
    end
end

@testset "commit! whose response is lost to a store's own error names its record" begin
    with_seeded() do dir, store, chain, copy
        store.fault = (verb, key, phase) -> verb === :put_object_if_absent &&
            phase === :after && error("response dropped")
        w = builder_inserting(copy, 3)
        before = local_state(copy)
        err = (@test_throws CommitOutcomeUnknownError "may or may not" commit!(w)).value
        store.fault = (verb, key, phase) -> nothing
        @test (err.chain_id, err.slot, err.landed) == (copy.head.chain_id, 2, nothing)
        @test err.cause isa ErrorException && err.transaction_hash isa TransactionHash
        @test local_state(copy) == before && isempty(copy.content)
        sync!(copy)
        entry = only(commit_log(copy; last = 1))
        @test (entry.slot, entry.transaction_hash) == (2, err.transaction_hash)
    end
end

@testset "commit! whose put fails before it lands leaves the slot empty" begin
    with_seeded() do dir, store, chain, copy
        store.fault = (verb, key, phase) -> verb === :put_object_if_absent &&
            phase === :before && error("interrupted")
        w = builder_inserting(copy, 3)
        err = (@test_throws CommitOutcomeUnknownError "may or may not" commit!(w)).value
        store.fault = (verb, key, phase) -> nothing
        @test err.slot == 2 && err.landed === nothing
        @test sync!(copy).slot == 1 && !haskey(store.objects, slotkey(2))
    end
end

@testset "commit! whose head fails to write is CommitOutcomeUnknownError, landed" begin
    with_seeded() do dir, store, chain, copy
        w = builder_inserting(copy, 3)
        heads = joinpath(copy.path, "heads")
        chmod(heads, 0o555)                       # the head cannot be written; the put wins
        err = try
            (@test_throws CommitOutcomeUnknownError "head was not written" commit!(w)).value
        finally
            chmod(heads, 0o755)
        end
        @test err.landed === true && err.cause isa SystemError
        @test haskey(store.objects, slotkey(2)) && head(copy).slot == 1
        @test sync!(copy).slot == 2
        @test rows_of(copy)[end] == (3, "3", 3.0)
    end
end

@testset "commit! refuses a head that disagrees with its own record" begin
    with_seeded() do dir, store, chain, copy
        h = copy.head
        lie = with_fingerprint(store.objects[slotkey(1)], 1, fill(0xee, 32))
        plant!(store, slotkey(1), lie)
        write(CT.record_path(chain, slotkey(1)), lie)
        copy.head = CT.Head(
            h.chain_id, h.format_version, h.slot, CT.Ops.transaction_hash(lie),
            h.state_fingerprint, h.tables, h.written_at_ms, h.written_by
        )
        w = write_builder(copy)
        delete_rows!(w, :samples, [(id = 1,)])
        msg = "disagrees with its own record"
        err = (@test_throws FingerprintMismatchError msg commit!(w)).value
        @test (err.chain_id, err.slot) == (h.chain_id, 1)
        @test (err.expected, err.computed) == (fill(0xee, 32), h.state_fingerprint)
        @test err.record_client.julia == err.this_client.julia == string(VERSION)
        @test !haskey(store.objects, slotkey(2))
    end
end

const REFUSED_CHAIN_CASES = [
    (
        name = "a rewritten chain",
        error = RewrittenChainError,
        msg = "contradicts",
        refill = false,
    ),
    (name = "another chain", error = WrongChainError, msg = "another chain", refill = true),
]

@testset "commit! refuses to build on $(case.name)" for case in REFUSED_CHAIN_CASES
    with_seeded() do dir, store, chain, copy
        empty!(store.objects)
        empty!(store.modified)
        case.refill && refill_with_another_chain(dir, store)
        held = Dict(store.objects)
        @test_throws case.error case.msg commit!(builder_inserting(copy, 3))
        @test store.objects == held
    end
end

@testset "write_builder and commit! refuse a pinned copy" begin
    with_seeded() do dir, store, chain, copy
        w = builder_inserting(copy, 3)
        CT.pin!(copy)
        err = (@test_throws PinnedCopyError "pinned" write_builder(copy)).value
        @test (err.path, err.slot, err.call) == (copy.path, 1, "write_builder")
        err = (@test_throws PinnedCopyError "pinned" commit!(w)).value
        @test err.call == "commit!" && w.spent
        @test !haskey(store.objects, slotkey(2))
    end
end

@testset "write_builder and commit! infer" begin
    with_seeded() do dir, store, chain, copy
        w = @inferred write_builder(copy)
        insert_rows!(w, :samples, [(id = 3, label = "c", mass = 3.0)])
        @test @inferred(commit!(w)).slot == 2
    end
end
