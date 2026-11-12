using Test
using ChainTables: ChainTables, AttachmentAbsentError, AttachmentChangedError,
    AttachmentURLExpiredError, Chain, GatewayMismatchError,
    GatewaySessionEndingError, TransportError, WriteRefusedError, put_attachment,
    touch_attachment
using SHA: sha256
using StableRNGs: StableRNG

include("fixtures/attachments.jl")
include("fixtures/s3_server.jl")
include("fixtures/gateway_server.jl")
include("fixtures/gateway_attachments.jl")

@testset "upload_minted sends nothing once the minted URL has expired" begin
    with_gateway() do g
        answer_mint(g; seconds = 1)
        reply = ChainTables.mint(g.store, FRESH_KEY, Int64(length(FRESH)))
        sleep(1.2)
        n = length(g.s3.requests)
        size = Int64(length(FRESH))
        io = IOBuffer(FRESH)
        e = thrown(() -> ChainTables.upload_minted(g.store, FRESH_KEY, io, size, reply))
        @test e isa AttachmentURLExpiredError
        @test (e.key, e.expires) == (FRESH_KEY, EXPIRES)
        @test !ChainTables.retryable(e)
        @test length(g.s3.requests) == n
        @test occursin(r"this process waited [12] s after the mint", sprint(showerror, e))
    end
end

const OUTLASTED = [
    (name = "a URL", capped = false, note = ""),
    (
        name = "a capped URL", capped = true,
        note = "; the gateway's AWS session capped this URL",
    ),
]

@testset "put_attachment via a gateway stops an upload outlasting $(case.name)" for case in
    OUTLASTED
    with_gateway() do g
        # Never notified: the upload stalls, and the handler never writes to a socket the
        # client has closed.
        never = Base.Event()
        g.s3.respond = req -> req.method == "PUT" ? (wait(never); nothing) : nothing
        answer_mint(g; seconds = 1, case.capped)
        t = @elapsed e = put_fresh(g)
        @test e isa AttachmentURLExpiredError
        @test !ChainTables.retryable(e)
        @test t < 3.5
        @test !haskey(g.s3.objects, FRESH_KEY)
        message = sprint(showerror, e)
        ran = match(r"the upload ran (\d+) s, past the URL's 1 s life", message)
        @test ran !== nothing
        @test ran.captures[1] in ("1", "2")
        @test occursin("its 10 bytes need 1 KiB/s or more" * case.note, message)
        @test !occursin("X-Amz-Signature", message)
        @test !occursin("clock", message)
    end
end

@testset "put_attachment via a gateway blames a clock for an early expiry" begin
    with_gateway() do g
        expired = s3test_error("AccessDenied", "Request has expired")
        g.s3.respond = req -> req.method == "PUT" ? (403, [], expired) : nothing
        answer_mint(g)
        e = put_fresh(g)
        @test e isa AttachmentURLExpiredError
        @test !haskey(g.s3.objects, FRESH_KEY)
        detail = "S3 refused the upload as expired after 0 s of the URL's 900 s: the " *
            "gateway's clock is off, or S3's"
        @test occursin(detail, sprint(showerror, e))
    end
end

@testset "put_attachment via a gateway refuses a URL without its lifetime" begin
    with_gateway() do g
        answer_mint(g; lifetime = nothing)
        e = put_fresh(g)
        @test e isa GatewayMismatchError
        @test e.key == FRESH_KEY
        detail = "without its lifetime (\"seconds\", \"capped\")"
        @test occursin(detail, sprint(showerror, e))
        @test isempty(filter(r -> r.method == "PUT", g.s3.requests))
    end
end

const ELSEWHERE = [
    (name = "another bucket", url = endpoint -> "$endpoint/other/$FRESH_KEY"),
    (name = "another key", url = endpoint -> "$endpoint/bkt/p/_attachments/" * "1"^64),
    (name = "another host", url = endpoint -> "https://evil.example/bkt/$FRESH_KEY"),
]

@testset "put_attachment via a gateway refuses a URL at $(case.name)" for case in
    ELSEWHERE
    with_gateway() do g
        endpoint = s3test_endpoint(g.s3)
        url = case.url(endpoint)
        answer_mint(g; url)
        e = put_fresh(g)
        @test e isa GatewayMismatchError
        @test (e.key, e.bucket) == (FRESH_KEY, "bkt")
        expected = "it minted a URL at $url, not at $endpoint/bkt/$FRESH_KEY"
        @test occursin(expected, sprint(showerror, e))
        @test isempty(g.s3.requests)
    end
end

const NO_QUERY = [
    (name = "no query", url = endpoint -> nothing),
    (name = "an empty query", url = endpoint -> "$endpoint/bkt/$FRESH_KEY?"),
]

