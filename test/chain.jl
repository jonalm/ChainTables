# #34 step 7 — ADR-0019, ADR-0002, ADR-0009, ADR-0010, ADR-0012, ADR-0013, ADR-0014,
# ADR-0007, ADR-0020: Chain, create_chain, sync!, commit!, the retry loop and its
# read-back, galloping, the crash windows, and the taxonomy's commit-side types.
# Everything runs against the double with no credentials.
using ChainTables: Chain, LocalCopy, Model, Ops, TransportError, WriteBuilderError, StaleHeadError, LostRaceError,
    PinnedCopyError, FingerprintMismatchError, RewrittenChainError, ChainNotFoundError, WrongChainError,
    MalformedRecordError, AbstractObjectStore, PutOutcome, put_object_if_absent, fetch_object, stat_object,
    list_objects, record_path
using ChainTables.Testing: InMemoryObjectStore
using ChainTables.Ops: Record, Client, Insert

# A store whose conditional put always says 412 while nothing is ever there: the
# contradictory transport put_record! must give up on.
struct ChainTestPhantom412 <: AbstractObjectStore
    inner::InMemoryObjectStore
end
ChainTables.put_object_if_absent(s::ChainTestPhantom412, key, bytes) = PutOutcome(false, 412)
ChainTables.fetch_object(s::ChainTestPhantom412, key) = fetch_object(s.inner, key)
ChainTables.stat_object(s::ChainTestPhantom412, key) = stat_object(s.inner, key)
# A store that reports a refused put with a status the port does not allow.
struct ChainTestBadOutcome <: AbstractObjectStore end
ChainTables.put_object_if_absent(::ChainTestBadOutcome, key, bytes) = PutOutcome(false, 200)

