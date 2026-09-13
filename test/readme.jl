# #34 step 10 — the README's worked example as a test (ADR-0019): the same sequence
# against the double, two copies in two temp directories, every commented value
# asserted. Drift between README.md and this file is a bug. The README constructs the
# S3 client; here `Testing.InMemoryObjectStore` stands in and the record cache is kept
# under the temp dir. The guard at the end checks that every `ChainTables.<name>` the
# README's code block names is defined, so a rename cannot leave the README behind.
using Tables
using ChainTables: StaleHeadError, TableView, TransactionHash, StateFingerprint
using ChainTables.Testing: InMemoryObjectStore

@testset "readme" begin
    CT = ChainTables
    caught(f) = try; f(); nothing; catch e; e; end

    @testset "the worked example" begin
        mktempdir() do dir
            store = InMemoryObjectStore()
            # A chain is location and configuration. Constructing it performs no I/O.
            chain = CT.Chain("my-bucket", "experiments/run-7"; region = "eu-north-1", store, cache_dir = joinpath(dir, "cache"))
            @test isempty(store.calls)

            # Only create_chain writes slot 0; a zero-op genesis; no local copy.
            created = CT.create_chain(chain)          # (; chain_id, slot = 0, transaction_hash)
            @test keys(created) == (:chain_id, :slot, :transaction_hash)
            @test created.slot == 0 && created.transaction_hash isa TransactionHash
            @test haskey(store.objects, "experiments/run-7/000000000000")

            # open creates the directory if absent and does no network I/O.
            n = length(store.calls)
            copy = CT.open(chain, joinpath(dir, "data", "run-7"))
            @test isdir(joinpath(dir, "data", "run-7")) && length(store.calls) == n
            @test CT.sync!(copy) == (; applied = 1, slot = 0, transaction_hash = created.transaction_hash)

            # A write builder is a value used once.
            w = CT.write_builder(copy)
            CT.create_table!(w, :samples) do t
                CT.column!(t, :id, Int64)
                CT.column!(t, :label, String)
                CT.column!(t, :mass, Float64; nullable = true)
                CT.primary_key!(t, :id)
            end
            CT.insert_rows!(w, :samples, [
                (id = 1, label = "a", mass = 1.5),
                (id = 2, label = "b", mass = missing),   # missing is null (ADR-0025)
            ])
            r1 = CT.commit!(w; comment = "first samples")
            # (; slot = 1, transaction_hash, state_fingerprint)
            @test keys(r1) == (:slot, :transaction_hash, :state_fingerprint)
            @test r1.slot == 1 && r1.transaction_hash isa TransactionHash && r1.state_fingerprint isa StateFingerprint

            # A second client replays the same records and reaches the same state fingerprint.
            copy2 = CT.open(chain, joinpath(dir, "scratch", "run-7"))
            @test CT.sync!(copy2).applied == 2
            @test CT.head(copy2) == CT.head(copy)
            @test CT.head(copy2).state_fingerprint == r1.state_fingerprint
            v = CT.table(copy2, :samples)             # TableView fixed at slot 1
            @test v isa TableView && v.slot == 1 && v.transaction_hash == r1.transaction_hash
            @test v[2].mass === missing
            @test Tables.columns(v).label == ["a", "b"]

            # Read, change, write: the record carries the rows found, never the condition.
            w2 = CT.write_builder(copy2)
            CT.update_rows!(w2, :samples, [(id = 2, mass = 2.5)])
            r2 = CT.commit!(w2)
            @test r2.slot == 2
            @test v[2].mass === missing               # a view never moves (ADR-0024)
            @test CT.table(copy2, :samples)[2].mass == 2.5
            @test CT.table(copy2, :samples) !== v

            # The first client is now behind. Commit does not sync; it raises.
            w3 = CT.write_builder(copy)
            CT.delete_rows!(w3, :samples, [(id = 1,)])
            err = caught(() -> CT.commit!(w3))
            @test err isa StaleHeadError
            @test (err.chain_id, err.slot, err.chain_slot) == (created.chain_id, 1, 2)
            msg = sprint(showerror, err)
            @test occursin("is at slot 1", msg) && occursin("the chain is at slot 2", msg) && occursin("sync!(copy)", msg)
            @test CT.head(copy).slot == 1                # nothing applied, nothing put
            @test length(store.objects) == 3
            @test CT.sync!(copy) == (; applied = 1, slot = 2, transaction_hash = r2.transaction_hash)
            @test CT.table(copy, :samples)[2].mass == 2.5
            # w3 is spent and is never re-run (ADR-0002).
            @test_throws "this builder is spent" CT.commit!(w3)

            # History is addressed by slot or transaction hash, never by time.
            old = CT.as_of(chain, 1)                  # a pinned temporary copy at slot 1
            @test CT.head(old).slot == 1 && CT.ispinned(old) && old.temporary
            @test CT.table(old, :samples)[2].mass === missing
            oldpath = old.path
            close(old)
            @test !ispath(oldpath)
            # and by hash, reaching the same place
            old = CT.as_of(chain, r1.transaction_hash)
            @test CT.head(old) == (; slot = 1, transaction_hash = r1.transaction_hash, state_fingerprint = r1.state_fingerprint)
            close(old)

            # Local integrity is checked on demand and never healed silently.
            @test CT.verify(copy) === nothing
            @test CT.verify(copy2) === nothing
            close(copy); close(copy2)
            @test_throws "is closed" CT.head(copy)
        end
    end

    # Every `ChainTables.<name>` the README's code block calls must exist: the example is
    # the front door, and a rename that leaves it behind is drift.
    @testset "every name the README calls is defined" begin
        readme = read(joinpath(@__DIR__, "..", "README.md"), String)
        m = match(r"```julia\n(.*?)```"s, readme)
        @test m !== nothing
        block = m.captures[1]
        called = unique(Symbol(x.captures[1]) for x in eachmatch(r"ChainTables\.([A-Za-z_][A-Za-z0-9_]*!?)", block))
        @test :Chain in called && :create_chain in called && :commit! in called && :as_of in called
        for name in called
            @test isdefined(CT, name)
            @test Base.Docs.hasdoc(CT, name)
        end
    end
end
