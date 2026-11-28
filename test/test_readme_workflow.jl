# The README's worked example as a test (ADR-0019): the same calls against the in-memory
# store, with two local copies in a temporary directory, and every value the README's
# comments give asserted. The README builds an S3 store; `InMemoryObjectStore` stands
# in, and the record cache is in the temporary directory. A change to the README's
# example changes this file too.
using Test
using ChainTables: ChainTables, AttachmentAbsentError, Chain, StaleHeadError,
    StateFingerprint, TableView, TransactionHash, WriteBuilderError, as_of, attachment,
    column!, commit!, commit_log, create_chain, create_table!, delete_rows!, head,
    insert_rows!, is_pinned, primary_key!, put_attachment, repair!, sync!, table,
    table_with_slots, touch_attachment, update_rows!, verify, write_builder
using ChainTables.Testing: InMemoryObjectStore
using SHA: sha256
using StableRNGs: StableRNG
using Tables: Tables

const README = joinpath(@__DIR__, "..", "README.md")
const PREFIX = "experiments/run-7"
const SAMPLES = [(id = 1, label = "a", mass = 1.5), (id = 2, label = "b", mass = missing)]

function readme_chain(dir, store)
    cache_dir = joinpath(dir, "cache")
    return Chain("my-bucket", PREFIX; region = "eu-north-1", store, cache_dir)
end

function commit_samples!(local_copy)
    w = write_builder(local_copy)
    create_table!(w, :samples) do t
        column!(t, :id, Int64)
        column!(t, :label, String)
        column!(t, :mass, Float64; nullable = true)
        primary_key!(t, :id)
    end
    insert_rows!(w, :samples, SAMPLES)
    return commit!(w; comment = "first samples")
end

function update_mass!(local_copy)
    w = write_builder(local_copy)
    update_rows!(w, :samples, [(id = 2, mass = 2.5)])
    return commit!(w)
end

# The README up to its second client: a chain with the samples committed from `copy`
# and replayed by `copy2`.
function with_readme_copies(f)
    return mktempdir() do dir
        store = InMemoryObjectStore()
        chain = readme_chain(dir, store)
        created = create_chain(chain)
        local_copy = ChainTables.open(chain, joinpath(dir, "data", "run-7"))
        sync!(local_copy)
        r1 = commit_samples!(local_copy)
        copy2 = ChainTables.open(chain, joinpath(dir, "scratch", "run-7"))
        applied = sync!(copy2).applied
        try
            return f((; dir, store, chain, created, copy = local_copy, copy2, r1, applied))
        finally
            close(local_copy)
            close(copy2)
        end
    end
end

function commit_scans!(local_copy)
    w = write_builder(local_copy)
    create_table!(w, :scans) do t
        column!(t, :id, Int64)
        column!(t, :file, String)
        primary_key!(t, :id)
    end
    return commit!(w)
end

function insert_scan!(local_copy, hash)
    w = write_builder(local_copy)
    insert_rows!(w, :scans, [(id = 1, file = hash)])
    return commit!(w)
end

# The README's attachments block: a scan stored and named by a row committed from the
# first copy; `copy2` is a second copy, synced.
function with_scan(f)
    return mktempdir() do dir
        store = InMemoryObjectStore()
        chain = readme_chain(dir, store)
        create_chain(chain)
        local_copy = ChainTables.open(chain, joinpath(dir, "data", "run-7"))
        sync!(local_copy)
        commit_scans!(local_copy)
        bytes = rand(StableRNG(1), UInt8, 1000)
        scan = joinpath(dir, "scan.tif")
        write(scan, bytes)
        hash = put_attachment(chain, scan)
        insert_scan!(local_copy, hash)
        copy2 = ChainTables.open(chain, joinpath(dir, "scratch", "run-7"))
        sync!(copy2)
        try
            return f((; dir, store, chain, bytes, hash, copy = local_copy, copy2))
        finally
            close(local_copy)
            close(copy2)
        end
    end
end