@testset "chain" begin
    CT = ChainTables
    hex = bytes2hex
    caught(f) = try; f(); nothing; catch e; e; end
    # every test builds its own store, cache and copies under one temp dir
    function fixture(dir; prefix = "p", kw...)
        store = InMemoryObjectStore()
        chain = Chain("bkt", prefix; store, cache_dir = joinpath(dir, "cache"), record_host = false, record_user = false, kw...)
        return store, chain
    end
    declare!(w, name = :samples) = CT.create_table!(w, name) do t
        CT.column!(t, :id, Int64)
        CT.column!(t, :label, String)
        CT.column!(t, :mass, Float64; nullable = true)
        CT.primary_key!(t, :id)
    end
    rows_of(copy, name) = collect(Model.rows_in_key_order(CT.load_table!(copy, name)))
    heads(copy) = sort(readdir(joinpath(copy.path, "heads")))
    tabs(copy) = sort(readdir(joinpath(copy.path, "tables")))
    puts(store, key) = count(==((:put_object_if_absent, key)), store.calls)
    slotkey(s) = "p/" * lpad(string(s), 12, '0')
    # an object placed in the double behind the port's back, as an actor outside the protocol would
    plant!(store, key, bytes) = (store.objects[key] = bytes; store.modified[key] = 0; nothing)
    # a chain with genesis and one committed table, and a copy at its head
    function seeded(dir; kw...)
        store, chain = fixture(dir; kw...)
        CT.create_chain(chain)
        copy = CT.open(chain, joinpath(dir, "one"))
        CT.sync!(copy)
        w = CT.write_builder(copy)
        declare!(w)
        CT.insert_rows!(w, :samples, [(id = 1, label = "a", mass = 1.5), (id = 2, label = "b", mass = missing)])
        CT.commit!(w; comment = "first samples")
        return store, chain, copy
    end

    # ------------------------------------------------------------------------
    # Chain is location and configuration, no I/O (ADR-0019, ADR-0010, ADR-0011)
    # ------------------------------------------------------------------------
    @testset "Chain" begin
        store = InMemoryObjectStore()
        chain = Chain("bkt", "exp/run-7"; store, cache_dir = "/c", region = "eu-north-1")
        @test chain isa Chain{InMemoryObjectStore}
        @test (chain.bucket, chain.prefix, chain.region) == ("bkt", "exp/run-7", "eu-north-1")
        @test chain.read_ahead == 8 && !chain.assume_first_writer_wins && !chain.path_style
        @test chain.endpoint === nothing && chain.credentials === nothing
        @test chain.record_host && chain.record_user
        @test chain.cache.dir == "/c"
        @test isempty(store.calls)                                   # no I/O
        @test CT.slot_key(chain, 7) == "exp/run-7/000000000007"
        @test CT.slot_key(Chain("bkt", ""; store), 7) == "000000000007"
        @test sprint(show, chain) == "Chain(\"bkt\", \"exp/run-7\"; store = InMemoryObjectStore)"
        withenv("CHAINTABLES_CACHE_DIR" => "/elsewhere") do
            @test Chain("bkt", "p"; store).cache.dir == "/elsewhere"
        end
        @test_throws "bucket name \"my.bucket\" contains a dot" Chain("my.bucket", "p"; store)
        @test_throws "the bucket name is empty" Chain("", "p"; store)
        @test_throws "prefix \"/p\" begins or ends with '/'" Chain("bkt", "/p"; store)
        @test_throws "prefix \"p/\" begins or ends with '/'" Chain("bkt", "p/"; store)
        @test_throws "read_ahead is 0" Chain("bkt", "p"; store, read_ahead = 0)
        @test_throws "store = nothing means the S3 client, which is not built yet" Chain("bkt", "p"; region = "eu-north-1")
        @test_throws "store is a Int64, not an AbstractObjectStore" Chain("bkt", "p"; store = 1)
    end

    # ------------------------------------------------------------------------
    # create_chain, open, sync! (ADR-0019, ADR-0002, ADR-0013): the only writer of
    # slot 0; a zero-op genesis; no local copy; a copy binds at its first sync!.
    # ------------------------------------------------------------------------
    @testset "create_chain and the first sync!" begin
        mktempdir() do dir
            store, chain = fixture(dir)
            created = CT.create_chain(chain)
            @test created.slot == 0 && occursin(r"^[A-Z2-7]{26}$", created.chain_id) && length(created.transaction_hash) == 32
            @test collect(keys(store.objects)) == ["p/000000000000"]
            @test store.calls == [(:put_object_if_absent, "p/000000000000")]
            genesis = Ops.decode_record(store.objects["p/000000000000"]; slot = 0)
            @test isempty(genesis.ops) && genesis.prev_hash === nothing && genesis.comment === nothing
            @test CT.chain_id_string(genesis.chain_id) == created.chain_id
            @test genesis.client.host === nothing && genesis.client.user === nothing
            @test genesis.state_fingerprint == Model.state_fingerprint(Model.Content())
            @test Ops.transaction_hash(store.objects["p/000000000000"]) == created.transaction_hash

            # the copy: open does no network I/O; sync! binds it at slot 0
            path = joinpath(dir, "copy")
            copy = CT.open(chain, path)
            @test length(store.calls) == 1
            @test copy.head === nothing
            @test CT.sync!(copy) == (; applied = 1, slot = 0, transaction_hash = created.transaction_hash)
            @test CT.head(copy).slot == 0 && copy.head.chain_id == created.chain_id
            @test CT.tables(copy) == String[]
            @test heads(copy) == ["000000000000"] && tabs(copy) == String[]
            # galloping probed slots 0 and 1 and stopped; the genesis create_chain wrote is in the
            # record cache already (a record of our own is cached like a fetched one), so no fetch
            @test store.calls[2:end] == [(:stat_object, "p/000000000000"), (:stat_object, "p/000000000001")]
            @test isfile(record_path(chain.cache, "bkt", "p/000000000000"))
            # nothing new: applied = 0, one probe, the head's own slot served from the cache
            n = length(store.calls)
            @test CT.sync!(copy) == (; applied = 0, slot = 0, transaction_hash = created.transaction_hash)
            @test store.calls[n+1:end] == [(:stat_object, "p/000000000001")]
            # the chain knows its id from the cached genesis, so open checks a bound copy against it
            @test CT.expected_chain_id(chain) == created.chain_id
            @test CT.expected_chain_id(Chain("bkt", "p"; store, cache_dir = joinpath(dir, "cold"))) === nothing
            close(copy)
            close(CT.open(chain, path))

            # create_chain twice on one prefix: the second loses the race, one put, never retried
            n = length(store.calls)
            err = caught(() -> CT.create_chain(chain))
            @test err isa LostRaceError
            @test sprint(showerror, err) == "LostRaceError: lost race for slot 0 at bkt/p: a chain already exists there " *
                "(chain $(created.chain_id), transaction hash $(hex(created.transaction_hash))). create_chain writes slot 0 " *
                "once and is never retried: open(chain, path) and sync!(copy) to use the existing chain, or create under another prefix."
            @test (err.chain_id, err.slot, err.transaction_hash) == (created.chain_id, 0, created.transaction_hash)
            @test puts(store, "p/000000000000") == 2
            @test store.calls[n+1:end] == [(:put_object_if_absent, "p/000000000000")]   # the read-back came from the cache
            @test Ops.transaction_hash(store.objects["p/000000000000"]) == created.transaction_hash
        end
    end

    @testset "sync! on a copy with no head against a prefix with no slot 0" begin
        mktempdir() do dir
            store, chain = fixture(dir)
            copy = CT.open(chain, joinpath(dir, "copy"))
            err = caught(() -> CT.sync!(copy))
            @test err isa ChainNotFoundError
            @test_throws "chain not found: no slot 0 at bkt/p, so there is no chain to sync the local copy at $(copy.path) from" CT.sync!(copy)
            @test_throws "Either the bucket or prefix is not the chain's, or no chain was created there — create_chain(chain) writes slot 0" CT.sync!(copy)
            @test_throws "The two cannot be told apart from here" CT.sync!(copy)
            @test (err.bucket, err.prefix) == ("bkt", "p")
            @test copy.head === nothing
            # a miss is never cached: the chain created afterwards is seen at once
            CT.create_chain(chain)
            @test CT.sync!(copy).slot == 0
            close(copy)
        end
    end

    # ------------------------------------------------------------------------
    # The README sequence (ADR-0019): two copies, commit, replay, the stale head.
    # ------------------------------------------------------------------------
    @testset "commit!, replay on a second copy, stale head" begin
        mktempdir() do dir
            store, chain = fixture(dir)
            created = CT.create_chain(chain)
            copy = CT.open(chain, joinpath(dir, "one"))
            CT.sync!(copy)
            w = CT.write_builder(copy)
            @test w.copy === copy && w.head == (; slot = 0, transaction_hash = created.transaction_hash)
            @test isempty(w.pending)
            declare!(w)
            CT.insert_rows!(w, :samples, [(id = 1, label = "a", mass = 1.5), (id = 2, label = "b", mass = missing)])
            r1 = CT.commit!(w; comment = "first samples")
            @test r1.slot == 1 && length(r1.transaction_hash) == 32
            @test r1.state_fingerprint == CT.head(copy).state_fingerprint == Model.state_fingerprint(copy.content)
            @test CT.head(copy) == (; slot = 1, transaction_hash = r1.transaction_hash, state_fingerprint = r1.state_fingerprint)
            @test heads(copy) == ["000000000001"] && length(tabs(copy)) == 1
            @test isequal(rows_of(copy, "samples"), [Any[1, "a", 1.5], Any[2, "b", missing]])
            bytes = store.objects["p/000000000001"]
            @test Ops.transaction_hash(bytes) == r1.transaction_hash
            rec = Ops.decode_record(bytes; slot = 1)
            @test rec.prev_hash == created.transaction_hash && rec.comment == "first samples"
            @test rec.state_fingerprint == r1.state_fingerprint && length(rec.ops) == 2
            @test CT.chain_id_string(rec.chain_id) == created.chain_id
            # the record landed with one put and was not fetched back: the read-back is only for a
            # failed put; and it is in the record cache, as every record the copy holds is
            @test puts(store, "p/000000000001") == 1
            @test (:fetch_object, "p/000000000001") ∉ store.calls
            @test read(record_path(chain.cache, "bkt", "p/000000000001")) == bytes
            @test w.spent
            @test_throws "commit!(w): this builder is spent; a builder is used once" CT.commit!(w)

            # a second client replays the same records and reaches the same fingerprint
            copy2 = CT.open(chain, joinpath(dir, "two"))
            @test CT.sync!(copy2) == (; applied = 2, slot = 1, transaction_hash = r1.transaction_hash)
            @test CT.head(copy2) == CT.head(copy)
            @test isequal(rows_of(copy2, "samples"), rows_of(copy, "samples"))
            @test only(tabs(copy2)) == only(tabs(copy))
            w2 = CT.write_builder(copy2)
            CT.update_rows!(w2, :samples, [(id = 2, mass = 2.5)])
            r2 = CT.commit!(w2)
            @test r2.slot == 2
            @test isequal(rows_of(copy2, "samples"), [Any[1, "a", 1.5], Any[2, "b", 2.5]])
            @test Ops.decode_record(store.objects["p/000000000002"]; slot = 2).prev_hash == r1.transaction_hash

            # the first client is behind: commit does not sync, it raises — before anything is applied
            w3 = CT.write_builder(copy)
            CT.delete_rows!(w3, :samples, [(id = 1,)])
            before = (heads(copy), tabs(copy), CT.head(copy), length(store.objects))
            err = caught(() -> CT.commit!(w3))
            @test err isa StaleHeadError
            @test sprint(showerror, err) == "StaleHeadError: stale head: the local copy at $(copy.path) is at slot 1 of chain " *
                "$(created.chain_id), the chain is at slot 2. sync!(copy), recompute the row set against the fresh state, and " *
                "build again with write_builder(copy); this builder is spent and is never re-run (ADR-0002)."
            @test (err.chain_id, err.slot, err.chain_slot) == (created.chain_id, 1, 2)
            @test (heads(copy), tabs(copy), CT.head(copy), length(store.objects)) == before
            @test puts(store, "p/000000000002") == 1                          # copy2's; w3 never put
            @test isequal(rows_of(copy, "samples"), [Any[1, "a", 1.5], Any[2, "b", missing]])
            @test_throws "this builder is spent" CT.commit!(w3)
            @test CT.sync!(copy) == (; applied = 1, slot = 2, transaction_hash = r2.transaction_hash)
            @test isequal(rows_of(copy, "samples"), [Any[1, "a", 1.5], Any[2, "b", 2.5]])
            w4 = CT.write_builder(copy)
            CT.delete_rows!(w4, :samples, [(id = 1,)])
            @test CT.commit!(w4).slot == 3
            @test isequal(rows_of(copy, "samples"), [Any[2, "b", 2.5]])

            # a builder held across a sync! raises at commit!, with no network: the copy moved under it
            w5 = CT.write_builder(copy2)                                       # copy2 is at slot 2
            CT.insert_rows!(w5, :samples, [(id = 3, label = "c", mass = 3.0)])
            @test CT.sync!(copy2).slot == 3
            n = length(store.calls)
            err = caught(() -> CT.commit!(w5))
            @test err isa StaleHeadError
            @test sprint(showerror, err) == "StaleHeadError: stale head: this builder was taken at slot 2 of chain " *
                "$(created.chain_id), and the local copy at $(copy2.path) has since moved to slot 3 (a sync!). The row set " *
                "was computed against a state that has moved: recompute it and build again with write_builder(copy); this " *
                "builder is spent and is never re-run (ADR-0002)."
            @test (err.chain_id, err.slot, err.chain_slot) == (created.chain_id, 2, 3)
            @test length(store.calls) == n
            # every record names its parent by hash (ADR-0002), the chain id in every one (ADR-0006)
            for s in 1:3
                r = Ops.decode_record(store.objects[slotkey(s)]; slot = s)
                @test r.prev_hash == Ops.transaction_hash(store.objects[slotkey(s - 1)])
                @test CT.chain_id_string(r.chain_id) == created.chain_id
            end
            # every applied record is in the cache; the copy's head names it
            @test all(isfile(record_path(chain.cache, "bkt", slotkey(s))) for s in 0:3)
            close(copy); close(copy2)
        end
    end

    # ------------------------------------------------------------------------
    # The state gate at commit! (ADR-0001, ADR-0019, ADR-0025): an error, never a
    # no-op, through apply's own checks; a spent or empty builder; lazy shapes.
    # ------------------------------------------------------------------------
    @testset "the state gate and the builder at commit!" begin
        mktempdir() do dir
            store, chain, copy = seeded(dir)
            before = (heads(copy), tabs(copy), CT.head(copy), length(store.calls), length(store.objects))
            unchanged() = (heads(copy), tabs(copy), CT.head(copy), length(store.objects)) == before[[1, 2, 3, 5]]
            refused(f) = (e = caught(f); e isa WriteBuilderError ? e.msg : e)
            # insert on a present key
            w = CT.write_builder(copy)
            CT.insert_rows!(w, :samples, [(id = 2, label = "dup", mass = 0.0)])
            @test refused(() -> CT.commit!(w)) == "commit!(w): op 1 (insert on \"samples\"): insert names a key that is present: (2,)"
            @test unchanged()
            @test isempty(copy.content) && isempty(copy.loaded)              # the model was dropped and reloads
            @test isequal(rows_of(copy, "samples"), [Any[1, "a", 1.5], Any[2, "b", missing]])
            # update and delete on an absent key; the op index names the one that failed
            w = CT.write_builder(copy)
            CT.delete_rows!(w, :samples, [(id = 1,)])
            CT.update_rows!(w, :samples, [(id = 9, mass = 1.0)])
            @test refused(() -> CT.commit!(w)) == "commit!(w): op 2 (update on \"samples\"): update names a key that is absent: (9,)"
            @test unchanged()
            w = CT.write_builder(copy)
            CT.delete_rows!(w, :samples, [(id = 9,)])
            @test refused(() -> CT.commit!(w)) == "commit!(w): op 1 (delete on \"samples\"): delete names a key that is absent: (9,)"
            @test unchanged()
            @test isequal(rows_of(copy, "samples"), [Any[1, "a", 1.5], Any[2, "b", missing]])
            # no put was attempted by any of them; each cost the pre-check (cached) and one preflight probe
            @test puts(store, "p/000000000002") == 0
            @test count(==((:stat_object, "p/000000000002")), store.calls) == 3
            # an empty builder; a comment that is not text; a builder over bare content
            @test refused(() -> CT.commit!(CT.write_builder(copy))) ==
                "commit!(w): the builder has no ops; a record after genesis carries at least one, and genesis is create_chain's (ADR-0019). Add ops, or do not commit."
            w = CT.write_builder(copy)
            CT.delete_rows!(w, :samples, [(id = 1,)])
            @test refused(() -> CT.commit!(w; comment = 1)) == "commit!(w): comment is a Int64, not text"
            w = CT.write_builder(copy)
            CT.delete_rows!(w, :samples, [(id = 1,)])
            @test refused(() -> CT.commit!(w; comment = "a\0b")) == "commit!(w): comment contains U+0000"
            @test unchanged()
            # a fresh copy has no head to build on
            fresh = CT.open(chain, joinpath(dir, "fresh"))
            @test_throws "write_builder(copy): the local copy at $(fresh.path) has no head yet; sync!(copy) binds it" CT.write_builder(fresh)
            close(fresh)

            # lazy shapes: a reopened copy has nothing loaded; the builder loads a table on
            # first mention and never one it does not name
            close(copy)
            copy = CT.open(chain, copy.path)
            w = CT.write_builder(copy)
            @test w.pending == Set(["samples"]) && isempty(w.scratch) && isempty(copy.loaded)
            CT.create_table!(w, :tags) do t
                CT.column!(t, :k, Vector{UInt8})
                CT.primary_key!(t, :k)
            end
            CT.insert_rows!(w, :tags, [(k = UInt8[1],)])
            @test isempty(copy.loaded)                                         # samples untouched
            @test_throws "create_table!(w, :samples): table \"samples\" already exists" declare!(w)
            @test isempty(copy.loaded)
            CT.insert_rows!(w, :samples, [(id = 3, label = "c", mass = 3.0)])
            @test copy.loaded == Set(["samples"]) && isempty(w.pending) && haskey(w.scratch, "samples")
            @test CT.commit!(w).slot == 2
            @test CT.tables(copy) == ["samples", "tags"]
            @test isequal(rows_of(copy, "samples"), [Any[1, "a", 1.5], Any[2, "b", missing], Any[3, "c", 3.0]])
            # drop_table! on an unread table reads nothing; the name is then free to create
            close(copy)
            copy = CT.open(chain, copy.path)
            w = CT.write_builder(copy)
            CT.drop_table!(w, :tags)
            @test isempty(copy.loaded) && w.pending == Set(["samples"])
            CT.create_table!(w, :tags) do t
                CT.column!(t, :n, Int64)
                CT.primary_key!(t, :n)
            end
            CT.insert_rows!(w, :tags, [(n = 7,)])
            @test_throws "insert_rows!(w, :gone): unknown table \"gone\"" CT.insert_rows!(w, :gone, [(n = 1,)])
            @test CT.commit!(w).slot == 3
            @test rows_of(copy, "tags") == [Any[7]]
            @test_throws "drop_table!(w, :tags)" begin
                w = CT.write_builder(copy)
                CT.drop_table!(w, :tags)
                CT.drop_table!(w, :tags)
            end
            close(copy)
        end
    end

    # ------------------------------------------------------------------------
    # The race, the lost acknowledgement, and the retry loop (ADR-0002, ADR-0010,
    # ADR-0016): the read-back decides the outcome, never the status.
    # ------------------------------------------------------------------------
    @testset "two builders racing for one slot" begin
        mktempdir() do dir
            store, chain, a = seeded(dir)
            b = CT.open(chain, joinpath(dir, "two"))
            CT.sync!(b)
            wa = CT.write_builder(a)
            CT.insert_rows!(wa, :samples, [(id = 3, label = "from a", mass = missing)])
            wb = CT.write_builder(b)
            CT.insert_rows!(wb, :samples, [(id = 4, label = "from b", mass = missing)])
            # b's preflight passes, then a's record lands first — injected as b's put is in flight
            ra = nothing
            store.fault = function (verb, key, phase)
                if verb === :put_object_if_absent && phase === :before && ra === nothing
                    store.fault = (verb, key, phase) -> nothing
                    ra = CT.commit!(wa)
                end
                return nothing
            end
            before = (heads(b), tabs(b), CT.head(b))
            err = caught(() -> CT.commit!(wb))
            @test ra.slot == 2
            @test err isa LostRaceError
            @test sprint(showerror, err) == "LostRaceError: lost race for slot 2 of chain $(a.head.chain_id) at bkt/p: " *
                "another client's record is there (transaction hash $(hex(ra.transaction_hash))). sync!(copy), recompute " *
                "the row set against the fresh state, and build again with write_builder(copy); this builder is spent and " *
                "is never re-run (ADR-0002)."
            @test (err.chain_id, err.slot, err.transaction_hash) == (a.head.chain_id, 2, ra.transaction_hash)
            # one put each; b's read-back was served by the cache, since a's commit cached its own record
            # in the same process-wide cache; b's head and files untouched (the 412 left the head alone)
            @test puts(store, "p/000000000002") == 2
            @test count(==((:fetch_object, "p/000000000002")), store.calls) == 0
            @test (heads(b), tabs(b), CT.head(b)) == before
            @test Ops.transaction_hash(store.objects["p/000000000002"]) == ra.transaction_hash
            @test_throws "this builder is spent" CT.commit!(wb)
            # the read-back cached the winner: b's sync! fetches nothing new from the store
            n = length(store.calls)
            @test CT.sync!(b) == (; applied = 1, slot = 2, transaction_hash = ra.transaction_hash)
            @test (:fetch_object, "p/000000000002") ∉ store.calls[n+1:end]
            @test isequal(rows_of(b, "samples"), [Any[1, "a", 1.5], Any[2, "b", missing], Any[3, "from a", missing]])
            close(a); close(b)
        end
    end

    @testset "lost acknowledgement: the object landed, the response did not" begin
        mktempdir() do dir
            store, chain, copy = seeded(dir)
            w = CT.write_builder(copy)
            CT.insert_rows!(w, :samples, [(id = 3, label = "c", mass = 3.0)])
            store.fault = (verb, key, phase) -> verb === :put_object_if_absent && phase === :after &&
                throw(TransportError("connection reset by peer"))
            r = CT.commit!(w)
            @test r.slot == 2 && CT.head(copy).slot == 2
            @test puts(store, "p/000000000002") == 1                          # never re-issued
            @test count(==((:fetch_object, "p/000000000002")), store.calls) == 1
            @test Ops.transaction_hash(store.objects["p/000000000002"]) == r.transaction_hash
            @test isfile(record_path(chain.cache, "bkt", "p/000000000002"))
            close(copy)
        end
    end

    @testset "the retry rule: 5xx and 409, never 412 or auth 4xx" begin
        @test CT.retryable(TransportError("timeout"))
        @test CT.retryable(TransportError("down"; status = 500)) && CT.retryable(TransportError("slow"; status = 503))
        @test CT.retryable(TransportError("conflict"; status = 409))
        @test !CT.retryable(TransportError("forbidden"; status = 403)) && !CT.retryable(TransportError("bad"; status = 400))
        @test !CT.retryable(TransportError("no"; status = 412)) && !CT.retryable(TransportError("?"; status = 404))
        @test !CT.retryable(ErrorException("not a transport failure"))
        @test sprint(showerror, TransportError("down"; status = 503)) == "TransportError: down (HTTP 503)"
        @test sprint(showerror, TransportError("timeout")) == "TransportError: timeout"
        @test CT.PUT_ATTEMPTS == 4 && length(CT.PUT_BACKOFF_S) == 3
        mktempdir() do dir
            store, chain, copy = seeded(dir)
            # a put that fails twice with a 503, then lands: three puts, one commit
            failures = Ref(2)
            store.fault = function (verb, key, phase)
                if verb === :put_object_if_absent && phase === :before && failures[] > 0
                    failures[] -= 1
                    throw(TransportError("service unavailable"; status = 503))
                end
            end
            w = CT.write_builder(copy)
            CT.insert_rows!(w, :samples, [(id = 3, label = "c", mass = 3.0)])
            @test CT.commit!(w).slot == 2
            @test puts(store, "p/000000000002") == 3
            # a 409 likewise
            failures[] = 1
            store.fault = function (verb, key, phase)
                if verb === :put_object_if_absent && phase === :before && failures[] > 0
                    failures[] -= 1
                    throw(TransportError("conflict"; status = 409))
                end
            end
            w = CT.write_builder(copy)
            CT.insert_rows!(w, :samples, [(id = 4, label = "d", mass = 4.0)])
            @test CT.commit!(w).slot == 3
            @test puts(store, "p/000000000003") == 2
            # an auth 4xx is raised at once: one put, the copy at its head with the model dropped
            store.fault = (verb, key, phase) -> verb === :put_object_if_absent && phase === :before &&
                throw(TransportError("forbidden"; status = 403))
            w = CT.write_builder(copy)
            CT.insert_rows!(w, :samples, [(id = 5, label = "e", mass = 5.0)])
            before = (heads(copy), tabs(copy), CT.head(copy))
            @test_throws TransportError CT.commit!(w)
            @test_throws "forbidden (HTTP 403)" begin
                w = CT.write_builder(copy)
                CT.insert_rows!(w, :samples, [(id = 5, label = "e", mass = 5.0)])
                CT.commit!(w)
            end
            @test puts(store, "p/000000000004") == 2 && !haskey(store.objects, "p/000000000004")
            @test (heads(copy), tabs(copy), CT.head(copy)) == before && isempty(copy.content)
            # every attempt fails: the last failure is raised after PUT_ATTEMPTS puts
            store.fault = (verb, key, phase) -> verb === :put_object_if_absent && phase === :before &&
                throw(TransportError("service unavailable"; status = 503))
            w = CT.write_builder(copy)
            CT.insert_rows!(w, :samples, [(id = 5, label = "e", mass = 5.0)])
            n = puts(store, "p/000000000004")
            @test_throws "service unavailable (HTTP 503)" CT.commit!(w)
            @test puts(store, "p/000000000004") == n + CT.PUT_ATTEMPTS
            @test (heads(copy), tabs(copy), CT.head(copy)) == before
            close(copy)
        end
    end

    @testset "put_record!: the read-back is the authority" begin
        mktempdir() do dir
            store, chain = fixture(dir)
            cache = chain.cache
            ours, theirs = b"our record", b"their record"
            # created
            @test CT.put_record!(store, cache, "bkt", "p/000000000001", ours) === nothing
            # ours already there (a lost acknowledgement seen from the outside): success, no other bytes
            @test CT.put_record!(store, cache, "bkt", "p/000000000001", ours) === nothing
            # theirs there: their bytes come back, and are now cached as the slot's record
            put_object_if_absent(store, "p/000000000002", theirs)
            @test CT.put_record!(store, cache, "bkt", "p/000000000002", ours) == theirs
            @test read(record_path(cache, "bkt", "p/000000000002")) == theirs
            # a 412 with nothing there, every time: given up as a rewritten chain
            phantom = ChainTestPhantom412(store)
            err = caught(() -> CT.put_record!(phantom, cache, "bkt", "p/000000000009", ours))
            @test err isa RewrittenChainError
            @test occursin("refused as existing (412) and a fetch found nothing there, 4 times over", err.msg)
            # a refusal with any status but 412 breaks the port's promise
            @test_throws "returned created = false with status 200; the port promises false only for a 412" CT.put_record!(ChainTestBadOutcome(), cache, "bkt", "k", ours)
        end
    end

    # ------------------------------------------------------------------------
    # Galloping (ADR-0012): O(log) stat probes warm and cold; nothing listed; a
    # miss is never cached, a hit is.
    # ------------------------------------------------------------------------
    @testset "galloping" begin
        store = InMemoryObjectStore()
        keyof(s) = slotkey(s)
        probes(f) = (n = length(store.calls); r = f(); (r, store.calls[n+1:end]))
        # an empty prefix: one probe, nothing found
        @test probes(() -> CT.gallop(store, keyof, -1)) == (-1, [(:stat_object, slotkey(0))])
        for s in 0:999
            store.objects[keyof(s)] = UInt8[]
            store.modified[keyof(s)] = 0
        end
        # cold: about 2 log2 N probes; every one a stat, no listing, no fetch
        top, calls = probes(() -> CT.gallop(store, keyof, -1))
        @test top == 999
        @test length(calls) <= 2 * ceil(Int, log2(1001)) + 1
        @test all(c -> c[1] === :stat_object, calls)
        @test calls[1:4] == [(:stat_object, slotkey(s)) for s in (0, 1, 3, 7)]
        # warm at the head: one probe; a little behind: a few
        @test probes(() -> CT.gallop(store, keyof, 999)) == (999, [(:stat_object, slotkey(1000))])
        top, calls = probes(() -> CT.gallop(store, keyof, 990))
        @test top == 999 && length(calls) <= 2 * ceil(Int, log2(10)) + 1
        # exact: every slot from 0 to 5 present, 6 absent
        small = InMemoryObjectStore()
        for s in 0:5
            put_object_if_absent(small, keyof(s), UInt8[])
        end
        @test CT.gallop(small, keyof, -1) == 5 && CT.gallop(small, keyof, 2) == 5 && CT.gallop(small, keyof, 5) == 5
        # a lone slot 0
        lone = InMemoryObjectStore()
        put_object_if_absent(lone, keyof(0), UInt8[])
        @test CT.gallop(lone, keyof, -1) == 0

        # through sync!: a probe that missed leaves nothing in the cache, and the slot is seen
        # the moment it lands; a fetched record is cached and never fetched again
        mktempdir() do dir
            store, chain, copy = seeded(dir)
            @test !isfile(record_path(chain.cache, "bkt", "p/000000000002"))
            CT.sync!(copy)
            @test !isfile(record_path(chain.cache, "bkt", "p/000000000002"))
            other = CT.open(chain, joinpath(dir, "other"))
            CT.sync!(other)
            w = CT.write_builder(other)
            CT.insert_rows!(w, :samples, [(id = 3, label = "c", mass = 3.0)])
            CT.commit!(w)
            @test CT.sync!(copy).applied == 1
            @test isfile(record_path(chain.cache, "bkt", "p/000000000002"))
            @test (:fetch_object, "p/000000000001") ∉ store.calls               # copy committed it, so it was cached; other's sync came from the cache
            close(copy); close(other)
        end
    end

    # ------------------------------------------------------------------------
    # Rewritten chain (ADR-0014): both symptoms on the head's own slot; a record
    # naming a parent the copy does not hold; a foreign record; the wrong chain.
    # The copy stays readable, nothing heals, and commit refuses.
    # ------------------------------------------------------------------------
    @testset "rewritten chain" begin
        mktempdir() do dir
            store, chain, copy = seeded(dir)
            cid = copy.head.chain_id
            th1 = copy.head.transaction_hash
            key1 = "p/000000000001"
            good = store.objects[key1]
            cached = record_path(chain.cache, "bkt", key1)
            # while the cache holds slot 1, the bucket is not consulted for it (ADR-0010, ADR-0014)
            other = Ops.encode_record(Record(CT.chain_id_bytes(cid), 1, Ops.transaction_hash(store.objects["p/000000000000"]),
                                             copy.head.state_fingerprint, Client(nothing, nothing, "L", "J", 1), "rewritten",
                                             Ops.decode_record(good; slot = 1).ops))
            plant!(store, key1, other)
            @test CT.sync!(copy).applied == 0
            # symptom one: the head's slot fetches bytes of another hash
            rm(cached)
            err = caught(() -> CT.sync!(copy))
            @test err isa RewrittenChainError
            @test sprint(showerror, err) == "RewrittenChainError: rewritten chain: slot 1 of chain $cid at bkt/p holds a record " *
                "hashing to $(hex(Ops.transaction_hash(other))); the local copy at $(copy.path) applied $(hex(th1)) there. The " *
                "bucket was written from outside the protocol and nothing heals it. The local copy stays readable and never " *
                "commits onto this chain."
            @test (err.chain_id, err.slot, err.expected, err.found) == (cid, 1, th1, Ops.transaction_hash(other))
            @test CT.head(copy).slot == 1 && CT.tables(copy) == ["samples"]
            @test isequal(rows_of(copy, "samples"), [Any[1, "a", 1.5], Any[2, "b", missing]])
            @test_throws RewrittenChainError CT.sync!(copy)                    # never healed
            w = CT.write_builder(copy)
            CT.delete_rows!(w, :samples, [(id = 1,)])
            @test_throws RewrittenChainError CT.commit!(w)                     # the pre-check refuses to commit onto it
            @test !haskey(store.objects, "p/000000000002")
            # symptom two: the head's slot is absent
            delete!(store.objects, key1)
            isfile(cached) && rm(cached)
            err = caught(() -> CT.sync!(copy))
            @test err isa RewrittenChainError
            @test sprint(showerror, err) == "RewrittenChainError: rewritten chain: slot 1 — the head of the local copy at " *
                "$(copy.path), chain $cid — is absent at bkt/p. Either the chain was truncated from outside the protocol, or " *
                "this is not the chain's bucket and prefix; neither is healed. The local copy stays readable; open it over the " *
                "chain it was built from, or delete it and sync!(copy) a fresh one."
            @test (err.chain_id, err.slot, err.expected, err.found) == (cid, 1, th1, nothing)
            @test isequal(rows_of(copy, "samples"), [Any[1, "a", 1.5], Any[2, "b", missing]])
            plant!(store, key1, good)
            @test CT.sync!(copy).applied == 0

            # a record above the head naming a parent the copy does not hold
            forged(slot, prev; chain_id = CT.chain_id_bytes(cid), ops = [Insert("samples", [Any[3, "c", 3.0]])]) =
                Ops.encode_record(Record(chain_id, slot, prev, copy.head.state_fingerprint, Client(nothing, nothing, "L", "J", 1), nothing, ops))
            plant!(store, "p/000000000002", forged(2, fill(0xaa, 32)))
            err = caught(() -> CT.sync!(copy))
            @test err isa RewrittenChainError
            @test sprint(showerror, err) == "RewrittenChainError: rewritten chain: slot 2 of chain $cid at bkt/p names parent " *
                "$("aa"^32), the local copy at $(copy.path) holds slot 1 as $(hex(th1)). The chain below was rewritten from " *
                "outside the protocol, or the committer of slot 2 had a bug; nothing heals it. The local copy stays at its last " *
                "checkpoint and readable."
            @test (err.chain_id, err.slot, err.expected, err.found) == (cid, 2, th1, fill(0xaa, 32))
            @test CT.head(copy).slot == 1 && isempty(copy.content)
            rm(record_path(chain.cache, "bkt", "p/000000000002"))
            # a record of another chain written into this prefix
            plant!(store, "p/000000000002", forged(2, th1; chain_id = fill(0x11, 16)))
            err = caught(() -> CT.sync!(copy))
            @test err isa MalformedRecordError
            @test occursin("malformed record at slot 2: it carries chain id $(CT.chain_id_string(fill(0x11, 16))), the chain is $cid", err.msg)
            @test (err.chain_id, err.slot) == (cid, 2)
            @test CT.head(copy).slot == 1
            rm(record_path(chain.cache, "bkt", "p/000000000002"))
            # a slot that vanished between the probe and the fetch
            plant!(store, "p/000000000002", forged(2, th1))
            store.fault = (verb, key, phase) -> verb === :fetch_object && key == "p/000000000002" && phase === :before &&
                delete!(store.objects, key)
            err = caught(() -> CT.sync!(copy))
            @test err isa RewrittenChainError
            @test occursin("slot 2 at bkt/p was there when head discovery probed it and is absent now", err.msg)
            @test (err.chain_id, err.slot, err.found) == (cid, 2, nothing)
            store.fault = (verb, key, phase) -> nothing
            close(copy)

            # the wrong chain: a copy bound to chain p opened over chain q, whose genesis is
            # not cached, passes open (no network) and is caught by the first sync!
            chainq = Chain("bkt", "q"; store, cache_dir = joinpath(dir, "qcache"))
            createdq = CT.create_chain(chainq)
            q = CT.open(chainq, joinpath(dir, "q"))
            CT.sync!(q)
            wq = CT.write_builder(q)
            declare!(wq, :other)
            CT.commit!(wq)
            close(q)
            cold = Chain("bkt", "q"; store, cache_dir = joinpath(dir, "coldcache"))
            wrong = CT.open(cold, copy.path)
            err = caught(() -> CT.sync!(wrong))
            @test err isa WrongChainError
            @test sprint(showerror, err) == "WrongChainError: wrong chain: the local copy at $(copy.path) is bound to chain $cid, " *
                "the chain at bkt/q is $(createdq.chain_id): open a different path for this chain."
            @test (err.path, err.bound, err.opened) == (copy.path, cid, createdq.chain_id)
            @test CT.head(wrong).slot == 1
            close(wrong)
            # with q's genesis cached, open itself refuses
            @test_throws WrongChainError CT.open(chainq, copy.path)
        end
    end

    # ------------------------------------------------------------------------
    # The crash windows (ADR-0009, ADR-0013, ADR-0023) and the amortized checkpoint.
    # ------------------------------------------------------------------------
    @testset "a crash after the put and before the head" begin
        mktempdir() do dir
            store, chain, copy = seeded(dir)
            head1 = read(joinpath(copy.path, "heads", "000000000001"))
            files1 = Dict(f => read(joinpath(copy.path, "tables", f)) for f in tabs(copy))
            w = CT.write_builder(copy)
            CT.insert_rows!(w, :samples, [(id = 3, label = "c", mass = 3.0)])
            r = CT.commit!(w)
            # undo the local commit point and its sweep only: the record is in the chain, the
            # copy is at slot 1 with slot 2's table file an orphan
            rm(joinpath(copy.path, "heads", "000000000002"))
            write(joinpath(copy.path, "heads", "000000000001"), head1)
            for (f, b) in files1
                write(joinpath(copy.path, "tables", f), b)
            end
            close(copy)
            again = CT.open(chain, copy.path)
            @test CT.head(again).slot == 1
            # the next sync! applies our own record as an ordinary one (no authorship special case)
            @test CT.sync!(again) == (; applied = 1, slot = 2, transaction_hash = r.transaction_hash)
            @test CT.head(again).state_fingerprint == r.state_fingerprint
            @test isequal(rows_of(again, "samples"), [Any[1, "a", 1.5], Any[2, "b", missing], Any[3, "c", 3.0]])
            close(again)
        end
    end

    @testset "checkpoints: the amortized rule, a failed sync, read_ahead" begin
        mktempdir() do dir
            store, chain, copy = seeded(dir)
            for i in 3:12
                w = CT.write_builder(copy)
                CT.insert_rows!(w, :samples, [(id = i, label = string(i), mass = Float64(i))])
                CT.commit!(w)
            end
            @test CT.head(copy).slot == 11
            # the rule on a scripted clock, one tick per call: apply takes 1, a checkpoint takes 1,
            # so a checkpoint fires after the first record, then every second one, and at the end
            ticks = Ref(0)
            clock() = (ticks[] += 1)
            fresh = CT.open(chain, joinpath(dir, "fresh"))
            @test CT.replay!(fresh, 0, 11; clock) == (; applied = 12, checkpoints = [0, 2, 4, 6, 8, 10, 11])
            @test CT.head(fresh) == CT.head(copy)
            # a checkpoint costing five applies: the rule waits for six applies' worth before the next one,
            # on a clock scripted for exactly that schedule (a checkpoint anywhere else desynchronises it)
            script = Int[]
            t = 0
            for s in 0:11
                push!(script, t, t + 1); t += 1                        # apply: one tick
                s in (0, 6, 11) && (push!(script, t, t + 5); t += 5)   # checkpoint: five ticks
            end
            scripted() = popfirst!(script)
            close(fresh)
            fresh2 = CT.open(chain, joinpath(dir, "fresh2"))
            @test CT.replay!(fresh2, 0, 11; clock = scripted) == (; applied = 12, checkpoints = [0, 6, 11])
            @test isempty(script)
            @test CT.head(fresh2) == CT.head(copy)
            close(fresh2)

            # a failed sync leaves the copy at its last checkpoint, consistent, and resumes from it;
            # over a cold cache, so the fetch of slot 7 reaches the store and fails there
            store.fault = (verb, key, phase) -> verb === :fetch_object && key == "p/000000000007" && phase === :before &&
                throw(TransportError("timeout"))
            cold = Chain("bkt", "p"; store, cache_dir = joinpath(dir, "cache_cold"))
            failed = CT.open(cold, joinpath(dir, "failed"))
            @test_throws "TransportError: timeout" CT.sync!(failed)
            @test failed.head !== nothing && 0 <= CT.head(failed).slot < 7
            @test isempty(failed.content)
            reached = CT.head(failed)
            close(failed)
            failed = CT.open(cold, failed.path)                         # the checkpoint is what is on disk
            @test CT.head(failed) == reached
            store.fault = (verb, key, phase) -> nothing
            @test CT.sync!(failed) == (; applied = 11 - reached.slot, slot = 11, transaction_hash = copy.head.transaction_hash)
            @test CT.head(failed) == CT.head(copy)
            @test isequal(rows_of(failed, "samples"), rows_of(copy, "samples"))
            close(failed)
            # read_ahead = 1 replays the same chain; the fetches still come one slot at a time in order
            one = Chain("bkt", "p"; store, cache_dir = joinpath(dir, "cache1"), read_ahead = 1)
            c1 = CT.open(one, joinpath(dir, "one_ahead"))
            n = length(store.calls)
            @test CT.sync!(c1).slot == 11
            fetched = [k for (v, k) in store.calls[n+1:end] if v === :fetch_object]
            @test fetched == [slotkey(s) for s in 0:11]
            @test CT.head(c1) == CT.head(copy)
            close(c1)
            # a malformed record mid-replay: the copy stays at its last checkpoint, the chain is dead beyond it
            bad = Ops.encode_record(Record(CT.chain_id_bytes(copy.head.chain_id), 12, copy.head.transaction_hash,
                                           copy.head.state_fingerprint, Client(nothing, nothing, "L", "J", 1), nothing,
                                           [Insert("samples", [Any[13.0, "x", 1.0]])]))
            put_object_if_absent(store, slotkey(12), bad)
            err = caught(() -> CT.sync!(copy))
            @test err isa MalformedRecordError
            @test occursin("malformed record at slot 12: op 1 (insert on \"samples\"): column \"id\" is int64, got a value of type Float64", err.msg)
            @test (err.chain_id, err.slot, err.op) == (copy.head.chain_id, 12, 1)
            @test CT.head(copy).slot == 11 && isempty(copy.content)
            @test isequal(rows_of(copy, "samples")[end], Any[12, "12", 12.0])
            close(copy)
        end
    end

    @testset "a fingerprint the head cannot reproduce (the commit pre-check, ADR-0007)" begin
        mktempdir() do dir
            store, chain, copy = seeded(dir)
            # a record whose state_fingerprint is a lie, applied through a fresh copy: the
            # checkpoint catches it (step 5's test); here the head file is rewritten to disagree
            # with its record, and commit's pre-check refuses to build on it
            h = copy.head
            rec = Ops.decode_record(store.objects["p/000000000001"]; slot = 1)
            lie = Ops.encode_record(Record(rec.chain_id, 1, rec.prev_hash, fill(0xee, 32),
                                           Client(nothing, nothing, "L", "J", rec.client.time_ms), rec.comment, rec.ops))
            plant!(store, "p/000000000001", lie)
            write(record_path(chain.cache, "bkt", "p/000000000001"), lie)
            copy.head = CT.Head(h.chain_id, h.format_version, h.slot, Ops.transaction_hash(lie), h.state_fingerprint, h.tables,
                                h.written_at_ms, h.written_by)
            w = CT.write_builder(copy)
            CT.delete_rows!(w, :samples, [(id = 1,)])
            err = caught(() -> CT.commit!(w))
            @test err isa FingerprintMismatchError
            @test occursin("state fingerprint mismatch at slot 1 (chain $(h.chain_id)): the record's state_fingerprint is $("ee"^32), the head of the local copy at $(copy.path) holds $(hex(h.state_fingerprint))", err.msg)
            @test occursin("written by L on Julia J; this client is ChainTables", err.msg)
            @test occursin("repair!(copy)", err.msg)
            @test (err.chain_id, err.slot, err.expected, err.computed) == (h.chain_id, 1, fill(0xee, 32), h.state_fingerprint)
            @test err.record_client == (; lib = "L", julia = "J") && err.this_client.julia == string(VERSION)
            @test !haskey(store.objects, "p/000000000002")
            close(copy)
        end
    end

    # ------------------------------------------------------------------------
    # A pinned copy (ADR-0015): sync!, write_builder and commit! refuse.
    # ------------------------------------------------------------------------
    @testset "pinned copy" begin
        mktempdir() do dir
            store, chain, copy = seeded(dir)
            w = CT.write_builder(copy)
            CT.delete_rows!(w, :samples, [(id = 1,)])
            touch(joinpath(copy.path, "pin"))
            @test CT.ispinned(copy)
            for (call, f) in (("sync!", () -> CT.sync!(copy)), ("write_builder", () -> CT.write_builder(copy)), ("commit!", () -> CT.commit!(w)))
                err = caught(f)
                @test err isa PinnedCopyError
                @test sprint(showerror, err) == "PinnedCopyError: pinned copy: the local copy at $(copy.path) is pinned at slot 1, " *
                    "so $call refuses to move it (ADR-0015). unpin!(copy) makes it live, or use a live copy."
                @test (err.path, err.slot) == (copy.path, 1)
            end
            @test w.spent                                                 # commit! spends before it refuses
            @test CT.head(copy).slot == 1 && !haskey(store.objects, "p/000000000002")
            rm(joinpath(copy.path, "pin"))
            @test CT.sync!(copy).applied == 0
            close(copy)
            @test_throws "sync!: the local copy at" CT.sync!(CT.open(:not_a_chain, joinpath(dir, "x")))
        end
    end
end
