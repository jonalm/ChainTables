# ADR-0046 — the client surface for attachments: `put_attachment(chain, path_or_io)`,
# `touch_attachment(chain, hash)`, against `InMemoryObjectStore` and, for a gateway bucket,
# the loopback gateway and S3 (`GatewayDouble`, `gwtest_*`, `LoopbackServer`: test/gateway.jl,
# included ahead of this file). The store layer's own tests are in s3.jl, gateway.jl and
# Testing.jl.
using ChainTables: Chain, TransportError, WriteRefusedError, GatewayObjectStore
using ChainTables.Testing: InMemoryObjectStore
using SHA: sha256
const ATT = ChainTables

@testset "attachments" begin
    @testset "put_attachment(chain, path_or_io): hash, then store under the chain's prefix" begin
        mktempdir() do dir
            store = InMemoryObjectStore()
            chain = Chain("bkt", "p"; store, cache_dir = joinpath(dir, "cache"))
            bytes = rand(UInt8, 1000)
            h = bytes2hex(sha256(bytes))
            path = joinpath(dir, "a.bin")
            write(path, bytes)
            @test ATT.put_attachment(chain, path) == h
            @test store.objects["p/_attachments/$h"] == bytes
            # present: the same hash, nothing stored again
            @test ATT.put_attachment(chain, path) == h
            @test count(c -> c[1] == :put_attachment, store.calls) == 2
            # a seekable IO at its start
            other = rand(UInt8, 10)
            ho = bytes2hex(sha256(other))
            @test ATT.put_attachment(chain, IOBuffer(other)) == ho && store.objects["p/_attachments/$ho"] == other
            # an empty attachment is an attachment
            @test ATT.put_attachment(chain, IOBuffer(UInt8[])) == bytes2hex(sha256(UInt8[]))
            # the chain at the bucket root
            root = Chain("bkt", ""; store, cache_dir = joinpath(dir, "cache"))
            @test ATT.put_attachment(root, path) == h && haskey(store.objects, "_attachments/$h")
            # refused before a request: a non-seekable IO, an IO not at its start, a missing file, a directory
            n = length(store.calls)
            @test_throws "put_attachment takes a path or a seekable IO; a Base.BufferStream cannot seek, so it cannot be hashed before the upload" ATT.put_attachment(chain, Base.BufferStream())
            io = IOBuffer(other); read(io, UInt8)
            @test_throws "an attachment's IO must stand at its start, not at byte 1" ATT.put_attachment(chain, io)
            @test_throws "put_attachment: no file at $(joinpath(dir, "absent"))" ATT.put_attachment(chain, joinpath(dir, "absent"))
            @test_throws "put_attachment: $dir is a directory, not a file" ATT.put_attachment(chain, dir)
            @test length(store.calls) == n
        end
    end

    @testset "put_attachment(chain, …) retries a retryable failure, bounded, and nothing else" begin
        mktempdir() do dir
            store = InMemoryObjectStore()
            chain = Chain("bkt", "p"; store, cache_dir = joinpath(dir, "cache"))
            bytes = rand(UInt8, 100)
            h = bytes2hex(sha256(bytes))
            key = "p/_attachments/$h"
            attempts() = count(c -> c[1] == :put_attachment, store.calls)
            # a failure before the request lands, once: the second attempt stores it
            failed = Ref(0)
            store.fault = (verb, k, phase) -> (verb == :put_attachment && phase == :before && failed[] < 1) &&
                (failed[] += 1; throw(TransportError("injected"; status = 503)))
            io = IOBuffer(bytes)
            @test ATT.put_attachment(chain, io) == h && store.objects[key] == bytes && attempts() == 2
            # the acknowledgement lost: the retry finds it present
            empty!(store.calls); delete!(store.objects, key)
            failed[] = 0
            store.fault = (verb, k, phase) -> (verb == :put_attachment && phase == :after && failed[] < 1) &&
                (failed[] += 1; throw(TransportError("lost"; status = nothing)))
            @test ATT.put_attachment(chain, IOBuffer(bytes)) == h && store.objects[key] == bytes && attempts() == 2
            # always failing: PUT_ATTEMPTS attempts, then the last failure
            empty!(store.calls); delete!(store.objects, key)
            store.fault = (verb, k, phase) -> verb == :put_attachment && phase == :before && throw(TransportError("down"; status = 429))
            e = try ATT.put_attachment(chain, IOBuffer(bytes)); nothing catch e; e end
            @test e isa TransportError && e.status == 429 && attempts() == ATT.PUT_ATTEMPTS
            # not retryable: one attempt
            for thrown in (TransportError("forbidden"; status = 403), ATT.AttachmentChangedError("changed"), ErrorException("bug"))
                empty!(store.calls)
                store.fault = (verb, k, phase) -> verb == :put_attachment && phase == :before && throw(thrown)
                @test (try ATT.put_attachment(chain, IOBuffer(bytes)); nothing catch e; e end) === thrown
                @test attempts() == 1
            end
        end
    end

    @testset "touch_attachment(chain, hash): present is enough on a plain store, absent fails" begin
        mktempdir() do dir
            store = InMemoryObjectStore()
            chain = Chain("bkt", "p"; store, cache_dir = joinpath(dir, "cache"))
            h = ATT.put_attachment(chain, IOBuffer(b"held"))
            empty!(store.calls)
            @test ATT.touch_attachment(chain, h) === nothing
            @test store.calls == [(:stat_object, "p/_attachments/$h")]
            absent = bytes2hex(sha256(b"never stored"))
            e = try ATT.touch_attachment(chain, absent); nothing catch e; e end
            @test e isa ATT.AttachmentAbsentError && e.key == "p/_attachments/$absent"
            @test sprint(showerror, e) == "AttachmentAbsentError: attachment absent: the store of the chain at bkt/p holds no " *
                "attachment p/_attachments/$absent — it was never put, or its retention ended and it was deleted. A row " *
                "cannot refer to it until it is put again: put_attachment(chain, file) (ADR-0046)."
            # a hash that is not 64 lowercase hex is the caller's bug, refused before any request
            empty!(store.calls)
            for bad in (uppercase(h), h[1:63], h * "0", "../" * h[4:end])
                @test_throws "$(repr(bad)) is not an attachment hash, the SHA-256 of its bytes in 64 lowercase hex (ADR-0046)" ATT.touch_attachment(chain, bad)
            end
            @test isempty(store.calls)
            # a retryable failure of the HEAD is retried, as for a put
            failed = Ref(0)
            store.fault = (verb, k, phase) -> (verb == :stat_object && failed[] < 1) && (failed[] += 1; throw(TransportError("x"; status = 500)))
            @test ATT.touch_attachment(chain, h) === nothing && count(c -> c[1] == :stat_object, store.calls) == 2
        end
    end

    @testset "through a gateway: put retries session_ending; touch HEADs, then mints with the size, which must be present" begin
        s3 = S3TestServer(; bucket = "bkt", credentials = GWTEST_CREDS)
        double = GatewayDouble(s3, GWTEST_CREDS, "eu-north-1", "alice@example.com", ["p" => ["alice@example.com"]], _ -> nothing)
        gw = LoopbackServer(double)
        mktempdir() do dir
            try
                store = GatewayObjectStore("bkt", loopback_url(gw); region = "eu-north-1", credentials = GWTEST_CREDS,
                                           endpoint = s3test_endpoint(s3), path_style = true, timeout = 30)
                chain = Chain("bkt", "p"; store, cache_dir = joinpath(dir, "cache"))
                mints() = filter(r -> r.rawpath == "/mint", gw.requests)
                bytes = rand(UInt8, 3000)
                h = bytes2hex(sha256(bytes))
                key = "p/_attachments/$h"
                # 503 session_ending once: minted again, by another environment
                ending = Ref(true)
                double.respond = req -> req.rawpath == "/mint" && ending[] ?
                    (ending[] = false; gwtest_json(503, "session_ending", "this environment's session ends too soon")) : nothing
                @test ATT.put_attachment(chain, IOBuffer(bytes)) == h && s3.objects[key] == bytes
                @test length(mints()) == 2
                double.respond = _ -> nothing
                # touch: a HEAD in our bucket, then the mint with the size it gave, answered present
                empty!(gw.requests); empty!(s3.requests)
                @test ATT.touch_attachment(chain, h) === nothing
                @test [r.method for r in s3.requests] == ["HEAD"]
                @test only(mints()).query == ["key" => key, "size" => string(length(bytes))]
                # absent from our bucket: no mint
                absent = bytes2hex(sha256(b"absent"))
                empty!(gw.requests)
                e = try ATT.touch_attachment(chain, absent); nothing catch e; e end
                @test e isa ATT.AttachmentAbsentError && e.key == "p/_attachments/$absent"
                @test sprint(showerror, e) == "AttachmentAbsentError: attachment absent: the store of the chain at bkt/p " *
                    "holds no attachment p/_attachments/$absent — it was never put, or its retention ended and it was " *
                    "deleted. A row cannot refer to it until it is put again: put_attachment(chain, file) (ADR-0046)."
                @test isempty(gw.requests)
                # the gateway finds it absent where our bucket holds it: it fronts another bucket
                double.respond = req -> req.rawpath == "/mint" ? gwtest_minted(s3, key, length(bytes)) : nothing
                e = try ATT.touch_attachment(chain, h); nothing catch e; e end
                @test e isa ATT.GatewayMismatchError && e.key == key && e.bucket == "bkt"
                @test occursin("bucket bkt holds the attachment $key, but the gateway at $(loopback_url(gw)) found it absent " *
                               "and minted a URL to upload it", sprint(showerror, e))
                @test count(r -> r.method == "PUT", s3.requests) == 0
                # a refusal is the gateway's, as for a put
                double.respond = _ -> nothing
                double.caller = "bob@example.com"
                e = try ATT.touch_attachment(chain, h); nothing catch e; e end
                @test e isa WriteRefusedError && e.reason == "not_allowed"
            finally
                close(gw); close(s3)
            end
        end
    end

    @testset "attachment(copy, hash): fetched once into the shared cache, confirmed once per copy" begin
        mktempdir() do dir
            store = InMemoryObjectStore()
            cache_dir = joinpath(dir, "cache")
            chain = Chain("bkt", "p"; store, cache_dir, record_host = false, record_user = false)
            ATT.create_chain(chain)
            copy = ATT.open(chain, joinpath(dir, "one"))
            ATT.sync!(copy)
            bytes = rand(UInt8, 5000)
            h = ATT.put_attachment(chain, IOBuffer(bytes))
            key = "p/_attachments/$h"
            cached = joinpath(cache_dir, "attachments", h[1:2], h)
            # an unbound copy, a bad hash: refused before any request
            fresh = ATT.open(chain, joinpath(dir, "fresh"))
            empty!(store.calls)
            @test_throws "attachment(copy, hash): the local copy at $(joinpath(dir, "fresh")) has no head yet, so it belongs to no chain whose attachment it could read; sync!(copy) binds it" ATT.attachment(fresh, h)
            @test_throws "\"$(uppercase(h))\" is not an attachment hash" ATT.attachment(copy, uppercase(h))
            @test isempty(store.calls)
            # a miss: one GET into the cache, read-only, with its sidecar, and the copy's marker
            path = ATT.attachment(copy, h)
            @test path == cached && read(path) == bytes
            @test store.calls == [(:fetch_object_to, key)]
            @test filemode(path) & 0o222 == 0
            st = stat(path)
            @test read(path * ".meta", String) == "$(st.size) $(st.mtime)"
            @test isfile(joinpath(copy.path, "confirmed", h))
            @test sort(readdir(dirname(path))) == [h, h * ".meta"]          # no temporary file left
            # a hit, confirmed: no request, and so after a reopen
            empty!(store.calls)
            @test ATT.attachment(copy, h) == path && isempty(store.calls)
            close(copy)
            copy = ATT.open(chain, joinpath(dir, "one"))
            @test ATT.attachment(copy, h) == path && isempty(store.calls)
            # a hit through another copy: its first read HEADs the key in its chain's store, once
            two = ATT.open(chain, joinpath(dir, "two"))
            ATT.sync!(two)
            empty!(store.calls)
            @test ATT.attachment(two, h) == path && store.calls == [(:stat_object, key)]
            @test ATT.attachment(two, h) == path && length(store.calls) == 1
            # a hit cached from another chain, which this chain's store lacks: the file does not stand in for it
            other = Chain("bkt", "q"; store, cache_dir, record_host = false, record_user = false)
            ATT.create_chain(other)
            oc = ATT.open(other, joinpath(dir, "other"))
            ATT.sync!(oc)
            e = try ATT.attachment(oc, h); nothing catch e; e end
            @test e isa ATT.AttachmentAbsentError && e.key == "q/_attachments/$h" && e.chain_id == oc.head.chain_id
            @test sprint(showerror, e) == "AttachmentAbsentError: attachment absent: the store of the chain at bkt/q holds " *
                "no attachment q/_attachments/$h — it was never put to this chain, or its retention ended and it was " *
                "deleted — so attachment(copy, hash) has nothing to serve, whatever this machine has cached. Only someone " *
                "holding the file can bring it back, with put_attachment(chain, file) (ADR-0046)."
            @test !isfile(joinpath(oc.path, "confirmed", h))
            # a miss the store lacks: the same error, nothing cached
            absent = bytes2hex(sha256(b"absent"))
            @test_throws "attachment absent: the store of the chain at bkt/p holds no attachment p/_attachments/$absent" ATT.attachment(copy, absent)
            @test !ispath(joinpath(cache_dir, "attachments", absent[1:2], absent))
            # a retryable failure of the GET is retried
            hr = ATT.put_attachment(chain, IOBuffer(b"retried"))
            failed = Ref(0)
            store.fault = (verb, k, phase) -> (verb == :fetch_object_to && failed[] < 1) && (failed[] += 1; throw(TransportError("x"; status = 503)))
            @test read(ATT.attachment(copy, hr)) == b"retried" && failed[] == 1
            store.fault = (verb, k, phase) -> nothing
        end
    end

    @testset "attachment(copy, hash) on a gateway chain: put through the mint, read straight from the bucket" begin
        s3 = S3TestServer(; bucket = "bkt", credentials = GWTEST_CREDS)
        double = GatewayDouble(s3, GWTEST_CREDS, "eu-north-1", "alice@example.com", ["exp" => ["alice@example.com"]], _ -> nothing)
        gw = LoopbackServer(double)
        sts = LoopbackServer(gwtest_sts(GWTEST_CREDS, "eu-north-1", GWTEST_ARN))
        mktempdir() do dir
            try
                cache_dir = joinpath(dir, "cache")
                store = GatewayObjectStore("bkt", loopback_url(gw); region = "eu-north-1", credentials = GWTEST_CREDS,
                                           endpoint = s3test_endpoint(s3), path_style = true, sts_endpoint = loopback_url(sts))
                chain = Chain("bkt", "exp/run-1"; store, cache_dir, assume_first_writer_wins = true)
                ATT.create_chain(chain)
                empty!(gw.requests)
                bytes = rand(UInt8, 5000)
                # the put: one mint, one presigned PUT to the bucket, nothing PUT to the gateway
                h = ATT.put_attachment(chain, IOBuffer(bytes))
                key = "exp/run-1/_attachments/$h"
                @test s3.objects[key] == bytes
                @test count(r -> r.rawpath == "/mint", gw.requests) == 1 && !any(r -> r.method == "PUT", gw.requests)
                # a reference to it, committed through the gateway
                copy = ATT.open(chain, joinpath(dir, "one"))
                ATT.sync!(copy)
                w = ATT.write_builder(copy)
                ATT.create_table!(w, :files) do t
                    ATT.column!(t, :id, Int64); ATT.column!(t, :hash, String); ATT.primary_key!(t, :id)
                end
                ATT.insert_rows!(w, :files, [(id = 1, hash = h)])
                ATT.commit!(w)
                # a miss: one GET from the bucket, none of it through the gateway
                empty!(gw.requests); empty!(s3.requests)
                path = ATT.attachment(copy, ATT.table(copy, :files)[1].hash)
                @test read(path) == bytes && path == joinpath(cache_dir, "attachments", h[1:2], h)
                @test [(r.method, r.path) for r in s3.requests] == [("GET", "/bkt/$key")]
                @test isempty(gw.requests)
                # confirmed: no request
                empty!(s3.requests)
                @test ATT.attachment(copy, h) == path && isempty(s3.requests)
                # a hit through a second copy: one HEAD of the bucket, then confirmed
                two = ATT.open(chain, joinpath(dir, "two"))
                ATT.sync!(two)
                empty!(s3.requests)
                @test ATT.attachment(two, h) == path
                @test [(r.method, r.path) for r in s3.requests] == [("HEAD", "/bkt/$key")]
                @test ATT.attachment(two, h) == path && length(s3.requests) == 1
                @test isempty(gw.requests)
                # verify(copy; full = true) over it, on the gateway chain
                @test ATT.verify(two; full = true) === nothing
                # absent from the bucket
                absent = bytes2hex(sha256(b"absent"))
                @test_throws "attachment absent: the store of the chain at bkt/exp/run-1 holds no attachment exp/run-1/_attachments/$absent" ATT.attachment(copy, absent)
                @test isempty(gw.requests)
                close(two); close(copy)
            finally
                close(gw); close(sts); close(s3)
            end
        end
    end

    @testset "attachment(copy, hash): a download that does not hash to its key, a damaged cache entry" begin
        mktempdir() do dir
            store = InMemoryObjectStore()
            cache_dir = joinpath(dir, "cache")
            chain = Chain("bkt", "p"; store, cache_dir, record_host = false, record_user = false)
            ATT.create_chain(chain)
            copy = ATT.open(chain, joinpath(dir, "one"))
            ATT.sync!(copy)
            # the store holds other bytes under a hash: nothing cached, not retried
            h = bytes2hex(sha256(b"what the key names"))
            store.objects["p/_attachments/$h"] = b"other bytes"; store.modified["p/_attachments/$h"] = 0
            empty!(store.calls)
            e = try ATT.attachment(copy, h); nothing catch e; e end
            found = bytes2hex(sha256(b"other bytes"))
            @test e isa ATT.AttachmentDigestError && e.key == "p/_attachments/$h" && e.found == found && e.size == 11
            @test e.chain_id == copy.head.chain_id
            @test sprint(showerror, e) == "AttachmentDigestError: attachment digest: the store of the chain at bkt/p " *
                "returned 11 bytes for p/_attachments/$h, which hash to $found, not to the key's hash. Nothing was cached. " *
                "S3 checked the hash when the attachment was stored, so the bucket was written from outside the protocol: " *
                "stop and report it (ADR-0046)."
            @test length(store.calls) == 1 && isempty(readdir(joinpath(cache_dir, "attachments", h[1:2])))
            @test !isfile(joinpath(copy.path, "confirmed", h))
            # a sidecar for another mtime beside a file that hashes right — two fills of one hash
            # at once pair one's sidecar with the other's file — is rewritten, nothing fetched
            bytes = rand(UInt8, 100)
            h = ATT.put_attachment(chain, IOBuffer(bytes))
            path = ATT.attachment(copy, h)
            write(path * ".meta", "100 0.0")
            empty!(store.calls)
            @test ATT.attachment(copy, h) == path && isempty(store.calls)      # confirmed: no HEAD either
            @test read(path * ".meta", String) == ATT.sidecar_text(stat(path))
            @test isempty(filter(f -> endswith(f, ".tmp"), readdir(dirname(path))))
            # through a copy that has not confirmed it: healed, then HEADed and confirmed
            two = ATT.open(chain, joinpath(dir, "two"))
            ATT.sync!(two)
            write(path * ".meta", "100 0.0")
            empty!(store.calls)
            @test ATT.attachment(two, h) == path && store.calls == [(:stat_object, "p/_attachments/$h")]
            @test isfile(joinpath(two.path, "confirmed", h)) && ATT.verify(two; full = true) === nothing
            close(two)
            # a cached file that differs from its sidecar and does not hash to its name: raised, not fetched again
            chmod(path, 0o644); write(path, rand(UInt8, 101)); chmod(path, 0o444)
            st = stat(path)
            meta = read(path * ".meta", String)
            found = bytes2hex(ATT.hash_file(path))
            empty!(store.calls)
            e = try ATT.attachment(copy, h); nothing catch e; e end
            @test e isa ATT.AttachmentCacheError && e.path == path && e.chain_id == copy.head.chain_id
            @test sprint(showerror, e) == "AttachmentCacheError: attachment cache: the cached file $path is $(st.size) " *
                "bytes modified at $(st.mtime) and hashes to $found, not to its name; its sidecar $path.meta records " *
                "\"$meta\". The file was changed after it was cached. The cache is damaged, not the chain: deleting " *
                "$path and $path.meta is always safe, and the next read fetches it again (ADR-0046)."
            @test isempty(store.calls)
            # as the message says, on a copy that never confirmed the hash too: deleted, then fetched again
            unconfirmed = ATT.open(chain, joinpath(dir, "unconfirmed"))
            ATT.sync!(unconfirmed)
            e = try ATT.attachment(unconfirmed, h); nothing catch e; e end
            @test e isa ATT.AttachmentCacheError && e.path == path && e.chain_id == unconfirmed.head.chain_id
            @test sprint(showerror, e) == "AttachmentCacheError: attachment cache: the cached file $path is $(st.size) " *
                "bytes modified at $(st.mtime) and hashes to $found, not to its name; its sidecar $path.meta records " *
                "\"$meta\". The file was changed after it was cached. The cache is damaged, not the chain: deleting " *
                "$path and $path.meta is always safe, and the next read fetches it again (ADR-0046)."
            chmod(path, 0o644); rm(path); rm(path * ".meta")
            @test read(ATT.attachment(unconfirmed, h)) == bytes
            close(unconfirmed)
            chmod(path, 0o644); write(path, rand(UInt8, 101)); chmod(path, 0o444)
            empty!(store.calls)
            # a cached file with no sidecar is absent: fetched again over the read-only file
            rm(path * ".meta")
            @test read(ATT.attachment(copy, h)) == bytes && store.calls == [(:fetch_object_to, "p/_attachments/$h")]
            # a sidecar with no file is absent too
            chmod(path, 0o644); rm(path)
            @test read(ATT.attachment(copy, h)) == bytes
        end
    end

    @testset "attachment(copy, hash): a hit whose HEAD gives another size — the cached file is hashed to say which side is wrong" begin
        mktempdir() do dir
            store = InMemoryObjectStore()
            cache_dir = joinpath(dir, "cache")
            chain = Chain("bkt", "p"; store, cache_dir, record_host = false, record_user = false)
            ATT.create_chain(chain)
            one = ATT.open(chain, joinpath(dir, "one"))
            ATT.sync!(one)
            bytes = rand(UInt8, 100)
            h = ATT.put_attachment(chain, IOBuffer(bytes))
            key = "p/_attachments/$h"
            path = ATT.attachment(one, h)
            fresh(name) = (c = ATT.open(chain, joinpath(dir, name)); ATT.sync!(c); c)
            # the store holds another size, the cached file hashes to its name: the store is wrong
            store.objects[key] = rand(UInt8, 120)
            two = fresh("two")
            empty!(store.calls)
            e = try ATT.attachment(two, h); nothing catch e; e end
            @test e isa ATT.AttachmentDigestError && e.key == key && e.size == 120 && e.found === nothing
            @test e.chain_id == two.head.chain_id
            @test sprint(showerror, e) == "AttachmentDigestError: attachment digest: the store of the chain at bkt/p " *
                "holds 120 bytes at $key, but the cached file $path, which hashes to the key's hash, is 100 bytes, so the " *
                "store's bytes cannot hash to it. Nothing was confirmed, and the cached file was kept. S3 checked the hash " *
                "when the attachment was stored, so the bucket was written from outside the protocol: stop and report it " *
                "(ADR-0046)."
            @test store.calls == [(:stat_object, key)]                       # a HEAD, no download
            @test !isfile(joinpath(two.path, "confirmed", h)) && read(path) == bytes
            # the store is right, the cached file was swapped with its sidecar rewritten to match: the cache is wrong
            store.objects[key] = bytes
            other = rand(UInt8, 80)
            chmod(path, 0o644); write(path, other); chmod(path, 0o444)
            write(path * ".meta", ATT.sidecar_text(stat(path)))
            three = fresh("three")
            e = try ATT.attachment(three, h); nothing catch e; e end
            found = bytes2hex(sha256(other))
            @test e isa ATT.AttachmentCacheError && e.path == path && e.key == key && e.chain_id == three.head.chain_id
            @test sprint(showerror, e) == "AttachmentCacheError: attachment cache: the cached file $path is 80 bytes and " *
                "hashes to $found, not to its name, while the store of the chain at bkt/p holds 100 bytes at $key. The " *
                "cache is damaged, not the chain: deleting $path and $path.meta is always safe, and the next read fetches " *
                "it again (ADR-0046)."
            @test !isfile(joinpath(three.path, "confirmed", h))
            # as the message says: deleted, then fetched again
            chmod(path, 0o644); rm(path); rm(path * ".meta")
            @test read(ATT.attachment(three, h)) == bytes
        end
    end

    @testset "verify(copy; full = true) hashes the confirmed attachments; repair!(copy) fetches what is bad" begin
        mktempdir() do dir
            store = InMemoryObjectStore()
            cache_dir = joinpath(dir, "cache")
            chain = Chain("bkt", "p"; store, cache_dir, record_host = false, record_user = false)
            ATT.create_chain(chain)
            copy = ATT.open(chain, joinpath(dir, "one"))
            ATT.sync!(copy)
            a, b = rand(UInt8, 300), rand(UInt8, 400)
            ha, hb = ATT.put_attachment(chain, IOBuffer(a)), ATT.put_attachment(chain, IOBuffer(b))
            pa, pb = ATT.attachment(copy, ha), ATT.attachment(copy, hb)
            ATT.put_attachment(chain, IOBuffer(b"never read"))                  # not confirmed: not covered
            @test ATT.verify(copy; full = true) === nothing
            @test ATT.repair!(copy) == (; slot = 0, files_rewritten = 0, attachments_repaired = 0)
            # damage no sidecar can see: other bytes, the sidecar rewritten to match
            chmod(pa, 0o644); write(pa, rand(UInt8, 300)); chmod(pa, 0o444)
            write(pa * ".meta", "$(stat(pa).size) $(stat(pa).mtime)")
            found = bytes2hex(ATT.hash_file(pa))
            rm(pb); rm(pb * ".meta")
            @test ATT.verify(copy) === nothing                                  # not full: the attachments are not checked
            e = try ATT.verify(copy; full = true); nothing catch e; e end
            @test e isa ATT.AttachmentCacheError && e.chain_id == copy.head.chain_id
            # an entry that is gone is not damage: deleting one is always safe, and the next read fetches it
            @test sprint(showerror, e) == "AttachmentCacheError: verify(copy; full = true): the attachment cache is " *
                "damaged for attachments this copy confirmed: $pa hashes to $found, not its name. The cache is damaged, " *
                "not the chain: repair!(copy) fetches them again (ADR-0046)."
            # repair!: fetched again from the chain's store
            empty!(store.calls)
            @test ATT.repair!(copy) == (; slot = 0, files_rewritten = 0, attachments_repaired = 2)
            @test read(pa) == a && read(pb) == b && filemode(pa) & 0o222 == 0
            @test sort([c for c in store.calls if c[1] == :fetch_object_to]) == sort([(:fetch_object_to, "p/_attachments/$ha"), (:fetch_object_to, "p/_attachments/$hb")])
            @test ATT.verify(copy; full = true) === nothing
            # the attachment cache cleared: verify passes, and the next read fetches again
            rm(joinpath(cache_dir, "attachments"); recursive = true)
            @test ATT.verify(copy; full = true) === nothing
            @test read(ATT.attachment(copy, ha)) == a && read(ATT.attachment(copy, hb)) == b
            # a sidecar that disagrees with a file that hashes right: the sidecar is rewritten, nothing fetched
            write(pa * ".meta", "0 0.0")
            @test ATT.verify(copy; full = true) === nothing                    # not damage: the next read heals it
            @test read(pa * ".meta", String) == "0 0.0"                        # verify writes nothing
            empty!(store.calls)
            @test ATT.repair!(copy).attachments_repaired == 1
            @test !any(c -> c[1] == :fetch_object_to, store.calls) && ATT.attachment(copy, ha) == pa
            # gone from the chain's store as well: repair! cannot bring them back. It finishes the pass —
            # a damaged entry the store still holds is fetched again — then drops the markers of the
            # absent ones and raises once, naming each; the next repair! and verify pass
            c = rand(UInt8, 50); hc = ATT.put_attachment(chain, IOBuffer(c)); pc = ATT.attachment(copy, hc)
            for h in (ha, hc)
                delete!(store.objects, "p/_attachments/$h")
                p = ATT.attachment_cache_path(chain.cache, h); chmod(p, 0o644); rm(p)
            end
            chmod(pb, 0o644); write(pb, rand(UInt8, 400)); chmod(pb, 0o444)
            gone = sort([ha, hc])
            e = try ATT.repair!(copy); nothing catch e; e end
            @test e isa ATT.AttachmentAbsentError && e.chain_id == copy.head.chain_id && e.key === nothing
            @test sprint(showerror, e) == "AttachmentAbsentError: attachment absent: repair!(copy) found that the store " *
                "of the chain at bkt/p no longer holds 2 attachments this copy had confirmed: " *
                "$(join(("p/_attachments/" * h for h in gone), ", ")). Their retention ended and they were deleted, or " *
                "the bucket was written from outside the protocol. Their confirmed markers were removed, so a read of one " *
                "raises this again and verify no longer covers them; the rest of the repair ran. Only someone holding a " *
                "file can bring it back, with put_attachment(chain, file) (ADR-0046)."
            @test read(pb) == b                                                 # the pass went on
            @test !isfile(joinpath(copy.path, "confirmed", ha)) && !isfile(joinpath(copy.path, "confirmed", hc))
            @test ATT.repair!(copy).attachments_repaired == 0 && ATT.verify(copy; full = true) === nothing
            e = try ATT.attachment(copy, ha); nothing catch e; e end
            @test e isa ATT.AttachmentAbsentError && e.key == "p/_attachments/$ha" && e.chain_id == copy.head.chain_id
            @test sprint(showerror, e) == "AttachmentAbsentError: attachment absent: the store of the chain at bkt/p holds " *
                "no attachment p/_attachments/$ha — it was never put to this chain, or its retention ended and it was " *
                "deleted — so attachment(copy, hash) has nothing to serve, whatever this machine has cached. Only someone " *
                "holding the file can bring it back, with put_attachment(chain, file) (ADR-0046)."
            # one alone is named in the error's key
            delete!(store.objects, "p/_attachments/$hb"); chmod(pb, 0o644); rm(pb)
            e = try ATT.repair!(copy); nothing catch e; e end
            @test e isa ATT.AttachmentAbsentError && e.key == "p/_attachments/$hb"
            @test occursin("no longer holds 1 attachment this copy had confirmed: p/_attachments/$hb. Its retention ended " *
                           "and it was deleted", sprint(showerror, e))
        end
    end

    @testset "repair!(copy) removes no confirmed marker when the pass raises before its end" begin
        mktempdir() do dir
            store = InMemoryObjectStore()
            chain = Chain("bkt", "p"; store, cache_dir = joinpath(dir, "cache"), record_host = false, record_user = false)
            ATT.create_chain(chain)
            copy = ATT.open(chain, joinpath(dir, "one"))
            ATT.sync!(copy)
            x, y = rand(UInt8, 30), rand(UInt8, 40)
            hx, hy = bytes2hex(sha256(x)), bytes2hex(sha256(y))
            # confirmed_hashes sorts: the one gone from the store comes first
            (gone, hgone), (bad, hbad) = hx < hy ? ((x, hx), (y, hy)) : ((y, hy), (x, hx))
            @test ATT.put_attachment(chain, IOBuffer(gone)) == hgone && ATT.put_attachment(chain, IOBuffer(bad)) == hbad
            pgone, pbad = ATT.attachment(copy, hgone), ATT.attachment(copy, hbad)
            kgone, kbad = "p/_attachments/$hgone", "p/_attachments/$hbad"
            delete!(store.objects, kgone); chmod(pgone, 0o644); rm(pgone)
            chmod(pbad, 0o644); rm(pbad)
            wrong = rand(UInt8, 40); found = bytes2hex(sha256(wrong))
            store.objects[kbad] = wrong
            e = try ATT.repair!(copy); nothing catch e; e end
            @test e isa ATT.AttachmentDigestError
            @test sprint(showerror, e) == "AttachmentDigestError: attachment digest: the store of the chain at bkt/p " *
                "returned 40 bytes for $kbad, which hash to $found, not to the key's hash. Nothing was cached. S3 checked " *
                "the hash when the attachment was stored, so the bucket was written from outside the protocol: stop and " *
                "report it (ADR-0046)."
            @test isfile(joinpath(copy.path, "confirmed", hgone))              # not removed, so reported next time
            store.objects[kbad] = bad
            e = try ATT.repair!(copy); nothing catch e; e end
            @test e isa ATT.AttachmentAbsentError && e.key == kgone
            @test !isfile(joinpath(copy.path, "confirmed", hgone)) && read(pbad) == bad
        end
    end

    @testset "heal_entry: a file changed while it is hashed is :changed; one renamed onto its path keeps the hashed file's stat" begin
        mktempdir() do dir
            store = InMemoryObjectStore()
            chain = Chain("bkt", "p"; store, cache_dir = joinpath(dir, "cache"), record_host = false, record_user = false)
            ATT.create_chain(chain)
            copy = ATT.open(chain, joinpath(dir, "one"))
            ATT.sync!(copy)
            bytes = rand(UInt8, 100)
            h = ATT.put_attachment(chain, IOBuffer(bytes))
            path = ATT.attachment(copy, h)
            function reset!()
                chmod(path, 0o644); write(path, bytes); chmod(path, 0o444)
                write(path * ".meta", "100 0.0")
            end
            # hashed right, then a byte appended before the stat after: not healed
            grow = io -> (d = ATT.hash_file(io); chmod(path, 0o644); Base.open(f -> write(f, 0x00), path, "a"); d)
            reset!()
            @test ATT.heal_entry(path, h; hasher = grow) === :changed
            @test read(path * ".meta", String) == "100 0.0"
            # another file with the same bytes renamed onto the path mid-hash: the sidecar records
            # the file that was hashed, not the one now at the path — the next read heals that
            swap = io -> (d = ATT.hash_file(io); write(path * ".other", bytes); ATT.replace_file(path * ".other", path); d)
            reset!()
            hashed = ATT.sidecar_text(stat(path))
            @test ATT.heal_entry(path, h; hasher = swap) === :ok
            @test read(path * ".meta", String) == hashed != ATT.sidecar_text(stat(path))
            # through attachment(copy, hash): raised, nothing fetched
            reset!()
            empty!(store.calls)
            e = try ATT.read_attachment(copy, h; hasher = grow); nothing catch e; e end
            @test e isa ATT.AttachmentCacheError && e.path == path && e.key == "p/_attachments/$h"
            @test e.chain_id == copy.head.chain_id
            @test sprint(showerror, e) == "AttachmentCacheError: attachment cache: the cached file $path changed while it " *
                "was being hashed, so something other than ChainTables writes to this cache, which ChainTables keeps " *
                "read-only: stop it. The cache is damaged, not the chain: deleting $path and $path.meta is always safe, " *
                "and the next read fetches it again (ADR-0046)."
            @test isempty(store.calls)
            # repair!: removed and fetched again
            reset!()
            empty!(store.calls)
            @test ATT.repair_attachments!(copy, chain; hasher = grow) == 1
            @test store.calls == [(:fetch_object_to, "p/_attachments/$h")] && read(path) == bytes
            @test read(path * ".meta", String) == ATT.sidecar_text(stat(path))
        end
    end
end
