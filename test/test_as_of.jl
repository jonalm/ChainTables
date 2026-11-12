using Test
using ChainTables: ChainTables, AbstractObjectStore, Chain, ChainNotFoundError,
    FingerprintMismatchError, LocalCopy, PinnedCopyError, RewrittenChainError,
    TransactionHash, TransportError, WrongChainError, as_of, commit!, create_chain,
    create_table!, column!, head, insert_rows!, is_pinned, primary_key!,
    put_object_if_absent, slot_at, sync!, table, tables, unpin!, update_rows!, write_builder
using ChainTables.Testing: InMemoryObjectStore

include("fixtures/chains.jl")

const CT = ChainTables

# A store whose every fetch of genesis fails: a replay that stops before its first
# checkpoint.
struct AsOfTestNoGenesis <: AbstractObjectStore
    inner::InMemoryObjectStore
end
ChainTables.cache_namespace(s::AsOfTestNoGenesis) = ChainTables.cache_namespace(s.inner)
function ChainTables.fetch_object(s::AsOfTestNoGenesis, key)
    key == slotkey(0) && throw(TransportError("connection reset by peer"))
    return ChainTables.fetch_object(s.inner, key)
end
ChainTables.stat_object(s::AsOfTestNoGenesis, key) = ChainTables.stat_object(s.inner, key)

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

# Samples at slot 1; tags and its twin at slot 2; an update at slot 3.
function commit_three!(copy)
    w = write_builder(copy)
    create_table!(w, :samples) do t
        column!(t, :id, Int64)
        column!(t, :label, String)
        column!(t, :mass, Float64; nullable = true)
        primary_key!(t, :id)
    end
    insert_rows!(w, :samples, SAMPLE_ROWS)
    r1 = commit!(w; comment = "first samples")
    w = write_builder(copy)
    foreach(name -> create_keyed!(w, name), (:tags, :twin))
    r2 = commit!(w)
    w = write_builder(copy)
    update_rows!(w, :samples, [(id = 2, mass = 2.5)])
    return [r1, r2, commit!(w)]
end

function with_seeded(f)
    mktempdir() do dir
        store = InMemoryObjectStore()
        chain = chain_over(store, joinpath(dir, "cache"))
        create_chain(chain)
        with_copy(chain, joinpath(dir, "one")) do copy
            sync!(copy)
            f(dir, store, chain, copy, commit_three!(copy))
        end
    end
    return nothing
end

function with_as_of(f, chain, target; kw...)
    copy = as_of(chain, target; kw...)
    try
        f(copy)
    finally
        close(copy)
    end
    return nothing
end

function plant!(store, key, bytes)
    store.objects[key] = bytes
    store.modified[key] = 0
    return nothing
end

cached(chain, s) = CT.record_path(chain, slotkey(s))

@testset "as_of a slot is a temporary pinned copy that close deletes" begin
    with_seeded() do dir, store, chain, copy, rs
        old = as_of(chain, 1)
        @test old isa LocalCopy && old.temporary && is_pinned(old)
        @test head(old) == (; slot = 1, rs[1].transaction_hash, rs[1].state_fingerprint)
        @test table(old, :samples)[2].mass === missing && tables(old) == ["samples"]
        @test startswith(basename(old.path), "chaintables-as_of-")
        @test_throws PinnedCopyError "pinned" sync!(old)
        @test_throws PinnedCopyError "pinned" write_builder(old)
        close(old)
        @test !ispath(old.path)
        close(old)                                                  # idempotent
        @test_throws ArgumentError "is closed" head(old)
    end
end

@testset "as_of a transaction hash leaves the live copy alone" begin
    with_seeded() do dir, store, chain, copy, rs
        with_as_of(chain, rs[2].transaction_hash) do old
            @test head(old).slot == 2 && tables(old) == ["samples", "tags", "twin"]
        end
        @test head(copy).slot == 3 && !is_pinned(copy)
    end
end

const BAD_TARGETS = [
    (
        name = "a hash's bytes",
        target = rs -> rs[2].transaction_hash.bytes,
        msg = "target is a Vector{UInt8}; give a slot",
    ),
    (
        name = "a fingerprint",
        target = rs -> rs[2].state_fingerprint,
        msg = "a StateFingerprint is not an address",
    ),
    (name = "a negative slot", target = rs -> -1, msg = "as_of: slot -1 is negative"),
    (
        name = "a slot above the head",
        target = rs -> 9,
        msg = "the chain at bkt/p has no slot 9",
    ),
    (
        name = "an unknown hash",
        target = rs -> TransactionHash(zeros(UInt8, 32)),
        msg = "no record of the chain at bkt/p hashes to",
    ),
]

