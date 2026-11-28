# The streamed transfer of an attachment (ADR-0046) is internal: no API name reaches it
# without a gateway or the attachment cache. So these tests call `fetch_object_to`,
# `request_headers` and `http_stream`.
using Test
using SHA: sha256
using StableRNGs: StableRNG
using Sockets: @ip_str, accept, getsockname, listen
using ChainTables: ChainTables, Chain, Credentials, TransportError, fetch_object_to,
    http_stream, request_headers

include("fixtures/s3_server.jl")

const CREDENTIALS = Credentials("AKIATEST", "topsecret"; session_token = "tok")
# Over libcurl's 1 MiB threshold for `Expect: 100-continue`.
const BYTES = rand(StableRNG(1), UInt8, 3 * 1024 * 1024 + 7)
const BYTES_HASH = bytes2hex(sha256(BYTES))
const ATTACHMENT_KEY = "p/_attachments/" * BYTES_HASH
const ABSENT_KEY = "p/_attachments/" * "0"^64
const REDIRECT = s3test_error("TemporaryRedirect", "Please re-send this request.")

function s3_store(server)
    chain = Chain(
        "bkt", "p"; region = "eu-north-1", credentials = CREDENTIALS,
        endpoint = s3test_endpoint(server), path_style = true, cache_dir = "/c",
    )
    return chain.store
end

function with_streaming_server(f)
    with_s3_server(; bucket = "bkt", credentials = CREDENTIALS) do server
        mktempdir() do dir
            write(joinpath(dir, "source"), BYTES)
            f(server, s3_store(server), dir)
        end
    end
    return nothing
end

function put_from_file(store, path)
    request = request_headers(
        store, "PUT", ATTACHMENT_KEY; payload_hash = BYTES_HASH,
        content_length = length(BYTES), headers = ["if-none-match" => "*"],
    )
    return Base.open(path) do io
        http_stream("PUT", request.url; request.headers, input = io, stall = 30)
    end
end

# A peer that accepts a connection and never answers.
function with_mute_peer(f)
    socket = listen(ip"127.0.0.1", 0)
    held = Any[]
    accepting = @async try_hold(socket, held)
    try
        return f(Int(getsockname(socket)[2]))
    finally
        close(socket)
        foreach(close, held)
        wait(accepting)
    end
end

function try_hold(socket, held)
    while isopen(socket)
        connection = try
            accept(socket)
        catch e
            e isa Base.IOError || rethrow()
            return nothing
        end
        push!(held, connection)
    end
    return nothing
end

@testset "http_stream puts from a file with the hash and the length given" begin
    with_streaming_server() do server, store, dir
        response = put_from_file(store, joinpath(dir, "source"))
        @test response.status == 200
        @test server.objects[ATTACHMENT_KEY] == BYTES
        put = only(server.requests)
        @test put.headers["x-amz-content-sha256"] == BYTES_HASH
        @test put.headers["content-length"] == string(length(BYTES))
    end
end

@testset "fetch_object_to streams an object into a file" begin
    with_streaming_server() do server, store, dir
        put_from_file(store, joinpath(dir, "source"))
        target = joinpath(dir, "target")
        @test fetch_object_to(store, ATTACHMENT_KEY, target) == length(BYTES)
        @test read(target) == BYTES
    end
end

@testset "fetch_object_to leaves no file for an absent key" begin
    with_streaming_server() do server, store, dir
        target = joinpath(dir, "target")
        @test fetch_object_to(store, ABSENT_KEY, target) === nothing
        @test !ispath(target)
    end
end

@testset "fetch_object_to throws TransportError for a refusal, and leaves no file" begin
    with_streaming_server() do server, store, dir
        target = joinpath(dir, "target")
        server.respond = _ -> (403, [], s3test_error("AccessDenied", "Access Denied"))
        err = (
            @test_throws TransportError "AccessDenied: Access Denied" fetch_object_to(
                store, ATTACHMENT_KEY, target
            )
        ).value
        @test err.status == 403
        @test err.url == "$(s3test_endpoint(server))/bkt/$ATTACHMENT_KEY"
        @test !ispath(target)
    end
end

@testset "fetch_object_to does not follow a redirect" begin
    with_streaming_server() do server, store, dir
        elsewhere = "$(s3test_endpoint(server))/elsewhere"
        server.respond = request -> request.rawpath == "/elsewhere" ?
            (200, [], b"followed") : (307, ["location" => elsewhere], REDIRECT)
        target = joinpath(dir, "target")
        err = (
            @test_throws TransportError "TemporaryRedirect" fetch_object_to(
                store, ATTACHMENT_KEY, target
            )
        ).value
        @test err.status == 307
        @test length(server.requests) == 1
        @test !ispath(target)
    end
end

@testset "http_stream does not follow a redirect on a PUT" begin
    with_streaming_server() do server, store, dir
        location = "location" => "$(s3test_endpoint(server))/x"
        server.respond = _ -> (307, [location], REDIRECT)
        @test put_from_file(store, joinpath(dir, "source")).status == 307
        @test length(server.requests) == 1
    end
end

@testset "http_stream refuses a PUT without content-length" begin
    put = () -> http_stream("PUT", "http://127.0.0.1:1/bkt/x"; headers = [], stall = 30)
    @test_throws ArgumentError "a streamed PUT needs a content-length header" put()
end

@testset "http_stream refuses a stall of zero seconds" begin
    @test_throws ArgumentError "stall is 0 seconds; it must be positive" http_stream(
        "GET", "http://127.0.0.1:1/bkt/x"; headers = [], stall = 0
    )
end

@testset "http_stream throws TransportError with no status after a stall" begin
    with_mute_peer() do port
        url = "http://127.0.0.1:$port/bkt/k?X-Amz-Signature=secret"
        err = (
            @test_throws TransportError "no response" http_stream(
                "GET", url; headers = [], output = IOBuffer(), stall = 1
            )
        ).value
        @test err.status === nothing
        @test err.url == "http://127.0.0.1:$port/bkt/k"
    end
end
