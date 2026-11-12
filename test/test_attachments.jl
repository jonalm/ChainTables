using Test
using ChainTables: ChainTables, AttachmentAbsentError, AttachmentChangedError, Chain,
    Credentials, S3ObjectStore, TransportError, put_attachment, touch_attachment
using ChainTables.Testing: InMemoryObjectStore
using SHA: sha256
using StableRNGs: StableRNG

include("fixtures/attachments.jl")
include("fixtures/s3_server.jl")

const BYTES = rand(StableRNG(1), UInt8, 1000)
const HASH = bytes2hex(sha256(BYTES))
const S3_CREDENTIALS = Credentials("AKIATEST", "topsecret")

hash_of(bytes) = bytes2hex(sha256(bytes))

"""
    with_s3_store(f)

Call `f(server, store)` with a loopback S3 and a plain-bucket store on it; close the
server after.
"""
function with_s3_store(f)
    server = S3TestServer(; bucket = "bkt", credentials = S3_CREDENTIALS)
    try
        store = S3ObjectStore(
            "bkt"; region = "eu-north-1", credentials = S3_CREDENTIALS,
            endpoint = s3test_endpoint(server), path_style = true
        )
        f(server, store)
    finally
        close(server)
    end
    return nothing
end

@testset "put_attachment stores a file under the chain's prefix and returns its hash" begin
    mktempdir() do dir
        store = InMemoryObjectStore()
        path = joinpath(dir, "a.bin")
        write(path, BYTES)
        @test put_attachment(memory_chain(dir, store), path) == HASH
        @test store.objects["p/_attachments/$HASH"] == BYTES
    end
end

@testset "put_attachment of a present attachment stores nothing again" begin
    mktempdir() do dir
        store = InMemoryObjectStore()
        chain = memory_chain(dir, store)
        put_attachment(chain, IOBuffer(BYTES))
        @test put_attachment(chain, IOBuffer(BYTES)) == HASH
        @test count_calls(store, :put_attachment) == 2
        @test store.objects["p/_attachments/$HASH"] == BYTES
    end
end

@testset "put_attachment takes an empty attachment" begin
    mktempdir() do dir
        store = InMemoryObjectStore()
        chain = memory_chain(dir, store)
        @test put_attachment(chain, IOBuffer(UInt8[])) == hash_of(UInt8[])
    end
end

@testset "put_attachment on the bucket root's chain stores under _attachments" begin
    mktempdir() do dir
        store = InMemoryObjectStore()
        put_attachment(memory_chain(dir, store; prefix = ""), IOBuffer(BYTES))
        @test haskey(store.objects, "_attachments/$HASH")
    end
end

const PUT_MISUSES = [
    (
        name = "a non-seekable IO", arg = dir -> Base.BufferStream(),
        message = "a Base.BufferStream cannot seek, so it cannot be hashed",
    ),
    (
        name = "an IO not at its start", arg = dir -> skip(IOBuffer(BYTES), 1),
        message = "an attachment's IO must stand at its start, not at byte 1",
    ),
    (
        name = "a missing file", arg = dir -> joinpath(dir, "absent"),
        message = "put_attachment: no file at",
    ),
    (name = "a directory", arg = dir -> dir, message = "is a directory, not a file"),
]

@testset "put_attachment refuses $(case.name) before any request" for case in PUT_MISUSES
    mktempdir() do dir
        store = InMemoryObjectStore()
        chain = memory_chain(dir, store)
        @test_throws ArgumentError case.message put_attachment(chain, case.arg(dir))
        @test isempty(store.calls)
    end
end

"""
    fail_first(verb, phase, exception)

A `fault` that throws `exception` on the first `verb` request at `phase`, then never.
"""
function fail_first(verb, phase, exception)
    failed = Ref(false)
    return function (v, key, p)
        (v === verb && p === phase && !failed[]) || return nothing
        failed[] = true
        throw(exception)
    end
end

