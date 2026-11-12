using Test
using ChainTables: ChainTables, AttachmentAbsentError, Chain, StaleHeadError, TableView,
    TransactionHash, StateFingerprint, as_of, attachment, column!, commit!, commit_log,
    create_chain, create_table!, delete_rows!, head, insert_rows!, is_pinned, primary_key!,
    put_attachment, repair!, sync!, table, table_with_slots, touch_attachment,
    update_rows!, verify, write_builder
using ChainTables.Testing: InMemoryObjectStore
using SHA: sha256
using StableRNGs: StableRNG
using Tables: Tables

# The README's worked example, with the in-memory store in place of the S3 client and the
# record cache under a temporary directory. Each commented value in the README is asserted
# here; drift between README.md and this file is a bug.

function readme_chain(dir)
    store = InMemoryObjectStore()
    cache_dir = joinpath(dir, "cache")
    chain = Chain("my-bucket", "experiments/run-7"; region = "eu-north-1", store, cache_dir)
    return chain, store
end

function create_samples!(w)
    create_table!(w, :samples) do t
        column!(t, :id, Int64)
        column!(t, :label, String)
        column!(t, :mass, Float64; nullable = true)
        primary_key!(t, :id)
    end
    rows = [(id = 1, label = "a", mass = 1.5), (id = 2, label = "b", mass = missing)]
    insert_rows!(w, :samples, rows)
    return nothing
end

# The README's first steps: a chain, its genesis, and a copy with the samples table.
function with_readme_start(f)
    mktempdir() do dir
        chain, store = readme_chain(dir)
        created = create_chain(chain)
        copy = ChainTables.open(chain, joinpath(dir, "data", "run-7"))
        sync!(copy)
        w = write_builder(copy)
        create_samples!(w)
        r1 = commit!(w; comment = "first samples")
        copy2 = ChainTables.open(chain, joinpath(dir, "scratch", "run-7"))
        sync!(copy2)
        try
            f(chain, store, copy, copy2, (; created, r1))
        finally
            close(copy)
            close(copy2)
        end
    end
    return nothing
end

@testset "README: a chain does no I/O, and create_chain returns no local copy" begin
    mktempdir() do dir
        chain, store = readme_chain(dir)
        @test isempty(store.calls)
        created = create_chain(chain)            # (; chain_id, slot = 0, transaction_hash)
        @test keys(created) == (:chain_id, :slot, :transaction_hash)
        @test created.slot == 0 && created.transaction_hash isa TransactionHash
        n = length(store.calls)
        copy = ChainTables.open(chain, joinpath(dir, "data", "run-7"))
        @test isdir(joinpath(dir, "data", "run-7")) && length(store.calls) == n
        @test sync!(copy) == (; applied = 1, slot = 0, created.transaction_hash)
        close(copy)
    end
end

@testset "README: commit! returns the slot, hash and fingerprint" begin
    with_readme_start() do chain, store, copy, copy2, rs
        # (; slot = 1, transaction_hash, state_fingerprint)
        @test rs.r1.slot == 1
        @test rs.r1.transaction_hash isa TransactionHash
        @test rs.r1.state_fingerprint isa StateFingerprint
    end
end

@testset "README: a second client reaches the same state fingerprint" begin
    with_readme_start() do chain, store, copy, copy2, rs
        @test head(copy2) == head(copy)          # sync! applied = 2
        @test head(copy2).state_fingerprint == rs.r1.state_fingerprint
        v = table(copy2, :samples)               # TableView fixed at slot 1
        @test v isa TableView && v.slot == 1
        @test v[2].mass === missing
        @test Tables.columns(v).label == ["a", "b"]
    end
end

@testset "README: read, change, write; a view never moves" begin
    with_readme_start() do chain, store, copy, copy2, rs
        v = table(copy2, :samples)
        w2 = write_builder(copy2)
        update_rows!(w2, :samples, [(id = 2, mass = 2.5)])
        @test commit!(w2).slot == 2
        @test v[2].mass === missing              # still missing
        @test table_with_slots(table(copy2, :samples))._slot == [1, 2]
        @test table(copy2, :samples)[2].mass == 2.5
    end
end