@testset "put_attachment via a gateway refuses a URL with $(case.name)" for case in
    NO_QUERY
    with_gateway() do g
        answer_mint(g; url = case.url(s3test_endpoint(g.s3)), query = false)
        e = put_fresh(g)
        @test e isa GatewayMismatchError
        @test e.gateway == loopback_url(g.gw)
        detail = "it minted a URL with no query, so no signature"
        @test occursin(detail, sprint(showerror, e))
        @test isempty(g.s3.requests)
    end
end

const FRESH_CHECKSUM = ChainTables.checksum_sha256(bytes2hex(sha256(FRESH)))
const ZERO_CHECKSUM = ChainTables.checksum_sha256("0"^64)

without_header(name) = headers -> filter(kv -> first(kv) != name, headers)
replaced(kv, name, value) = first(kv) == name ? name => value : kv
setting_header(name, value) = headers -> map(kv -> replaced(kv, name, value), headers)

const HEADER_PROBLEMS = [
    (
        name = "no checksum", edit = without_header("x-amz-checksum-sha256"),
        problem = "no x-amz-checksum-sha256 header, where $(repr(FRESH_CHECKSUM))",
    ),
    (
        name = "another checksum",
        edit = setting_header("x-amz-checksum-sha256", ZERO_CHECKSUM),
        problem = "x-amz-checksum-sha256 $(repr(ZERO_CHECKSUM)), " *
            "where $(repr(FRESH_CHECKSUM))",
    ),
    (
        name = "no if-none-match", edit = without_header("if-none-match"),
        problem = "no if-none-match header, where \"*\"",
    ),
    (
        name = "another if-none-match", edit = setting_header("if-none-match", "abc"),
        problem = "if-none-match \"abc\", where \"*\"",
    ),
    (
        name = "no content-length", edit = without_header("content-length"),
        problem = "no content-length header, where \"10\"",
    ),
    (
        name = "another content-length", edit = setting_header("content-length", "11"),
        problem = "content-length \"11\", where \"10\"",
    ),
    (
        name = "a content-length twice",
        edit = headers -> [headers; "content-length" => "11"],
        problem = "content-length 2 times (\"10\", \"11\"), where once, \"10\"",
    ),
    (
        name = "an agreeing content-length twice",
        edit = headers -> [headers; "content-length" => "10"],
        problem = "content-length 2 times (\"10\", \"10\"), where once, \"10\"",
    ),
]

@testset "put_attachment via a gateway refuses $(case.name) minted" for case in
    HEADER_PROBLEMS
    with_gateway() do g
        answer_mint(g; case.edit)
        e = put_fresh(g)
        @test e isa GatewayMismatchError
        @test (e.key, e.bucket) == (FRESH_KEY, "bkt")
        @test occursin("it minted " * case.problem, sprint(showerror, e))
        @test isempty(g.s3.requests)
    end
end

const MINTED_START = "{\"code\": \"minted\", \"url\": \"x\", \"expires\": \"y\", "
const AB = "\"headers\": {\"a\": \"b\"}}"

const UNREADABLE_REPLIES = [
    (
        name = "no headers", body = MINTED_START * "\"z\": 1}",
        what = "no \"headers\" object",
    ),
    (
        name = "no url", body = "{\"code\": \"minted\", \"expires\": \"y\", " * AB,
        what = "no \"url\"",
    ),
    (
        name = "headers without a comma",
        body = MINTED_START * "\"headers\": {\"a\": \"b\" \"c\": \"d\"}}",
        what = "not a flat map",
    ),
    (
        name = "an uppercase header", body = MINTED_START * "\"headers\": {\"A\": \"b\"}}",
        what = "not a flat map",
    ),
    (
        name = "empty headers", body = MINTED_START * "\"headers\": {}}",
        what = "an empty \"headers\" object",
    ),
    (
        name = "a quoted seconds",
        body = MINTED_START * "\"seconds\": \"9\", \"capped\": false, " * AB,
        what = "a \"seconds\" that is not a whole number",
    ),
    (
        name = "seconds alone", body = MINTED_START * "\"seconds\": 9, " * AB,
        what = "\"seconds\" without \"capped\"",
    ),
    (
        name = "a numeric capped",
        body = MINTED_START * "\"seconds\": 9, \"capped\": 1, \"headers\": {\"a\": \"b\"}}",
        what = "a \"capped\" that is not true or false",
    ),
    (
        name = "capped alone", body = MINTED_START * "\"capped\": 1, " * AB,
        what = "\"capped\" without \"seconds\"",
    ),
    (
        name = "an unknown code", body = "{\"code\": \"stored\"}",
        what = "with code \"stored\", neither present nor minted",
    ),
]

@testset "put_attachment via a gateway refuses a reply with $(case.name)" for case in
    UNREADABLE_REPLIES
    with_gateway() do g
        g.double.respond = req -> (200, [], Vector{UInt8}(case.body))
        e = put_fresh(g)
        @test e isa TransportError
        @test e.status == 200
        @test !ChainTables.retryable(e)
        @test occursin(case.what, sprint(showerror, e))
    end
end
