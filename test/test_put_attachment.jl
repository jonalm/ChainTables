using Test
using ChainTables: ChainTables, AttachmentChangedError, Chain, Credentials,
    TransportError, put_attachment
using ChainTables.Testing: InMemoryObjectStore

include("fixtures/attachments.jl")
include("fixtures/chain_copies.jl")
include("fixtures/s3_server.jl")

const CREDENTIALS = Credentials("AKIATEST", "topsecret")
const BYTES = attachment_bytes(1000)
const H = sha256_hex(BYTES)
const RETRY_LATER = "The failure may pass"

const NOT_RETRIED = [
    (name = "a refused request", failure = transport_failure(403)),
    (name = "bytes that changed", failure = AttachmentChangedError(; key = "k")),
    (name = "a bug", failure = ErrorException("bug")),
]

const BAD_DIGESTS = [
    (name = "the checksum header", code = "BadDigest"),
    (name = "the signed payload hash", code = "XAmzContentSHA256Mismatch"),
]

const SIGNED_HEADERS = "SignedHeaders=content-type;host;if-none-match;" *
    "x-amz-checksum-sha256;x-amz-content-sha256;x-amz-date,"

function s3_chain(server)
    return Chain(
        "bkt", "p"; region = "eu-north-1", credentials = CREDENTIALS,
        endpoint = s3test_endpoint(server), path_style = true, cache_dir = "/c",
    )
end

with_plain_s3(f) = with_s3_server(f; bucket = "bkt", credentials = CREDENTIALS)

@testset "put_attachment stores a file's bytes under the chain's prefix" begin
    mktempdir() do dir
        chain = chain_in(dir)
        path = joinpath(dir, "a.bin")
        write(path, BYTES)
        @test put_attachment(chain, path) == H
        @test chain.store.objects["p/_attachments/$H"] == BYTES
    end
end

@testset "put_attachment of an attachment that is present sends no bytes again" begin
    mktempdir() do dir
        chain = chain_in(dir)
        put_attachment(chain, IOBuffer(BYTES))
        @test put_attachment(chain, IOBuffer(BYTES)) == H
        @test n_calls(chain.store, :put_attachment) == 2
        @test length(chain.store.objects) == 1
    end
end

@testset "put_attachment reads a seekable IO at its start" begin
    mktempdir() do dir
        chain = chain_in(dir)
        @test @inferred(put_attachment(chain, IOBuffer(BYTES))) == H
    end
end

@testset "put_attachment stores an empty attachment" begin
    mktempdir() do dir
        chain = chain_in(dir)
        @test put_attachment(chain, IOBuffer(UInt8[])) == sha256_hex(UInt8[])
    end
end

@testset "put_attachment on a chain at the bucket's root has no prefix in its key" begin
    mktempdir() do dir
        chain = chain_in(dir; prefix = "")
        put_attachment(chain, IOBuffer(BYTES))
        @test haskey(chain.store.objects, "_attachments/$H")
    end
end

@testset "put_attachment refuses an IO that cannot seek, before any request" begin
    mktempdir() do dir
        chain = chain_in(dir)
        fragment = "a Base.BufferStream cannot seek, so it cannot be hashed"
        @test_throws ArgumentError fragment put_attachment(chain, Base.BufferStream())
        @test isempty(chain.store.calls)
    end
end

@testset "put_attachment refuses an IO that does not stand at its start" begin
    mktempdir() do dir
        chain = chain_in(dir)
        io = IOBuffer(BYTES)
        read(io, UInt8)
        fragment = "an attachment's IO must stand at its start, not at byte 1"
        @test_throws ArgumentError fragment put_attachment(chain, io)
        @test isempty(chain.store.calls)
    end
end

@testset "put_attachment refuses a path with no file" begin
    mktempdir() do dir
        chain = chain_in(dir)
        absent = joinpath(dir, "absent")
        @test_throws ArgumentError "put_attachment: no file at $absent" put_attachment(
            chain, absent
        )
        @test_throws ArgumentError "put_attachment: $dir is a directory, not a file" (
            put_attachment(chain, dir)
        )
        @test isempty(chain.store.calls)
    end