@testset "README: the client behind raises StaleHeadError, then syncs" begin
    with_readme_start() do chain, store, copy, copy2, rs
        w2 = write_builder(copy2)
        update_rows!(w2, :samples, [(id = 2, mass = 2.5)])
        r2 = commit!(w2)
        w3 = write_builder(copy)
        delete_rows!(w3, :samples, [(id = 1,)])
        err = (@test_throws StaleHeadError "behind the chain" commit!(w3)).value
        @test (err.chain_id, err.slot, err.chain_slot) == (rs.created.chain_id, 1, 2)
        @test head(copy).slot == 1 && length(store.objects) == 3
        @test sync!(copy) == (; applied = 1, slot = 2, r2.transaction_hash)
        @test_throws ChainTables.WriteBuilderError "this builder is spent" commit!(w3)
    end
end

@testset "README: history is addressed by slot or transaction hash" begin
    with_readme_start() do chain, store, copy, copy2, rs
        old = as_of(chain, 1)                    # a pinned temporary copy at slot 1
        @test head(old).slot == 1 && is_pinned(old) && old.temporary
        @test table(old, :samples)[2].mass === missing
        close(old)
        @test !ispath(old.path)
        old = as_of(chain, rs.r1.transaction_hash)
        @test head(old) == (; slot = 1, rs.r1.transaction_hash, rs.r1.state_fingerprint)
        close(old)
    end
end

@testset "README: commit_log and verify" begin
    with_readme_start() do chain, store, copy, copy2, rs
        w2 = write_builder(copy2)
        update_rows!(w2, :samples, [(id = 2, mass = 2.5)])
        commit!(w2)
        log = commit_log(copy2; last = 2)
        @test [(e.slot, e.comment) for e in log] == [(2, nothing), (1, "first samples")]
        @test verify(copy) === nothing
        @test verify(copy2) === nothing
    end
end

function commit_scans_table!(copy)
    w = write_builder(copy)
    create_table!(w, :scans) do t
        column!(t, :id, Int64)
        column!(t, :file, String)
        primary_key!(t, :id)
    end
    return commit!(w)
end

# A chain with a scans table, and a scan file of random bytes beside it.
function readme_scans(dir)
    chain, store = readme_chain(dir)
    create_chain(chain)
    copy = ChainTables.open(chain, joinpath(dir, "data", "run-7"))
    sync!(copy)
    commit_scans_table!(copy)
    bytes = rand(StableRNG(1), UInt8, 1000)
    scan = joinpath(dir, "scan.tif")
    write(scan, bytes)
    return (; chain, store, copy, bytes, scan)
end

@testset "README: attachments" begin
    mktempdir() do dir
        (; chain, store, copy, bytes, scan) = readme_scans(dir)
        h = put_attachment(chain, scan)
        @test h == bytes2hex(sha256(bytes))
        @test haskey(store.objects, "experiments/run-7/_attachments/" * h)
        w = write_builder(copy)
        insert_rows!(w, :scans, [(id = 1, file = h)])
        commit!(w)
        @test touch_attachment(chain, h) === nothing     # nothing, or AttachmentAbsentError
        msg = "no such attachment"
        @test_throws AttachmentAbsentError msg touch_attachment(chain, "0"^64)
        copy2 = ChainTables.open(chain, joinpath(dir, "scratch", "run-7"))
        sync!(copy2)
        path = attachment(copy2, table(copy2, :scans)[1].file)
        @test read(path) == bytes && startswith(path, joinpath(dir, "cache", "attachments"))
        @test verify(copy2; full = true) === nothing     # nothing, or AttachmentCacheError
        @test repair!(copy2).attachments_repaired == 0
        close(copy)
        close(copy2)
    end
end

# Every `ChainTables.<name>` the README's code blocks call must exist and be documented:
# the example is the front door, and a rename that leaves it behind is drift.
function readme_names()
    readme = replace(read(joinpath(@__DIR__, "..", "README.md"), String), "\r\n" => "\n")
    blocks = [m.captures[1] for m in eachmatch(r"```julia\n(.*?)```"s, readme)]
    pattern = r"ChainTables\.([A-Za-z_][A-Za-z0-9_]*!?)"
    return unique(Symbol(x.captures[1]) for b in blocks for x in eachmatch(pattern, b))
end

const README_NAMES = readme_names()

@testset "README calls the main names" begin
    @test :Chain in README_NAMES && :create_chain in README_NAMES
    @test :commit! in README_NAMES
    @test :put_attachment in README_NAMES && :attachment in README_NAMES
end

@testset "README name $name is defined and documented" for name in README_NAMES
    @test isdefined(ChainTables, name)
    @test Docs.hasdoc(ChainTables, name)
end
