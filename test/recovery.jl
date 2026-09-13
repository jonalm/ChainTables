# #34 step 8 — ADR-0014, ADR-0007, ADR-0015, ADR-0020, ADR-0023: verify (both forms),
# repair! and DivergenceError, as_of by slot and by TransactionHash, pinned copies and
# unpin!, slot_at. Everything runs against the double with no credentials.
using ChainTables: Chain, LocalCopy, TransactionHash, StateFingerprint, Model, Ops, FingerprintMismatchError,
    DivergenceError, PinnedCopyError, ChainNotFoundError, WrongChainError, LocalCopyInconsistentError, record_path
using ChainTables.Testing: InMemoryObjectStore
using ChainTables.Ops: Record, Client, Insert, CreateTable
using ChainTables.Model: Column, Shape, Content
using SHA: sha256

@testset "recovery" begin
    CT = ChainTables
    hex = bytes2hex
    caught(f) = try; f(); nothing; catch e; e; end
    function fixture(dir; prefix = "p", kw...)
        store = InMemoryObjectStore()
        chain = Chain("bkt", prefix; store, cache_dir = joinpath(dir, "cache"), record_host = false, record_user = false, kw...)
        return store, chain
    end
    slotkey(s, prefix = "p") = prefix * "/" * lpad(string(s), 12, '0')
    plant!(store, key, bytes) = (store.objects[key] = bytes; store.modified[key] = 0; nothing)
    headfile(copy, slot) = joinpath(copy.path, "heads", lpad(string(slot), 12, '0'))
    tablefile(copy, name) = joinpath(copy.path, "tables", hex(copy.head.tables[findfirst(p -> first(p) == name, copy.head.tables)].second))
    # flip the last byte of a table's file; returns the file and its good bytes
    function damage!(copy, name)
        file = tablefile(copy, name)
        good = read(file)
        bad = Base.copy(good)
        bad[end] ⊻= 0x01
        write(file, bad)
        return file, good
    end
    # a chain with genesis and three records: samples (slot 1), tags and its twin sharing
    # one file (slot 2), an update (slot 3); a copy at its head
    function seeded(dir; kw...)
        store, chain = fixture(dir; kw...)
        CT.create_chain(chain)
        copy = CT.open(chain, joinpath(dir, "one"))
        CT.sync!(copy)
        w = CT.write_builder(copy)
        CT.create_table!(w, :samples) do t
            CT.column!(t, :id, Int64)
            CT.column!(t, :label, String)
            CT.column!(t, :mass, Float64; nullable = true)
            CT.primary_key!(t, :id)
        end
        CT.insert_rows!(w, :samples, [(id = 1, label = "a", mass = 1.5), (id = 2, label = "b", mass = missing)])
        r1 = CT.commit!(w; comment = "first samples")
        w = CT.write_builder(copy)
        for name in (:tags, :twin)
            CT.create_table!(w, name) do t
                CT.column!(t, :k, Int64)
                CT.primary_key!(t, :k)
            end
            CT.insert_rows!(w, name, [(k = 1,), (k = 2,)])
        end
        r2 = CT.commit!(w)
        w = CT.write_builder(copy)
        CT.update_rows!(w, :samples, [(id = 2, mass = 2.5)])
        r3 = CT.commit!(w)
        return store, chain, copy, [r1, r2, r3]
    end
    shape = Shape([Column("id", "int64", false), Column("v", "text", true)], ["id"])
    # a chain forged by hand under `prefix`: genesis, create samples, one insert per slot up
    # to `last`; every slot in `liars` carries a wrong state_fingerprint — a committer whose
    # model diverged from ours from that slot on. `plant = true` overwrites what the store
    # holds (an actor outside the protocol) and the record cache under `cache`. Returns the
    # chain id, the true fingerprint of every slot, and the record bytes by slot.
    function forge!(store, prefix, last; cidb = rand(UInt8, 16), liars = (), times = s -> 1000 + s, plant = false, cache = nothing)
        content = Content()
        prev = nothing
        fps = Vector{UInt8}[]
        records = Vector{UInt8}[]
        for s in 0:last
            ops = s == 0 ? Ops.Op[] : s == 1 ? [CreateTable("samples", shape)] : [Insert("samples", [Any[s, string(s)]])]
            foreach(op -> Ops.apply!(content, op), ops)
            fp = Model.state_fingerprint(content)
            push!(fps, fp)
            bytes = Ops.encode_record(Record(cidb, s, prev, s in liars ? fill(UInt8(s), 32) : fp,
                                             Client(nothing, nothing, "L$s", "J", times(s)), nothing, ops))
            plant ? plant!(store, slotkey(s, prefix), bytes) : CT.put_object_if_absent(store, slotkey(s, prefix), bytes)
            cache === nothing || write(record_path(cache, "bkt", slotkey(s, prefix)), bytes)
            push!(records, bytes)
            prev = Ops.transaction_hash(bytes)
        end
        return CT.chain_id_string(cidb), fps, records
    end
    # a copy at `last` of a chain whose records from `liar` on are then rewritten to carry
    # fingerprints this client does not reproduce, with the head naming the rewritten record:
    # what a copy looks like after the committers diverged and its own head was built on
    # their records (cf. test/chain.jl, the commit pre-check)
    function diverged!(store, chain, prefix, last, liar)
        cidb = rand(UInt8, 16)
        cid, fps, _ = forge!(store, prefix, last; cidb)
        copy = CT.open(chain, joinpath(dirname(chain.cache.dir), "copy_" * prefix))
        @test CT.replay!(copy, 0, last; clock = () -> 0).checkpoints == [last]
        _, _, lies = forge!(store, prefix, last; cidb, liars = liar:last, plant = true, cache = chain.cache)
        h = copy.head
        copy.head = CT.Head(h.chain_id, h.format_version, h.slot, Ops.transaction_hash(lies[end]), h.state_fingerprint, h.tables,
                            h.written_at_ms, h.written_by)
        return copy, cid, fps, lies
    end

    # ------------------------------------------------------------------------
    # verify (ADR-0014, ADR-0007, ADR-0020): local only; a damaged or missing
    # table file raises FingerprintMismatchError naming the file and repair!.
    # ------------------------------------------------------------------------
    @testset "verify" begin
        mktempdir() do dir
            store, chain, copy, rs = seeded(dir)
            cid = copy.head.chain_id
            n = length(store.calls)
            @test CT.verify(copy) === nothing
            @test CT.verify(copy; full = true) === nothing
            @test length(store.calls) == n                                      # local only, no network
            file, good = damage!(copy, "samples")
            f = basename(file)
            bad = hex(sha256(read(file)))
            computed = Model.state_fingerprint(name => (name == "samples" ? sha256(read(file)) : h) for (name, h) in copy.head.tables)
            err = caught(() -> CT.verify(copy))
            @test err isa FingerprintMismatchError
            msg = sprint(showerror, err)
            @test occursin("state fingerprint mismatch at slot 3 (chain $cid): the head of the local copy at $(copy.path) holds " *
                           "state_fingerprint $(hex(copy.head.state_fingerprint)), its table files hash to $(hex(computed)): " *
                           "table file tables/$f (table \"samples\") hashes to $bad, not its name.", msg)
            @test occursin("The local copy is damaged (its files, not the chain): repair!(copy) rewrites every file whose bytes " *
                           "do not hash to its name from the record cache.", msg)
            @test (err.chain_id, err.slot, err.expected, err.computed) == (cid, 3, copy.head.state_fingerprint, computed)
            @test err.expected isa StateFingerprint && err.computed isa StateFingerprint
            @test_throws FingerprintMismatchError CT.verify(copy; full = true)      # the files come first
            @test CT.head(copy).slot == 3                                       # readable
            again = CT.open(chain, copy.path)                                   # the damage is caught at load, as ever
            @test_throws LocalCopyInconsistentError CT.load_table!(again, "samples")
            close(again)
            rm(file)
            err = caught(() -> CT.verify(copy))
            @test err isa FingerprintMismatchError
            @test occursin("table file tables/$f (table \"samples\") is missing.", sprint(showerror, err))
            @test err.computed === nothing
            write(file, good)
            @test CT.verify(copy) === nothing
            # two tables sharing one file: one line names both
            file, good = damage!(copy, "tags")
            @test occursin("(tables \"tags\", \"twin\") hashes to", sprint(showerror, caught(() -> CT.verify(copy))))
            write(file, good)
            @test CT.verify(copy) === nothing
            fresh = CT.open(chain, joinpath(dir, "fresh"))
            @test_throws "verify(copy): the local copy at $(fresh.path) has no head yet, so there is nothing to verify; sync!(copy) binds it" CT.verify(fresh)
            close(fresh)
            close(copy)
            @test_throws "is closed" CT.verify(copy)
        end
    end

    @testset "verify full: the record cache walked, the first mismatching slot bisected" begin
        mktempdir() do dir
            store, chain = fixture(dir)
            copy, cid, fps, lies = diverged!(store, chain, "p", 6, 4)
            @test CT.head(copy).slot == 6 && CT.verify(copy) === nothing        # the files are fine: it is the chain
            n = length(store.calls)
            err = caught(() -> CT.verify(copy; full = true))
            @test length(store.calls) == n                                      # local only
            @test err isa FingerprintMismatchError
            msg = sprint(showerror, err)
            @test occursin("state fingerprint mismatch at slot 4 (chain $cid): replaying the record cache from slot 0, the record's " *
                           "state_fingerprint is $("04"^32), this client computes $(hex(fps[5])) after applying it; slots 0 to 3 " *
                           "reproduce. The record was written by L4 on Julia J; this client is ChainTables", msg)
            @test occursin("The local copy at $(copy.path) is at slot 6 and stays readable. This machine cannot reproduce the " *
                           "chain from slot 4, or the committer of slot 4 wrote a wrong fingerprint: repair!(copy) confirms whether " *
                           "the head reproduces.", msg)
            @test (err.chain_id, err.slot, err.expected, err.computed) == (cid, 4, fill(0x04, 32), fps[5])
            @test err.record_client == (; lib = "L4", julia = "J") && err.this_client.julia == string(VERSION)
            # the head's own content is what the replay yields, so repair! has nothing to rewrite
            @test CT.repair!(copy) == (; slot = 6, files_rewritten = 0)
            # a missing cached record: the check is local and stops
            cached(s) = record_path(chain.cache, "bkt", slotkey(s))
            two = read(cached(2))
            rm(cached(2))
            @test_throws "verify(copy; full = true): slot 2 of chain $cid is not in the record cache ($(cached(2))), and the check " *
                         "is local. repair!(copy) fetches what the cache lacks and rewrites what differs; a fresh local copy " *
                         "sync!ed from the chain fetches every record." CT.verify(copy; full = true)
            write(cached(2), two)
            # a damaged cached record: caught by hash before anything is replayed
            three = read(cached(3))
            badbytes = Base.copy(three)
            badbytes[end] ⊻= 0x01
            write(cached(3), badbytes)
            @test_throws "verify(copy; full = true): the record cache's copy of slot 3 ($(cached(3))) hashes to " *
                         "$(hex(Ops.transaction_hash(badbytes))); slot 4 names its parent as $(hex(Ops.transaction_hash(three))). " *
                         "The record cache is damaged: delete that file, and repair!(copy) fetches it again." CT.verify(copy; full = true)
            write(cached(3), three)
            six = read(cached(6))
            write(cached(6), badbytes)
            @test_throws "hashes to $(hex(Ops.transaction_hash(badbytes))); the head of the local copy at $(copy.path) names it as " *
                         "$(hex(copy.head.transaction_hash))." CT.verify(copy; full = true)
            write(cached(6), six)
            @test_throws FingerprintMismatchError CT.verify(copy; full = true)
            close(copy)

            # the head is the first liar: every slot below reproduces
            chainq = Chain("bkt", "q"; store, cache_dir = joinpath(dir, "cache"), record_host = false, record_user = false)
            q, cidq, fpsq, _ = diverged!(store, chainq, "q", 5, 5)
            err = caught(() -> CT.verify(q; full = true))
            @test err isa FingerprintMismatchError
            @test occursin("state fingerprint mismatch at slot 5 (chain $cidq): replaying the record cache from slot 0, the record's " *
                           "state_fingerprint is $("05"^32), this client computes $(hex(fpsq[6])) after applying it; slots 0 to 4 reproduce.", err.msg)
            @test err.slot == 5
            close(q)
            # the genesis is: it is the first record
            chainr = Chain("bkt", "r"; store, cache_dir = joinpath(dir, "cache"), record_host = false, record_user = false)
            r, cidr, fpsr, _ = diverged!(store, chainr, "r", 3, 0)
            err = caught(() -> CT.verify(r; full = true))
            @test err isa FingerprintMismatchError
            @test occursin("state fingerprint mismatch at slot 0 (chain $cidr): replaying the record cache from slot 0, the record's " *
                           "state_fingerprint is $("00"^32), this client computes $(hex(fpsr[1])) after applying it; it is the first record.", err.msg)
            @test err.slot == 0
            close(r)
            # a fresh sync! of a lying chain is refused at the checkpoint, as ever, and left at its last one
            fresh = CT.open(Chain("bkt", "q"; store, cache_dir = joinpath(dir, "cold")), joinpath(dir, "fresh"))
            @test_throws FingerprintMismatchError CT.sync!(fresh)
            @test fresh.head === nothing || CT.head(fresh).slot < 5
            close(fresh)
        end
    end

    # ------------------------------------------------------------------------
    # repair! (ADR-0014, ADR-0023, ADR-0020): in place, only the files whose
    # bytes do not hash to their name; head and pin untouched; DivergenceError
    # when the fresh replay does not reproduce the head, nothing written.
    # ------------------------------------------------------------------------
    @testset "repair!" begin
        mktempdir() do dir
            store, chain, copy, rs = seeded(dir)
            cid = copy.head.chain_id
            @test CT.repair!(copy) == (; slot = 3, files_rewritten = 0)
            file, good = damage!(copy, "samples")
            touch(joinpath(copy.path, "pin"))
            headbytes = read(headfile(copy, 3))
            files = sort(readdir(joinpath(copy.path, "tables")))
            @test CT.repair!(copy) == (; slot = 3, files_rewritten = 1)
            @test read(file) == good
            @test read(headfile(copy, 3)) == headbytes && CT.ispinned(copy)      # head and pin untouched
            @test sort(readdir(joinpath(copy.path, "tables"))) == files          # no temporary left
            @test CT.verify(copy; full = true) === nothing
            @test isequal(CT.table(copy, :samples)[2].mass, 2.5)
            rm(joinpath(copy.path, "pin"))
            # a missing file, and one file shared by two tables: one rewrite
            twin = tablefile(copy, "tags")
            @test twin == tablefile(copy, "twin")
            rm(twin)
            @test CT.repair!(copy) == (; slot = 3, files_rewritten = 1)
            @test isfile(twin) && hex(sha256(read(twin))) == basename(twin)
            damage!(copy, "tags")
            damage!(copy, "samples")
            @test CT.repair!(copy) == (; slot = 3, files_rewritten = 2)
            @test CT.verify(copy) === nothing
            # a record the cache lacks is fetched; a damaged cached record stops it
            cached(s) = record_path(chain.cache, "bkt", slotkey(s))
            rm(cached(1))
            damage!(copy, "samples")
            n = length(store.calls)
            @test CT.repair!(copy) == (; slot = 3, files_rewritten = 1)
            @test isfile(cached(1)) && store.calls[n+1:end] == [(:fetch_object, slotkey(1))]
            two = read(cached(2))
            badbytes = Base.copy(two)
            badbytes[end] ⊻= 0x01
            write(cached(2), badbytes)
            @test_throws "repair!(copy): the record cache's copy of slot 2 ($(cached(2))) hashes to" CT.repair!(copy)
            write(cached(2), two)
            fresh = CT.open(chain, joinpath(dir, "fresh"))
            @test_throws "repair!(copy): the local copy at $(fresh.path) has no head yet, so there is nothing to repair; sync!(copy) binds it" CT.repair!(fresh)
            close(fresh)

            # divergence: a self-consistent head the replay does not reproduce — here, one
            # that omits tags and twin. Nothing is written; the copy stays readable; commit refuses.
            h = copy.head
            kept = filter(p -> first(p) == "samples", h.tables)
            lying = CT.Head(h.chain_id, h.format_version, 3, h.transaction_hash, Model.state_fingerprint(kept), kept, h.written_at_ms, h.written_by)
            close(copy)
            rm(headfile(copy, 3))
            write(headfile(copy, 3), CT.encode_head(lying))
            copy = CT.open(chain, copy.path)
            @test CT.tables(copy) == ["samples"]
            files = sort(readdir(joinpath(copy.path, "tables")))
            err = caught(() -> CT.repair!(copy))
            @test err isa DivergenceError
            replayed = Model.state_fingerprint(h.tables)
            @test sprint(showerror, err) == "DivergenceError: divergence at slot 3 (chain $cid): a fresh replay of the record cache " *
                "from slot 0 to slot 3 yields state fingerprint $(hex(replayed)), the head of the local copy at $(copy.path) carries " *
                "$(hex(lying.state_fingerprint)); tables that differ: tags (replay $(hex(h.tables[2].second)), head absent), " *
                "twin (replay $(hex(h.tables[3].second)), head absent). This machine cannot reproduce the chain — whether this " *
                "client or the chain's committers are right is not decided here. Nothing was written; the local copy stays " *
                "readable and never commits onto this chain."
            @test (err.chain_id, err.slot, err.expected, err.computed) == (cid, 3, lying.state_fingerprint, replayed)
            @test err.expected isa StateFingerprint && err.computed isa StateFingerprint
            @test sort(readdir(joinpath(copy.path, "tables"))) == files && read(headfile(copy, 3)) == CT.encode_head(lying)
            @test CT.table(copy, :samples)[2].mass == 2.5
            w = CT.write_builder(copy)
            CT.delete_rows!(w, :samples, [(id = 1,)])
            @test_throws FingerprintMismatchError CT.commit!(w)
            @test !haskey(store.objects, slotkey(4))
            close(copy)
        end
    end

    # ------------------------------------------------------------------------
    # as_of (ADR-0015, ADR-0023): a pinned copy at a slot or a TransactionHash;
    # temporary and deleted on close, or at a path that is kept and reopened.
    # ------------------------------------------------------------------------
    @testset "as_of" begin
        mktempdir() do dir
            store, chain, copy, rs = seeded(dir)
            cid = copy.head.chain_id
            old = CT.as_of(chain, 1)
            @test old isa LocalCopy && old.temporary && CT.ispinned(old)
            @test CT.head(old) == (; slot = 1, transaction_hash = rs[1].transaction_hash, state_fingerprint = rs[1].state_fingerprint)
            @test CT.table(old, :samples)[2].mass === missing && CT.tables(old) == ["samples"]
            @test startswith(basename(old.path), "chaintables-as_of-")
            for f in (() -> CT.sync!(old), () -> CT.write_builder(old))
                @test_throws PinnedCopyError f()
            end
            @test CT.head(old).slot == 1
            path = old.path
            close(old)
            @test !ispath(path)
            close(old)                                                          # idempotent
            @test_throws "is closed" CT.head(old)
            # by transaction hash; the live copy was never touched
            old = CT.as_of(chain, rs[2].transaction_hash)
            @test CT.head(old).slot == 2 && CT.tables(old) == ["samples", "tags", "twin"]
            close(old)
            @test CT.head(copy).slot == 3 && !CT.ispinned(copy)
            # refused targets
            @test_throws "as_of(chain, target): target is a Vector{UInt8}; give a slot (an Integer) or a TransactionHash" CT.as_of(chain, rs[2].transaction_hash.bytes)
            @test_throws "as_of(chain, target): a StateFingerprint is not an address; give a slot (an Integer) or a TransactionHash" CT.as_of(chain, rs[2].state_fingerprint)
            @test_throws "as_of(chain, -1): slot -1 is negative" CT.as_of(chain, -1)
            @test_throws "as_of(chain, 9): the chain at bkt/p has no slot 9; its head is below it. slot_at(chain, time_ms) finds a slot by time, and head(copy) after sync!(copy) is the chain's head" CT.as_of(chain, 9)
            @test_throws "as_of(chain, TransactionHash(\"$("00"^32)\")): no record of the chain at bkt/p hashes to it (slots 0 to 3 scanned)" CT.as_of(chain, TransactionHash(zeros(UInt8, 32)))
            none = Chain("bkt", "none"; store, cache_dir = joinpath(dir, "cache"))
            @test_throws ChainNotFoundError CT.as_of(none, 0)
            @test_throws ChainNotFoundError CT.as_of(none, TransactionHash(zeros(UInt8, 32)))
            @test_throws "chain not found: no slot 0 at bkt/none" CT.as_of(none, 2)
            # a given path is kept, and opened rather than rebuilt when pinned at the slot
            p = joinpath(dir, "pinned")
            a = CT.as_of(chain, 2; path = p)
            @test !a.temporary && a.path == abspath(p) && CT.ispinned(a) && CT.head(a).slot == 2
            close(a)
            @test isfile(joinpath(p, "pin"))
            hb = read(joinpath(p, "heads", "000000000002"))
            n = length(store.calls)
            a = CT.as_of(chain, 2; path = p)
            @test CT.head(a).slot == 2 && read(joinpath(p, "heads", "000000000002")) == hb   # the same head file
            @test isempty(store.calls[n+1:end])                                 # its record came from the cache
            close(a)
            # pinned below the target: replayed forward, still pinned
            a = CT.as_of(chain, 3; path = p)
            @test CT.head(a).slot == 3 && CT.ispinned(a) && CT.table(a, :samples)[2].mass == 2.5
            close(a)
            # pinned above the target, or live: refused, untouched
            @test_throws "as_of(chain, 1): the local copy at $(abspath(p)) is pinned at slot 3, above 1; a local copy never moves backwards. Give another path, or delete this one." CT.as_of(chain, 1; path = p)
            @test isfile(joinpath(p, "pin"))
            @test_throws "as_of(chain, 1): the local copy at $(copy.path) is live (slot 3, not pinned); as_of never touches a live local copy. Give another path, or none for a temporary one." CT.as_of(chain, 1; path = copy.path)
            @test !CT.ispinned(copy) && CT.head(copy).slot == 3
            # unpin!: live thereafter, and sync! advances
            a = CT.as_of(chain, 1; path = joinpath(dir, "unpin"))
            @test CT.unpin!(a) === nothing && !CT.ispinned(a)
            @test_throws "unpin!(copy): the local copy at $(a.path) is not pinned; it is live already" CT.unpin!(a)
            @test CT.sync!(a) == (; applied = 2, slot = 3, transaction_hash = rs[3].transaction_hash)
            @test CT.table(a, :samples)[2].mass == 2.5
            close(a)
            t = CT.as_of(chain, 1)
            CT.unpin!(t)
            tp = t.path
            close(t)
            @test !ispath(tp)                                                   # temporary regardless
            # the record it stops at is verified, built (the checkpoint) or opened (the head's record)
            cached(s) = record_path(chain.cache, "bkt", slotkey(s))
            two = store.objects[slotkey(2)]
            rec2 = Ops.decode_record(two; slot = 2)
            lie = Ops.encode_record(Record(rec2.chain_id, 2, rec2.prev_hash, fill(0xee, 32), rec2.client, rec2.comment, rec2.ops))
            plant!(store, slotkey(2), lie)
            write(cached(2), lie)
            before = readdir(tempdir())
            err = caught(() -> CT.as_of(chain, 2))
            @test err isa FingerprintMismatchError && err.slot == 2
            @test readdir(tempdir()) == before                                  # the temporary copy is gone
            plant!(store, slotkey(2), two)
            write(cached(2), two)
            three = store.objects[slotkey(3)]
            rec3 = Ops.decode_record(three; slot = 3)
            lie = Ops.encode_record(Record(rec3.chain_id, 3, rec3.prev_hash, fill(0xee, 32), rec3.client, rec3.comment, rec3.ops))
            plant!(store, slotkey(3), lie)
            write(cached(3), lie)
            # a lie with another hash is a rewritten chain first; give the pinned head the lie's hash,
            # as a copy built on the lying record would carry, so the fingerprint pre-check is what speaks
            @test_throws CT.RewrittenChainError CT.as_of(chain, 3; path = p)
            ph = CT.decode_head(read(joinpath(p, "heads", "000000000003")))
            rm(joinpath(p, "heads", "000000000003"))
            write(joinpath(p, "heads", "000000000003"), CT.encode_head(CT.Head(ph.chain_id, ph.format_version, 3, Ops.transaction_hash(lie),
                                                                              ph.state_fingerprint, ph.tables, ph.written_at_ms, ph.written_by)))
            err = caught(() -> CT.as_of(chain, 3; path = p))
            @test err isa FingerprintMismatchError
            @test occursin("state fingerprint mismatch at slot 3 (chain $cid): the record's state_fingerprint is $("ee"^32), the head of the local copy at $(abspath(p)) holds", err.msg)
            @test occursin("The pinned copy does not match the record it claims to be the result of: delete the directory, or repair!(copy) confirms whether this machine reproduces the chain.", err.msg)
            @test isdir(p)                                                      # a given path is never deleted
            plant!(store, slotkey(3), three)
            write(cached(3), three)
            rm(joinpath(p, "heads", "000000000003"))
            write(joinpath(p, "heads", "000000000003"), CT.encode_head(ph))
            close(CT.as_of(chain, 3; path = p))
            # a path bound to another chain: refused at open, pinned or live
            chainq = Chain("bkt", "q"; store, cache_dir = joinpath(dir, "qcache"))
            CT.create_chain(chainq)
            @test_throws WrongChainError CT.as_of(chainq, 0; path = p)
            @test_throws WrongChainError CT.as_of(chainq, 0; path = joinpath(dir, "one"))
        end
    end

    # ------------------------------------------------------------------------
    # slot_at (ADR-0015): the highest slot whose client.time_ms is at or below
    # the time, by scan — time is advisory and not monotone; before genesis errors.
    # ------------------------------------------------------------------------
    @testset "slot_at" begin
        mktempdir() do dir
            store, chain = fixture(dir; prefix = "t")
            times = [10, 100, 50, 200, 150]
            forge!(store, "t", 4; times = s -> times[s+1])
            @test CT.slot_at(chain, 10) == 0
            @test CT.slot_at(chain, 49) == 0
            @test CT.slot_at(chain, 50) == 2
            @test CT.slot_at(chain, 99) == 2
            @test CT.slot_at(chain, 100) == 2                                   # the highest slot, not the latest time
            @test CT.slot_at(chain, 149) == 2
            @test CT.slot_at(chain, 150) == 4
            @test CT.slot_at(chain, 200) == 4
            @test CT.slot_at(chain, 10^12) == 4
            @test CT.slot_at(chain, 10) isa Int64
            @test_throws "slot_at(chain, 9): the time is before the genesis record's client.time_ms, 10; there is no state before slot 0 (ADR-0015)" CT.slot_at(chain, 9)
            @test_throws "slot_at(chain, time_ms): time_ms is a Float64, not an Integer of milliseconds since the Unix epoch" CT.slot_at(chain, 1.5)
            @test_throws ChainNotFoundError CT.slot_at(Chain("bkt", "none"; store, cache_dir = joinpath(dir, "cache")), 5)
            old = CT.as_of(chain, CT.slot_at(chain, 99))
            @test CT.head(old).slot == 2 && CT.table(old, :samples)[2].v == "2"
            close(old)
        end
    end
end