end

@testset "put_attachment tries again after a request that never arrived" begin
    mktempdir() do dir
        fault = FailingRequests(:put_attachment, :before, 1, transport_failure(503))
        chain = chain_in(dir; store = InMemoryObjectStore(; fault))
        @test put_attachment(chain, IOBuffer(BYTES)) == H
        @test chain.store.objects["p/_attachments/$H"] == BYTES
        @test n_calls(chain.store, :put_attachment) == 2
    end
end

@testset "put_attachment tries again after a lost answer, and finds it present" begin
    mktempdir() do dir
        fault = FailingRequests(:put_attachment, :after, 1, transport_failure(nothing))
        chain = chain_in(dir; store = InMemoryObjectStore(; fault))
        @test put_attachment(chain, IOBuffer(BYTES)) == H
        @test n_calls(chain.store, :put_attachment) == 2
    end
end

@testset "put_attachment throws the last failure after 4 attempts" begin
    mktempdir() do dir
        failure = transport_failure(429)
        fault = FailingRequests(:put_attachment, :before, typemax(Int), failure)
        chain = chain_in(dir; store = InMemoryObjectStore(; fault))
        io = IOBuffer(BYTES)
        err = @test_throws TransportError RETRY_LATER put_attachment(chain, io)
        @test err.value === failure
        @test n_calls(chain.store, :put_attachment) == 4
    end
end

@testset "put_attachment does not try again after $(case.name)" for case in NOT_RETRIED
    mktempdir() do dir
        fault = FailingRequests(:put_attachment, :before, 1, case.failure)
        chain = chain_in(dir; store = InMemoryObjectStore(; fault))
        thrown = try
            put_attachment(chain, IOBuffer(BYTES))
        catch e
            e
        end
        @test thrown === case.failure
        @test n_calls(chain.store, :put_attachment) == 1
    end
end

@testset "put_attachment on a plain bucket sends one streamed PUT" begin
    with_plain_s3() do server
        bytes = attachment_bytes(2 * 1024 * 1024)
        h = sha256_hex(bytes)
        @test put_attachment(s3_chain(server), IOBuffer(bytes)) == h
        @test server.objects["p/_attachments/$h"] == bytes
        put = only(server.requests)
        @test (put.method, put.path) == ("PUT", "/bkt/p/_attachments/$h")
        @test put.headers["if-none-match"] == "*"
        @test put.headers["content-type"] == "application/octet-stream"
        @test put.headers["x-amz-checksum-sha256"] == base64encode(sha256(bytes))
        @test put.headers["x-amz-content-sha256"] == h
        @test occursin(SIGNED_HEADERS, put.headers["authorization"])
    end
end

@testset "put_attachment on a plain bucket that holds it sends one refused PUT" begin
    with_plain_s3() do server
        chain = s3_chain(server)
        put_attachment(chain, IOBuffer(BYTES))
        @test put_attachment(chain, IOBuffer(BYTES)) == H
        @test [request.method for request in server.requests] == ["PUT", "PUT"]
    end
end

@testset "put_attachment on a plain bucket refused by $(case.name)" for case in BAD_DIGESTS
    with_plain_s3() do server
        server.respond = _ -> (400, [], s3test_error(case.code, "no match"))
        fragment = "the file changed between hashing and upload"
        err = @test_throws AttachmentChangedError fragment put_attachment(
            s3_chain(server), IOBuffer(BYTES)
        )
        @test (err.value.bucket, err.value.key) == ("bkt", "p/_attachments/$H")
        @test length(server.requests) == 1
    end
end

@testset "put_attachment on a plain bucket throws S3's refusal, not tried again" begin
    with_plain_s3() do server
        server.respond = _ -> (403, [], s3test_error("AccessDenied", "Access Denied"))
        err = @test_throws TransportError "A retry will not help" put_attachment(
            s3_chain(server), IOBuffer(BYTES)
        )
        @test err.value.status == 403
        @test err.value.url == "$(s3test_endpoint(server))/bkt/p/_attachments/$H"
        @test err.value.detail == "AccessDenied: Access Denied"
        @test length(server.requests) == 1
    end
end