function readme_code_blocks()
    text = replace(read(README, String), "\r\n" => "\n")  # a CRLF checkout
    return [m.captures[1] for m in eachmatch(r"```julia\n(.*?)```"s, text)]
end

function names_called(blocks)
    pattern = r"ChainTables\.([A-Za-z_][A-Za-z0-9_]*!?)"
    return unique(Symbol(m.captures[1]) for b in blocks for m in eachmatch(pattern, b))
end

const CALLED = names_called(readme_code_blocks())

@testset "Chain makes no request when it is built" begin
    mktempdir() do dir
        store = InMemoryObjectStore()
        readme_chain(dir, store)
        @test isempty(store.calls)
    end
end

@testset "create_chain writes slot 0 and returns its transaction hash" begin
    mktempdir() do dir
        store = InMemoryObjectStore()
        created = create_chain(readme_chain(dir, store))
        @test keys(created) == (:chain_id, :slot, :transaction_hash)
        @test created.slot == 0
        @test created.transaction_hash isa TransactionHash
        @test haskey(store.objects, PREFIX * "/000000000000")
    end
end

@testset "open makes the directory without a request, and sync! applies the genesis" begin
    mktempdir() do dir
        store = InMemoryObjectStore()
        chain = readme_chain(dir, store)
        created = create_chain(chain)
        n_calls = length(store.calls)
        path = joinpath(dir, "data", "run-7")
        local_copy = ChainTables.open(chain, path)
        @test isdir(path)
        @test length(store.calls) == n_calls
        expected = (; applied = 1, slot = 0, transaction_hash = created.transaction_hash)
        @test sync!(local_copy) == expected
        close(local_copy)
    end
end

@testset "commit! returns the slot, the transaction hash and the state fingerprint" begin
    with_readme_copies() do readme
        @test keys(readme.r1) == (:slot, :transaction_hash, :state_fingerprint)
        @test readme.r1.slot == 1
        @test readme.r1.transaction_hash isa TransactionHash
        @test readme.r1.state_fingerprint isa StateFingerprint
    end
end

@testset "sync! of a second copy replays to the same head" begin
    with_readme_copies() do readme
        @test readme.applied == 2
        @test head(readme.copy2) == head(readme.copy)
        @test head(readme.copy2).state_fingerprint == readme.r1.state_fingerprint
    end
end

@testset "table returns a view fixed at the head" begin
    with_readme_copies() do readme
        v = table(readme.copy2, :samples)
        @test v isa TableView
        @test v.slot == 1
        @test v.transaction_hash == readme.r1.transaction_hash
        @test v[2].mass === missing
        @test Tables.columns(v).label == ["a", "b"]
    end
end

@testset "update_rows! commits a change that an earlier view does not see" begin
    with_readme_copies() do readme
        v = table(readme.copy2, :samples)
        @test update_mass!(readme.copy2).slot == 2
        @test v[2].mass === missing
        @test table_with_slots(table(readme.copy2, :samples))._slot == [1, 2]
        @test table(readme.copy2, :samples)[2].mass == 2.5
        @test table(readme.copy2, :samples) !== v
    end
end

@testset "commit! from a copy behind the chain throws StaleHeadError" begin
    with_readme_copies() do readme
        update_mass!(readme.copy2)
        w3 = write_builder(readme.copy)
        delete_rows!(w3, :samples, [(id = 1,)])
        err = (@test_throws StaleHeadError "  chain_slot = 2" commit!(w3)).value
        @test (err.chain_id, err.slot, err.chain_slot) == (readme.created.chain_id, 1, 2)
        @test occursin("  slot = 1", sprint(showerror, err))
        @test occursin("sync!(copy)", sprint(showerror, err))
        @test head(readme.copy).slot == 1
        @test length(readme.store.objects) == 3
    end
end

@testset "sync! brings a copy that is behind to the chain's head" begin
    with_readme_copies() do readme
        r2 = update_mass!(readme.copy2)
        expected = (; applied = 1, slot = 2, transaction_hash = r2.transaction_hash)
        @test sync!(readme.copy) == expected
        @test table(readme.copy, :samples)[2].mass == 2.5
    end
