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

    @testset "through a gateway: put retries session_ending" begin
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
            finally
                close(gw); close(s3)
            end
        end
    end
end