@testset "as_of refuses $(case.name)" for case in BAD_TARGETS
    with_seeded() do dir, store, chain, copy, rs
        @test_throws ArgumentError case.msg as_of(chain, case.target(rs))
    end
end

@testset "as_of a prefix with no slot 0 is ChainNotFoundError" begin
    with_seeded() do dir, store, chain, copy, rs
        none = chain_over(store, chain.cache.dir, "none")
        @test_throws ChainNotFoundError "no chain" as_of(none, 0)
        @test_throws ChainNotFoundError "no chain" as_of(none, 2)
        msg = "no chain"
        @test_throws ChainNotFoundError msg as_of(none, TransactionHash(zeros(UInt8, 32)))
    end
end

@testset "as_of leaves no directory where it failed before a checkpoint" begin
    with_seeded() do dir, store, chain, copy, rs
        refused = joinpath(dir, "refused")
        @test_throws ArgumentError "has no slot 9" as_of(chain, 9; path = refused)
        @test !ispath(refused)
        with_as_of(a -> nothing, chain, 1; path = refused)
        cold = chain_over(AsOfTestNoGenesis(store), joinpath(dir, "cold"))
        cut = joinpath(dir, "cut")
        @test_throws TransportError "connection reset by peer" as_of(cold, 1; path = cut)
        @test !ispath(cut)
    end
end

@testset "as_of reopens a given path pinned at the target, asking only for its slot" begin
    with_seeded() do dir, store, chain, copy, rs
        path = joinpath(dir, "pinned")
        with_as_of(chain, 2; path) do a
            @test !a.temporary && a.path == abspath(path) && is_pinned(a)
        end
        head_bytes = read(joinpath(path, "heads", "000000000002"))
        n = length(store.calls)
        with_as_of(chain, 2; path) do a
            @test head(a).slot == 2
            @test read(joinpath(path, "heads", "000000000002")) == head_bytes
            @test store.calls[(n + 1):end] == [(:fetch_object, slotkey(2))]
        end
        @test isfile(joinpath(path, "pin"))
    end
end

@testset "as_of replays a given path pinned below the target forward" begin
    with_seeded() do dir, store, chain, copy, rs
        path = joinpath(dir, "pinned")
        with_as_of(a -> nothing, chain, 1; path)
        with_as_of(chain, 3; path) do a
            @test head(a).slot == 3 && is_pinned(a) && table(a, :samples)[2].mass == 2.5
        end
    end
end

@testset "as_of refuses a path pinned above the target, or live" begin
    with_seeded() do dir, store, chain, copy, rs
        path = joinpath(dir, "pinned")
        with_as_of(a -> nothing, chain, 3; path)
        msg = "is pinned at slot 3, above 1"
        @test_throws ArgumentError msg as_of(chain, 1; path)
        @test isfile(joinpath(path, "pin"))
        msg = "as_of: the local copy at $(copy.path) is live (slot 3)"
        @test_throws ArgumentError msg as_of(chain, 1; path = copy.path)
        @test !is_pinned(copy) && head(copy).slot == 3
    end
end

@testset "as_of and unpin! make a copy live that sync! advances" begin
    with_seeded() do dir, store, chain, copy, rs
        with_as_of(chain, 1; path = joinpath(dir, "unpin")) do a
            @test unpin!(a) === nothing && !is_pinned(a)
            @test sync!(a) == (; applied = 2, slot = 3, rs[3].transaction_hash)
        end
        t = as_of(chain, 1)
        unpin!(t)
        close(t)
        @test !ispath(t.path)                                     # temporary regardless
    end
end

@testset "as_of verifies the record it builds to" begin
    with_seeded() do dir, store, chain, copy, rs
        lie = with_fingerprint(store.objects[slotkey(2)], 2, fill(0xee, 32))
        plant!(store, slotkey(2), lie)
        write(cached(chain, 2), lie)
        tmp = joinpath(dir, "tmp")
        mkdir(tmp)
        err = withenv("TMPDIR" => tmp) do
            (@test_throws FingerprintMismatchError "differs" as_of(chain, 2)).value
        end
        @test err.slot == 2
        # the temporary copy is gone
        @test isempty(readdir(tmp))
    end
end

# A pinned copy whose head names a record with a lying fingerprint, as a copy built on
# that record would carry.
function pin_onto_lie!(path, lie)
    file = joinpath(path, "heads", "000000000003")
    h = CT.decode_head(read(file))
    rm(file)
    th = CT.Ops.transaction_hash(lie)
    lying = CT.Head(
        h.chain_id, h.format_version, 3, th, h.state_fingerprint, h.tables,
        h.written_at_ms, h.written_by
    )
    write(file, CT.encode_head(lying))
    return nothing