end

@testset "commit! refuses a builder that a failed commit spent" begin
    with_readme_copies() do readme
        update_mass!(readme.copy2)
        w3 = write_builder(readme.copy)
        delete_rows!(w3, :samples, [(id = 1,)])
        @test_throws StaleHeadError "behind the chain" commit!(w3)
        sync!(readme.copy)
        @test_throws WriteBuilderError "this builder is spent" commit!(w3)
    end
end

@testset "as_of by slot returns a pinned copy that close deletes" begin
    with_readme_copies() do readme
        update_mass!(readme.copy2)
        old = as_of(readme.chain, 1)
        @test head(old).slot == 1
        @test is_pinned(old)
        @test table(old, :samples)[2].mass === missing
        path = old.path
        close(old)
        @test !ispath(path)
    end
end

@testset "as_of by transaction hash reaches the head of that slot" begin
    with_readme_copies() do readme
        r1 = readme.r1
        old = as_of(readme.chain, r1.transaction_hash)
        expected = (; slot = 1, r1.transaction_hash, r1.state_fingerprint)
        @test head(old) == expected
        close(old)
    end
end

@testset "commit_log lists the copy's records, newest first" begin
    with_readme_copies() do readme
        update_mass!(readme.copy2)
        log = commit_log(readme.copy2; last = 2)
        @test [(e.slot, e.comment) for e in log] == [(2, nothing), (1, "first samples")]
    end
end

@testset "verify returns nothing for the README's two copies" begin
    with_readme_copies() do readme
        @test verify(readme.copy) === nothing
        @test verify(readme.copy2) === nothing
    end
end

@testset "head throws on a closed copy" begin
    with_readme_copies() do readme
        close(readme.copy)
        @test_throws ArgumentError "is closed" head(readme.copy)
    end
end

@testset "put_attachment stores the file under the chain and returns its hash" begin
    with_scan() do scan
        @test scan.hash == bytes2hex(sha256(scan.bytes))
        @test haskey(scan.store.objects, PREFIX * "/_attachments/" * scan.hash)
    end
end

@testset "touch_attachment returns nothing for a stored hash" begin
    with_scan() do scan
        @test touch_attachment(scan.chain, scan.hash) === nothing
    end
end

@testset "touch_attachment throws AttachmentAbsentError for an absent hash" begin
    with_scan() do scan
        absent = "0"^64
        @test_throws AttachmentAbsentError "does not hold the attachment" touch_attachment(
            scan.chain, absent,
        )
    end
end

@testset "sync! fetches no attachment" begin
    with_scan() do scan
        @test isempty(filter(c -> first(c) == :fetch_object_to, scan.store.calls))
    end
end

@testset "attachment returns a read-only file in the shared cache" begin
    with_scan() do scan
        path = attachment(scan.copy2, table(scan.copy2, :scans)[1].file)
        @test read(path) == scan.bytes
        @test startswith(path, joinpath(scan.dir, "cache", "attachments"))
        @test (filemode(path) & 0o222) == 0 || Sys.iswindows()
    end
end

@testset "verify and repair! of the attachment cache find nothing to do" begin
    with_scan() do scan
        attachment(scan.copy2, scan.hash)
        @test verify(scan.copy2; full = true) === nothing
        @test repair!(scan.copy2).attachments_repaired == 0
    end
end

@testset "README calls the names of its worked example" begin
    @testset "$name" for name in [:Chain, :create_chain, :commit!, :as_of]
        @test name in CALLED
    end
    @testset "$name" for name in [:put_attachment, :touch_attachment, :attachment]
        @test name in CALLED
    end
end

@testset "README calls only defined, documented names" begin
    @testset "$name" for name in CALLED
        @test isdefined(ChainTables, name)
        @test Docs.hasdoc(ChainTables, name)
    end
end
