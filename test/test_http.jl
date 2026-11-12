# The streamed transfer has no API name of its own (attachments use it), so these tests
# call it directly.
using Test
using ChainTables: ChainTables, Credentials, S3ObjectStore, TransportError
using SHA: sha256
using StableRNGs: StableRNG

include("fixtures/s3_server.jl")

const HTTP = ChainTables
const SESSION = Credentials("AKIATEST", "topsecret"; session_token = "session-token")
# Over libcurl's 1 MiB threshold for `Expect: 100-continue`.
const BYTES = rand(StableRNG(1), UInt8, 3 * 1024 * 1024 + 7)
const BYTES_HASH = bytes2hex(sha256(BYTES))
const KEY = "p/_attachments/" * BYTES_HASH

function loopback_store(server)
    return S3ObjectStore(
        "bkt"; region = "eu-north-1", credentials = SESSION,
        endpoint = s3test_endpoint(server), path_style = true, timeout = 30
    )
end

function with_stored_bytes(f)
    return with_s3_server(; bucket = "bkt", credentials = SESSION) do server
        s3test_store!(server, KEY, BYTES)
        mktempdir() do dir
            f(server, loopback_store(server), dir)
        end
    end
end

@testset "http_stream PUTs a file signed with its hash and length" begin
    with_s3_server(; bucket = "bkt", credentials = SESSION) do server
        store = loopback_store(server)
        req = HTTP.request_headers(
            store, "PUT", KEY; payload_hash = BYTES_HASH, content_length = length(BYTES),
            headers = ["if-none-match" => "*"]
        )
        input = IOBuffer(BYTES)
        response = HTTP.http_stream(req.url, "PUT", req.headers; input, stall = 30)
        @test response.status == 200
        @test server.objects[KEY] == BYTES
        put = only(server.requests)
        @test put.headers["x-amz-content-sha256"] == BYTES_HASH
        @test put.headers["content-length"] == string(length(BYTES))
    end
end

@testset "fetch_object_to streams an object into a file" begin
    with_stored_bytes() do server, store, dir
        path = joinpath(dir, "dst")
        @test HTTP.fetch_object_to(store, KEY, path) == length(BYTES)
        @test read(path) == BYTES
    end
end

@testset "fetch_object_to leaves no file for an absent key" begin
    with_stored_bytes() do server, store, dir
        path = joinpath(dir, "gone")
        @test HTTP.fetch_object_to(store, "p/_attachments/" * "0"^64, path) === nothing
        @test !ispath(path)
    end
end

@testset "fetch_object_to raises a refusal and leaves no file" begin
    with_stored_bytes() do server, store, dir
        server.respond = _ -> s3test_refusal(403, "AccessDenied", "Access Denied")
        path = joinpath(dir, "gone")
        url = "http://127.0.0.1:$(server.port)/bkt/$KEY"
        says = "GET $url: AccessDenied: Access Denied"
        e = (@test_throws TransportError says HTTP.fetch_object_to(store, KEY, path)).value
        @test e.status == 403
        @test !ispath(path)
    end
end

const REDIRECT = s3test_error("TemporaryRedirect", "Re-send.")

function redirecting(server)
    return req -> req.rawpath == "/elsewhere" ? (200, Pair{String, String}[], b"followed") :
        (307, ["location" => "$(s3test_endpoint(server))/elsewhere"], REDIRECT)
end

@testset "fetch_object_to never follows a redirect" begin
    with_stored_bytes() do server, store, dir
        server.respond = redirecting(server)
        path = joinpath(dir, "gone")
        says = "TemporaryRedirect: Re-send."
        e = (@test_throws TransportError says HTTP.fetch_object_to(store, KEY, path)).value
        @test e.status == 307
        @test length(server.requests) == 1 && !ispath(path)
    end
end

@testset "http_stream never follows a redirect of a PUT" begin
    with_stored_bytes() do server, store, dir
        server.respond = redirecting(server)
        headers = ["content-length" => string(length(BYTES))]
        url = "$(s3test_endpoint(server))/bkt/x"
        input = IOBuffer(BYTES)
        response = HTTP.http_stream(url, "PUT", headers; input, stall = 30)
        @test response.status == 307 && length(server.requests) == 1
    end
end

@testset "http_stream refuses a PUT without content-length" begin
    no_headers = Pair{String, String}[]
    says = "a streamed PUT needs a content-length header"
    @test_throws ArgumentError says HTTP.http_stream(
        "http://127.0.0.1:1/x", "PUT", no_headers; input = IOBuffer(BYTES), stall = 30
    )
end

@testset "http_stream refuses a stall or deadline that is not positive" begin
    url = "http://127.0.0.1:1/x"
    @test_throws ArgumentError "stall is 0 seconds; it must be positive" HTTP.http_stream(
        url, "GET", Pair{String, String}[]; stall = 0
    )
    @test_throws ArgumentError "deadline is 0 seconds" HTTP.http_stream(
        url, "GET", Pair{String, String}[]; stall = 1, deadline = 0
    )
end

# A peer that accepts and never answers; `held` keeps its connections open.
function with_mute_peer(f)
    mute = listen(ip"127.0.0.1", 0)
    held = Any[]
    hold = sock -> (push!(held, sock); wait(Timer(30)))
    errormonitor(@async serve_connections(mute, hold))
    return try
        f(Int(getsockname(mute)[2]))
    finally
        close(mute)
    end
end

@testset "http_stream raises a stall as no response, without status" begin
    with_mute_peer() do port
        url = "http://127.0.0.1:$port/bkt/k"
        e = (
            @test_throws TransportError "GET $url: no response" HTTP.http_stream(
                url, "GET", Pair{String, String}[]; output = IOBuffer(), stall = 1
            )
        ).value
        @test e.status === nothing
    end
end

@testset "http_stream leaves the query out of its message" begin
    with_mute_peer() do port
        url = "http://127.0.0.1:$port/bkt/k?X-Amz-Signature=secret"
        e = (
            @test_throws TransportError "no response" HTTP.http_stream(
                url, "GET", Pair{String, String}[]; stall = 1, deadline = 1
            )
        ).value
        @test !occursin("secret", sprint(showerror, e))
    end
end

const XML_CASES = [
    (
        name = "entities",
        s = "a&amp;b&lt;c&gt;d&quot;e&apos;f&#65;&#x42;",
        text = "a&b<c>d\"e'fAB",
    ),
    (name = "plain", s = "plain", text = "plain"),
]

@testset "xml_unescape: $(case.name)" for case in XML_CASES
    @test HTTP.xml_unescape(case.s) == case.text
end
