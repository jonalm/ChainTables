using Test
using ChainTables: ChainTables, Chain, DivergenceError, FingerprintMismatchError,
    RewrittenChainError, StateFingerprint, commit!, create_chain, create_table!, column!,
    delete_rows!, insert_rows!, is_pinned, primary_key!, repair!, sync!, table, tables,
    update_rows!, verify, write_builder
using ChainTables.Testing: InMemoryObjectStore
using SHA: sha256

include("fixtures/chains.jl")
include("fixtures/seeded_chains.jl")

const CT = ChainTables

function table_file(copy, name)
    return joinpath(copy.path, "tables", bytes2hex(Dict(copy.head.tables)[name]))
end

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

cached(chain, s) = CT.record_path(chain, slotkey(s))

head_file(copy) = joinpath(copy.path, "heads", lpad(string(copy.head.slot), 12, '0'))

table_files(copy) = sort(readdir(joinpath(copy.path, "tables")))

const REPAIRED = (; slot = 3, files_rewritten = 1, attachments_repaired = 0)

@testset "repair! of a sound copy rewrites nothing" begin
    with_seeded(commit_three!) do dir, store, chain, copy, _
        @test repair!(copy) == (; slot = 3, files_rewritten = 0, attachments_repaired = 0)
    end
end

@testset "repair! rewrites a damaged file in place, head and pin untouched" begin
    with_seeded(commit_three!) do dir, store, chain, copy, _
        file, good = damage!(copy, "samples")
        CT.pin!(copy)
        head_bytes, files = read(head_file(copy)), table_files(copy)
        @test repair!(copy) == REPAIRED
        @test read(file) == good
        @test read(head_file(copy)) == head_bytes && is_pinned(copy)
        @test table_files(copy) == files                       # no temporary left
        @test verify(copy; full = true) === nothing
        @test table(copy, :samples)[2].mass == 2.5
    end
end

@testset "repair! rewrites one file for two tables that share it" begin
    with_seeded(commit_three!) do dir, store, chain, copy, _
        twin = table_file(copy, "tags")
        @test twin == table_file(copy, "twin")
        rm(twin)
        @test repair!(copy) == REPAIRED
        @test bytes2hex(sha256(read(twin))) == basename(twin)
        damage!(copy, "tags")
        damage!(copy, "samples")
        @test repair!(copy).files_rewritten == 2
        @test verify(copy) === nothing
    end
end

@testset "repair! fetches a record the cache lacks" begin
    with_seeded(commit_three!) do dir, store, chain, copy, _
        rm(cached(chain, 1))
        damage!(copy, "samples")
        n = length(store.calls)
        @test repair!(copy) == REPAIRED
        @test isfile(cached(chain, 1))
        @test store.calls[(n + 1):end] == [(:fetch_object, slotkey(1))]
    end
end

@testset "repair! replaces a damaged cached record with the store's" begin
    with_seeded(commit_three!) do dir, store, chain, copy, _
        two = read(cached(chain, 2))
        write(cached(chain, 2), flipped(two))
        damage!(copy, "samples")
        n = length(store.calls)
        @test repair!(copy) == REPAIRED
        @test read(cached(chain, 2)) == two
        @test store.calls[(n + 1):end] == [(:fetch_object, slotkey(2))]
    end
end

@testset "repair! writes nothing when the store's record does not hash as named" begin
    with_seeded(commit_three!) do dir, store, chain, copy, _
        two = read(cached(chain, 2))
        write(cached(chain, 2), b"cached damage")
        plant!(store, slotkey(2), flipped(two))
        file, _ = damage!(copy, "samples")
        damaged = read(file)
        msg = "the store's record is not the one slot 3 names"
        err = (@test_throws RewrittenChainError msg repair!(copy)).value
        @test err.slot == 2 && err.expected == CT.Ops.transaction_hash(two)
        @test err.found == CT.Ops.transaction_hash(flipped(two))
        @test read(file) == damaged
        @test read(cached(chain, 2)) == b"cached damage"
    end
end

@testset "repair! refuses a copy with no head" begin
    with_seeded(commit_three!) do dir, store, chain, copy, _
        with_copy(chain, joinpath(dir, "fresh")) do fresh
            msg = "repair!(copy): the local copy at $(fresh.path) has no head yet"
            @test_throws ArgumentError msg repair!(fresh)
        end
    end
end

# A self-consistent head the replay does not reproduce: one that omits tags and twin.
function write_lying_head!(copy)
    h = copy.head
    kept = filter(p -> first(p) == "samples", h.tables)
    lying = CT.Head(
        h.chain_id, h.format_version, h.slot, h.transaction_hash,
        CT.state_fingerprint(kept), kept, h.written_at_ms, h.written_by
    )
    file = head_file(copy)
    rm(file)
    write(file, CT.encode_head(lying))
    return lying
end

@testset "repair! throws DivergenceError for a head the replay does not reproduce" begin
    with_seeded(commit_three!) do dir, store, chain, copy, _
        h = copy.head
        close(copy)
        lying = write_lying_head!(copy)
        with_copy(chain, copy.path) do liar
            @test tables(liar) == ["samples"]
            files = table_files(liar)
            msg = "other tables than the head"
            err = (@test_throws DivergenceError msg repair!(liar)).value
            @test (err.path, err.chain_id, err.slot) == (liar.path, h.chain_id, 3)
            @test err.expected == lying.state_fingerprint
            @test err.computed == CT.state_fingerprint(h.tables)
            @test err.tables == ["tags", "twin"] && err.computed isa StateFingerprint
            @test table_files(liar) == files
            @test read(head_file(liar)) == CT.encode_head(lying)
            @test table(liar, :samples)[2].mass == 2.5
            w = write_builder(liar)
            delete_rows!(w, :samples, [(id = 1,)])
            @test_throws FingerprintMismatchError "disagrees" commit!(w)
            @test !haskey(store.objects, slotkey(4))
        end
    end
end

@testset "repair! infers" begin
    with_seeded(commit_three!) do dir, store, chain, copy, _
        @test @inferred(repair!(copy)).slot == 3
    end
end