@testset "put_attachment retries a failure before the request lands" begin
    mktempdir() do dir
        store = InMemoryObjectStore()
        unavailable = TransportError("x"; status = 503)
        store.fault = fail_first(:put_attachment, :before, unavailable)
        @test put_attachment(memory_chain(dir, store), IOBuffer(BYTES)) == HASH
        @test store.objects["p/_attachments/$HASH"] == BYTES
        @test count_calls(store, :put_attachment) == 2
    end
end

@testset "put_attachment retries a lost acknowledgement, which then finds it present" begin
    mktempdir() do dir
        store = InMemoryObjectStore()
        store.fault = fail_first(:put_attachment, :after, TransportError("lost"))
        @test put_attachment(memory_chain(dir, store), IOBuffer(BYTES)) == HASH
        @test count_calls(store, :put_attachment) == 2
    end
end

@testset "put_attachment gives up after PUT_ATTEMPTS and throws the last failure" begin
    mktempdir() do dir
        store = InMemoryObjectStore()
        down = TransportError("down"; status = 429)
        store.fault = (verb, key, phase) -> verb === :put_attachment && throw(down)
        chain = memory_chain(dir, store)
        @test thrown(() -> put_attachment(chain, IOBuffer(BYTES))) === down
        @test count_calls(store, :put_attachment) == ChainTables.PUT_ATTEMPTS
    end
end

const NOT_RETRIED = [
    (name = "a 403", exception = TransportError("forbidden"; status = 403)),
    (name = "a changed file", exception = AttachmentChangedError(; detail = "changed")),
    (name = "a bug", exception = ErrorException("bug")),
]

@testset "put_attachment does not retry $(case.name)" for case in NOT_RETRIED
    mktempdir() do dir
        store = InMemoryObjectStore()
        (; exception) = case
        store.fault = (verb, key, phase) -> verb === :put_attachment && throw(exception)
        chain = memory_chain(dir, store)
        @test thrown(() -> put_attachment(chain, IOBuffer(BYTES))) === case.exception
        @test count_calls(store, :put_attachment) == 1
    end
end

@testset "put_attachment(chain, io) infers its String" begin
    mktempdir() do dir
        chain = memory_chain(dir, InMemoryObjectStore())
        @test @inferred(put_attachment(chain, IOBuffer(BYTES))) == HASH
    end
end

@testset "touch_attachment of a present attachment on a plain store is one HEAD" begin
    mktempdir() do dir
        store = InMemoryObjectStore()
        chain = memory_chain(dir, store)
        put_attachment(chain, IOBuffer(BYTES))
        empty!(store.calls)
        @test @inferred(touch_attachment(chain, HASH)) === nothing
        @test store.calls == [(:stat_object, "p/_attachments/$HASH")]
    end
end

@testset "touch_attachment of an absent attachment throws AttachmentAbsentError" begin
    mktempdir() do dir
        absent = hash_of(b"never stored")
        e = thrown(() -> touch_attachment(memory_chain(dir, InMemoryObjectStore()), absent))
        @test e isa AttachmentAbsentError
        @test e.key == "p/_attachments/$absent"
        @test occursin("the store of bkt/p lacks it", sprint(showerror, e))
    end
end

const BAD_HASHES = [
    (name = "uppercase", hex = uppercase(HASH)),
    (name = "too short", hex = HASH[1:63]),
    (name = "too long", hex = HASH * "0"),
    (name = "a path", hex = "../" * HASH[4:end]),
]

@testset "touch_attachment refuses $(case.name) hex before any request" for case in
    BAD_HASHES
    mktempdir() do dir
        store = InMemoryObjectStore()
        message = "$(repr(case.hex)) is not an attachment hash"
        chain = memory_chain(dir, store)
        @test_throws ArgumentError message touch_attachment(chain, case.hex)
        @test isempty(store.calls)
    end
end

@testset "touch_attachment retries a retryable failure of the HEAD" begin
    mktempdir() do dir
        store = InMemoryObjectStore()
        chain = memory_chain(dir, store)
        put_attachment(chain, IOBuffer(BYTES))
        store.fault = fail_first(:stat_object, :before, TransportError("x"; status = 500))
        @test touch_attachment(chain, HASH) === nothing
        @test count_calls(store, :stat_object) == 2
    end