end

@testset "as_of verifies the record a reopened path claims" begin
    with_seeded() do dir, store, chain, copy, rs
        path = joinpath(dir, "pinned")
        with_as_of(a -> nothing, chain, 3; path)
        lie = with_fingerprint(store.objects[slotkey(3)], 3, fill(0xee, 32))
        plant!(store, slotkey(3), lie)
        write(cached(chain, 3), lie)
        @test_throws RewrittenChainError "contradicts" as_of(chain, 3; path)
        pin_onto_lie!(path, lie)
        msg = "disagrees"
        err = (@test_throws FingerprintMismatchError msg as_of(chain, 3; path)).value
        @test (err.slot, err.expected) == (3, fill(0xee, 32))
        @test isdir(path)                                         # a given path is kept
    end
end

@testset "as_of refuses a path bound to another chain" begin
    with_seeded() do dir, store, chain, copy, rs
        path = joinpath(dir, "pinned")
        with_as_of(a -> nothing, chain, 1; path)
        chainq = Chain("bkt", "q"; store, cache_dir = joinpath(dir, "qcache"))
        create_chain(chainq)
        @test_throws WrongChainError "another chain" as_of(chainq, 0; path)
        @test_throws WrongChainError "another chain" as_of(chainq, 0; path = copy.path)
    end
end

@testset "as_of infers" begin
    with_seeded() do dir, store, chain, copy, rs
        with_as_of(a -> nothing, chain, 1)
        old = @inferred as_of(chain, 1)
        close(old)
        @test !ispath(old.path)
    end
end

const TIMES = [10, 100, 50, 200, 150]

function with_timed_chain(f)
    mktempdir() do dir
        store = InMemoryObjectStore()
        records = forged_chain(rand(UInt8, 16), 4; times = s -> TIMES[s + 1]).records
        foreach(s -> put_object_if_absent(store, slotkey(s, "t"), records[s + 1]), 0:4)
        f(dir, store, chain_over(store, joinpath(dir, "cache"), "t"))
    end
    return nothing
end

const SLOT_AT_CASES = [
    (time_ms = 10, slot = 0), (time_ms = 49, slot = 0), (time_ms = 50, slot = 2),
    (time_ms = 99, slot = 2), (time_ms = 100, slot = 2), (time_ms = 149, slot = 2),
    (time_ms = 150, slot = 4), (time_ms = 200, slot = 4), (time_ms = 10^12, slot = 4),
]

@testset "slot_at is the last slot at or before $(case.time_ms)" for case in SLOT_AT_CASES
    with_timed_chain() do dir, store, chain
        @test slot_at(chain, case.time_ms) === Int64(case.slot)
    end
end

@testset "slot_at refuses a time before genesis, or not an Integer" begin
    with_timed_chain() do dir, store, chain
        msg = "slot_at: 9 is before the genesis, at 10"
        @test_throws ArgumentError msg slot_at(chain, 9)
        msg = "time_ms is a Float64, not an Integer"
        @test_throws ArgumentError msg slot_at(chain, 1.5)
        none = chain_over(store, chain.cache.dir, "none")
        @test_throws ChainNotFoundError "no chain" slot_at(none, 5)
    end
end

@testset "slot_at gives as_of the slot to build" begin
    with_timed_chain() do dir, store, chain
        with_as_of(chain, slot_at(chain, 99)) do old
            @test head(old).slot == 2 && table(old, :samples)[2].v == "2"
        end
    end
end

const SCANS = [
    (name = "slot_at", scan = chain -> slot_at(chain, 10^12)),
    (
        name = "as_of a hash",
        scan = chain -> as_of(chain, TransactionHash(zeros(UInt8, 32))),
    ),
]

@testset "$(case.name) raises for a slot gone after the probe" for case in SCANS
    with_timed_chain() do dir, store, chain
        store.fault = (verb, key, phase) -> verb === :fetch_object &&
            key == slotkey(3, "t") && phase === :before && delete!(store.objects, key)
        cold = chain_over(store, joinpath(dir, "cold"), "t")
        err = (@test_throws RewrittenChainError "absent now" case.scan(cold)).value
        @test (err.slot, err.found) == (3, nothing)
    end
end

@testset "slot_at infers" begin
    with_timed_chain() do dir, store, chain
        @test @inferred(slot_at(chain, 10)) == 0
    end
end