end

@testset "touch_attachment(store, key) is true only for a present key" begin
    store = InMemoryObjectStore()
    key = "p/_attachments/$HASH"
    @test @inferred(touch_attachment(store, key)) == false
    put_attachment(store, key, IOBuffer(BYTES))
    @test touch_attachment(store, key) == true
end

@testset "put_attachment on a plain bucket is one streamed PUT with the checksum" begin
    with_s3_store() do server, store
        key = "p/_attachments/$HASH"
        @test @inferred(put_attachment(store, key, IOBuffer(BYTES))) == true
        @test server.objects[key] == BYTES
        put = only(server.requests)
        @test put.headers["if-none-match"] == "*"
        @test put.headers["content-type"] == "application/octet-stream"
        # base64 of the digest, not hex
        @test put.headers["x-amz-checksum-sha256"] == ChainTables.checksum_sha256(HASH)
        @test put.headers["x-amz-content-sha256"] == HASH
        signed = "SignedHeaders=content-type;host;if-none-match;x-amz-checksum-sha256;" *
            "x-amz-content-sha256;x-amz-date,"
        @test occursin(signed, put.headers["authorization"])
    end
end

@testset "put_attachment on a plain bucket answers false for a present key" begin
    with_s3_store() do server, store
        key = "p/_attachments/$HASH"
        put_attachment(store, key, IOBuffer(BYTES))
        @test put_attachment(store, key, IOBuffer(BYTES)) == false
        @test length(server.requests) == 2
    end
end

@testset "put_attachment on a plain bucket refuses other bytes as a changed file" begin
    with_s3_store() do server, store
        other = "p/_attachments/" * "0"^64
        e = thrown(() -> put_attachment(store, other, IOBuffer(BYTES)))
        @test e isa AttachmentChangedError
        @test e.key == other
        url = "$(s3test_endpoint(server))/bkt/$other"
        @test occursin("S3 at $url answered BadDigest", sprint(showerror, e))
        @test !haskey(server.objects, other)
    end
end

@testset "put_attachment on a plain bucket reads S3's BadDigest as a changed file" begin
    with_s3_store() do server, store
        digest = s3test_error("BadDigest", "The SHA256 you specified did not match.")
        server.respond = req -> (400, [], digest)
        key = "p/_attachments/$HASH"
        @test_throws AttachmentChangedError "answered BadDigest" put_attachment(
            store, key, IOBuffer(BYTES)
        )
    end
end

@testset "put_attachment on a plain bucket throws S3's other refusals as is" begin
    with_s3_store() do server, store
        server.respond = req -> (403, [], s3test_error("AccessDenied", "Access Denied"))
        key = "p/_attachments/$HASH"
        e = thrown(() -> put_attachment(store, key, IOBuffer(BYTES)))
        @test e isa TransportError
        @test e.status == 403
        url = "$(s3test_endpoint(server))/bkt/$key"
        @test occursin("PUT $url: AccessDenied", sprint(showerror, e))
    end
end

const NOT_ATTACHMENT_KEYS = [
    (name = "a slot key", key = "p/000000000001"),
    (name = "an uppercase hash", key = "p/_attachments/" * uppercase(HASH)),
]

@testset "put_attachment(store, …) refuses $(case.name) before any request" for case in
    NOT_ATTACHMENT_KEYS
    with_s3_store() do server, store
        message = "$(repr(case.key)) is not an attachment key"
        @test_throws ArgumentError message put_attachment(store, case.key, IOBuffer(BYTES))
        @test isempty(server.requests)
    end
end

@testset "AttachmentHash is equal and hashes equal for equal hex" begin
    a = ChainTables.AttachmentHash(HASH)
    b = ChainTables.AttachmentHash(String(collect(HASH)))
    @test a == b
    @test (a == b) isa Bool
    @test length(Set([a, b])) == 1
    @test Dict(a => 1)[b] == 1
end
