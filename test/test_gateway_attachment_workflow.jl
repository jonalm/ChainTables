# Attachments on a gateway bucket: `put_attachment`, `touch_attachment` and `attachment`
# through the loopback gateway, S3 and STS. The store is built directly, to point it at
# the doubles. `expected_attachment_url` is called directly for AWS stores, which no
# request reaches offline.
using Test
using Base64: base64encode
using ChainTables: ChainTables, AttachmentAbsentError, AttachmentChangedError,
    AttachmentURLExpiredError, Chain, Credentials, GatewayMismatchError,
    GatewaySessionEndingError, TransportError, WriteRefusedError, attachment, commit!,
    create_chain, put_attachment, sync!, table, touch_attachment, verify

include("fixtures/attachments.jl")
include("fixtures/s3_server.jl")
include("fixtures/gateway_double.jl")
include("fixtures/chain_copies.jl")

const URL = "https://abc123.lambda-url.eu-north-1.on.aws"
const BYTES = attachment_bytes(2 * 1024 * 1024 + 3)
const H = sha256_hex(BYTES)
const KEY = "p/_attachments/$H"
const FRESH = attachment_bytes(10; seed = 2)
const FRESH_KEY = "p/_attachments/$(sha256_hex(FRESH))"
const RETRY_LATER = "The failure may pass"
const NO_RETRY = "A retry will not help"
const LAMBDA_SCOPE = "/eu-north-1/lambda/aws4_request, SignedHeaders=host;" *
    "x-amz-content-sha256;x-amz-date;x-amz-security-token,"
const CHECKSUM = base64encode(sha256(FRESH))
const ZERO_CHECKSUM = base64encode(zeros(UInt8, 32))

const AWS_ENDPOINTS = [
    (endpoint = nothing, path_style = false),
    (endpoint = nothing, path_style = true),
    (endpoint = "https://s3.eu-north-1.amazonaws.com", path_style = true),
    (endpoint = "https://s3.eu-north-1.amazonaws.com", path_style = false),
    (endpoint = "https://s3-fips.eu-north-1.amazonaws.com", path_style = true),
    (endpoint = "https://s3.dualstack.eu-north-1.amazonaws.com", path_style = false),
]

const ONES = "1"^64

const ELSEWHERE = [
    (name = "another bucket", url = s3 -> "$(s3test_endpoint(s3))/other/$FRESH_KEY"),
    (name = "another key", url = s3 -> "$(s3test_endpoint(s3))/bkt/p/_attachments/$ONES"),
    (name = "another host", url = s3 -> "https://evil.example/bkt/$FRESH_KEY"),
]

const NO_QUERY = [
    (name = "no query", url = nothing),
    (name = "an empty query", url = "/bkt/$FRESH_KEY?"),
]

without(name) = headers -> filter(pair -> first(pair) != name, headers)
setting(name, value) = headers -> [first(p) == name ? name => value : p for p in headers]

const HEADER_EDITS = [
    (
        name = "no checksum", edit = without("x-amz-checksum-sha256"),
        problem = "no x-amz-checksum-sha256 header, where $(repr(CHECKSUM))",
    ),
    (
        name = "another checksum",
        edit = setting("x-amz-checksum-sha256", ZERO_CHECKSUM),
        problem = "x-amz-checksum-sha256 $(repr(ZERO_CHECKSUM)), where $(repr(CHECKSUM))",
    ),
    (
        name = "no if-none-match", edit = without("if-none-match"),
        problem = "no if-none-match header, where \"*\"",
    ),
    (
        name = "another if-none-match", edit = setting("if-none-match", "abc"),
        problem = "if-none-match \"abc\", where \"*\"",
    ),
    (
        name = "no content-length", edit = without("content-length"),
        problem = "no content-length header, where \"10\"",
    ),
    (
        name = "another content-length", edit = setting("content-length", "11"),
        problem = "content-length \"11\", where \"10\"",
    ),
    (
        name = "two content-lengths", edit = headers -> [headers; "content-length" => "11"],
        problem = "content-length 2 times (\"10\", \"11\"), where once, \"10\"",
    ),
    (
        name = "a content-length twice",
        edit = headers -> [headers; "content-length" => "10"],
        problem = "content-length 2 times (\"10\", \"10\"), where once, \"10\"",
    ),
]

minted_json(fields) = "{\"code\": \"minted\", $fields}"
const MINTED_BASE = "\"url\": \"x\", \"expires\": \"y\""

const UNREADABLE = [
    (name = "no headers", body = minted_json(MINTED_BASE), what = "no \"headers\" object"),
    (
        name = "no url",
        body = minted_json("\"expires\": \"y\", \"headers\": {\"a\": \"b\"}"),
        what = "no \"url\"",
    ),
    (
        name = "headers that are not a map",
        body = minted_json(MINTED_BASE * ", \"headers\": {\"a\": \"b\" \"c\": \"d\"}"),
        what = "not a flat map",
    ),
    (
        name = "an uppercase header",
        body = minted_json(MINTED_BASE * ", \"headers\": {\"A\": \"b\"}"),
        what = "not a flat map",
    ),
    (
        name = "empty headers", body = minted_json(MINTED_BASE * ", \"headers\": {}"),
        what = "an empty \"headers\" object",
    ),
    (
        name = "seconds as text",
        body = minted_json(
            MINTED_BASE * ", \"seconds\": \"9\", \"capped\": false, " *
                "\"headers\": {\"a\": \"b\"}"
        ),
        what = "a \"seconds\" that is not a whole number",
    ),
    (
        name = "seconds alone",
        body = minted_json(MINTED_BASE * ", \"seconds\": 9, \"headers\": {\"a\": \"b\"}"),
        what = "\"seconds\" without \"capped\"",
    ),
    (
        name = "capped as a number",
        body = minted_json(
            MINTED_BASE * ", \"seconds\": 9, \"capped\": 1, \"headers\": {\"a\": \"b\"}"
        ),
        what = "a \"capped\" that is not true or false",
    ),
    (
        name = "capped alone",
        body = minted_json(MINTED_BASE * ", \"capped\": 1, \"headers\": {\"a\": \"b\"}"),
        what = "\"capped\" without \"seconds\"",
    ),
    (
        name = "an unknown code", body = "{\"code\": \"stored\"}",
        what = "the code \"stored\" is neither present nor minted",
    ),
]

const MINT_FAILURES = [
    (status = 502, code = "s3_error", next_move = RETRY_LATER, n_mints = 4),
    (status = 413, code = "too_large", next_move = NO_RETRY, n_mints = 1),
    (status = 400, code = "not_a_slot", next_move = NO_RETRY, n_mints = 1),
]

const LATE = [
    (name = "a URL of full life", capped = false, hint = false),
    (name = "a capped URL", capped = true, hint = true),
]

# A chain over the loopback gateway bucket, with its record cache in a temporary dir.
# A chain that commits: the loopback S3 is not AWS, so it needs the promise.
const COMMITTING =
    (policy = ["exp" => [ALICE]], prefix = "exp/run-1", assume_first_writer_wins = true)

function with_gateway_chain(f; policy = ["p" => [ALICE]], prefix = "p", keywords...)
    with_gateway(; policy) do world
        mktempdir() do dir
            store = gateway_store(world)
            cache_dir = joinpath(dir, "cache")
            chain = Chain("bkt", prefix; store, cache_dir, keywords...)
            f(world, chain)
        end
    end
    return nothing
end

# The mint answers with a URL for `FRESH_KEY` from `gwtest_minted(…; keywords…)`.
function script_mint!(world; keywords...)
    world.double.respond = request -> scripted_mint(world.s3, request; keywords...)
    return nothing
end

function scripted_mint(s3, request; size = length(FRESH), keywords...)
    request.rawpath == "/mint" || return nothing
    return gwtest_minted(s3, FRESH_KEY, size; keywords...)
end

put_fresh(chain) = put_attachment(chain, IOBuffer(FRESH))

mint_requests(world) = filter(r -> r.rawpath == "/mint", world.gateway.requests)
n_mints(world) = length(mint_requests(world))
n_uploads(world) = count(r -> r.method == "PUT", world.s3.requests)
requested(s3) = [(r.method, r.path) for r in s3.requests]

@testset "put_attachment through a gateway mints, uploads, then asks the bucket" begin
    with_gateway_chain() do world, chain
        @test put_attachment(chain, IOBuffer(BYTES)) == H
        @test world.s3.objects[KEY] == BYTES
        mint = only(mint_requests(world))
        @test mint.method == "POST"
        @test mint.query == ["key" => KEY, "size" => string(length(BYTES))]
        @test isempty(mint.body)
        @test occursin(LAMBDA_SCOPE, mint.headers["authorization"])
        @test [r.method for r in world.s3.requests] == ["PUT", "HEAD"]
        @test world.s3.requests[end].path == "/bkt/$KEY"
    end
end

@testset "put_attachment through a gateway sends exactly the minted headers" begin
    with_gateway_chain() do world, chain
        put_attachment(chain, IOBuffer(BYTES))
        upload = world.s3.requests[1]
        amz = sort(filter(startswith("x-amz-"), collect(keys(upload.headers))))
        @test upload.path == "/bkt/$KEY"
        @test any(pair -> first(pair) == "X-Amz-Signature", upload.query)
        @test !haskey(upload.headers, "authorization")
        @test amz == ["x-amz-checksum-sha256", "x-amz-tagging"]
        @test upload.headers["x-amz-checksum-sha256"] == base64encode(sha256(BYTES))
    end
end

@testset "put_attachment through a gateway of a present attachment uploads nothing" begin
    with_gateway_chain() do world, chain
        put_attachment(chain, IOBuffer(BYTES))
        empty!(world.s3.requests)
        @test put_attachment(chain, IOBuffer(BYTES)) == H
        @test [r.method for r in world.s3.requests] == ["HEAD"]
    end
end

@testset "put_attachment through a gateway that lost a race asks the mint again" begin
    with_gateway_chain() do world, chain
        world.s3.objects[FRESH_KEY], world.s3.modified[FRESH_KEY] = FRESH, 0
        minted = Ref(false)
        world.double.respond = function (request)
            (request.rawpath == "/mint" && !minted[]) || return nothing
            minted[] = true
            return gwtest_minted(world.s3, FRESH_KEY, length(FRESH))
        end
        @test put_fresh(chain) == sha256_hex(FRESH)
        @test n_mints(world) == 2
    end
end

@testset "put_attachment through a gateway that mints twice for a present key" begin
    with_gateway_chain() do world, chain
        world.s3.objects[FRESH_KEY], world.s3.modified[FRESH_KEY] = FRESH, 0
        script_mint!(world)
        fragment = "S3 refused the upload as already present (412), and the gateway " *
            "then found it absent and minted another URL"
        err = @test_throws GatewayMismatchError fragment put_fresh(chain)
        @test (err.value.key, err.value.bucket) == (FRESH_KEY, "bkt")
        @test err.value.gateway == loopback_url(world.gateway)
    end
end

@testset "put_attachment through a gateway reads S3's BadDigest as a changed file" begin
    with_gateway_chain() do world, chain
        world.s3.respond = request -> request.method == "PUT" ?
            (400, [], s3test_error("BadDigest", "no match")) : nothing
        fragment = "the file changed between hashing and upload"
        err = @test_throws AttachmentChangedError fragment put_fresh(chain)
        @test (err.value.bucket, err.value.key) == ("bkt", FRESH_KEY)
        @test !haskey(world.s3.objects, FRESH_KEY)
    end
end

@testset "put_attachment through a gateway sends nothing past the URL's life" begin
    with_gateway_chain() do world, chain
        script_mint!(world; seconds = 0)
        fragment = "Nothing was stored. Put the attachment again, which mints a new URL."
        err = @test_throws AttachmentURLExpiredError fragment put_fresh(chain)
        @test err.value.reason === :expired_before_upload
        @test (err.value.key, err.value.expires) == (FRESH_KEY, "2026-11-06T12:00:00Z")
        @test err.value.gateway == loopback_url(world.gateway)
        @test startswith(err.value.detail, "this process waited 0 s after the mint")
        @test n_uploads(world) == 0
        @test n_mints(world) == 1
    end
end

@testset "put_attachment through a gateway stops at its end: $(case.name)" for case in LATE
    with_gateway_chain() do world, chain
        world.s3.respond = request -> request.method == "PUT" ? sleep(4) : nothing
        script_mint!(world; seconds = 1, case.capped)
        next_move = "Put the attachment again over a faster link."
        err = @test_throws AttachmentURLExpiredError next_move put_fresh(chain)
        @test err.value.reason === :outlasted
        fragment = "past the URL's life of 1 s; its 10 bytes need 1 KiB/s"
        @test occursin(fragment, err.value.detail)
        @test occursin("(capped)", err.value.detail) == case.hint
        @test !occursin("X-Amz-Signature", sprint(showerror, err.value))
        @test !haskey(world.s3.objects, FRESH_KEY)
        @test n_mints(world) == 1
    end
end

@testset "put_attachment through a gateway reads S3's early expiry as such" begin
    with_gateway_chain() do world, chain
        expired = s3test_error("AccessDenied", "Request has expired")
        world.s3.respond = request -> request.method == "PUT" ? (403, [], expired) : nothing
        script_mint!(world)
        fragment = "the gateway's clock or S3's is off"
        err = @test_throws AttachmentURLExpiredError fragment put_fresh(chain)
        @test err.value.reason === :expired_early
        @test err.value.detail ==
            "S3 refused the upload as expired after 0 s, though the URL lives 900 s"
    end
end

@testset "put_attachment through a gateway refuses a URL without its lifetime" begin
    with_gateway_chain() do world, chain
        script_mint!(world; lifetime = nothing)
        fragment = "the gateway minted a URL without its lifetime"
        err = @test_throws GatewayMismatchError fragment put_fresh(chain)
        @test err.value.key == FRESH_KEY
        @test n_uploads(world) == 0
    end
end

@testset "put_attachment through a gateway refuses $(case.name)" for case in ELSEWHERE
    with_gateway_chain() do world, chain
        url = case.url(world.s3)
        script_mint!(world; url)
        expected = "$(s3test_endpoint(world.s3))/bkt/$FRESH_KEY"
        fragment = "the gateway minted a URL at $url, not at $expected"
        err = @test_throws GatewayMismatchError fragment put_fresh(chain)
        @test (err.value.key, err.value.bucket) == (FRESH_KEY, "bkt")
        @test n_uploads(world) == 0
    end
end

@testset "put_attachment through a gateway refuses $(case.name)" for case in NO_QUERY
    with_gateway_chain() do world, chain
        url = case.url === nothing ? nothing : s3test_endpoint(world.s3) * case.url
        script_mint!(world; url, query = false)
        fragment = "the gateway minted a URL with no query, so no signature"
        @test_throws GatewayMismatchError fragment put_fresh(chain)
        @test n_uploads(world) == 0
    end
end

@testset "put_attachment through a gateway refuses $(case.name)" for case in HEADER_EDITS
    with_gateway_chain() do world, chain
        script_mint!(world; case.edit)
        fragment = "the gateway minted $(case.problem); nothing was sent"
        err = @test_throws GatewayMismatchError fragment put_fresh(chain)
        @test err.value.gateway == loopback_url(world.gateway)
        @test n_uploads(world) == 0
    end
end

@testset "put_attachment through a gateway that stored it elsewhere" begin
    with_gateway_chain() do world, chain
        world.double.respond = request -> gwtest_json(200, "present", "already stored")
        fragment = "the gateway has stored the attachment, and the bucket does not hold it"
        @test_throws GatewayMismatchError fragment put_fresh(chain)
    end
end

@testset "put_attachment through a gateway whose bucket holds another size" begin
    with_gateway_chain() do world, chain
        world.s3.objects[FRESH_KEY], world.s3.modified[FRESH_KEY] = b"abc", 0
        fragment = "the bucket holds 3 bytes there, not 10"
        @test_throws GatewayMismatchError fragment put_fresh(chain)
    end
end

@testset "put_attachment through a gateway tries a failed upload again" begin
    with_gateway_chain() do world, chain
        failure = (500, [], s3test_error("InternalError", "Please try again."))
        world.s3.respond = request -> request.method == "PUT" ? failure : nothing
        script_mint!(world)
        err = @test_throws TransportError RETRY_LATER put_fresh(chain)
        @test err.value.status == 500
        @test err.value.url == "$(s3test_endpoint(world.s3))/bkt/$FRESH_KEY"
        @test err.value.detail == "InternalError: Please try again."
        @test !occursin("Signature", sprint(showerror, err.value))
        @test n_uploads(world) == 4
    end
end

@testset "put_attachment through a gateway refuses $(case.name)" for case in UNREADABLE
    with_gateway_chain() do world, chain
        world.double.respond = request -> (200, [], Vector{UInt8}(case.body))
        err = @test_throws TransportError NO_RETRY put_fresh(chain)
        @test (err.value.method, err.value.status) == ("POST", 200)
        @test occursin(case.what, err.value.detail)
        @test n_mints(world) == 1
    end
end

@testset "put_attachment through a gateway throws the mint's refusal" begin
    with_gateway_chain() do world, chain
        world.double.caller = "bob@example.com"
        next_move = "Ask the bucket's operator to add"
        err = @test_throws WriteRefusedError next_move put_fresh(chain)
        @test (err.value.reason, err.value.key) == ("not_allowed", FRESH_KEY)
        @test err.value.caller === nothing
        @test err.value.detail == "bob@example.com may not write under p/_attachments"
    end
end

@testset "put_attachment through a gateway that predates the mint route" begin
    with_gateway_chain() do world, chain
        message = "POST /mint is not the gateway's one route, PUT /?key=<slot key>"
        world.double.respond = _ -> gwtest_json(400, "bad_request", message)
        fragment = "The gateway was deployed before attachments"
        err = @test_throws WriteRefusedError fragment put_fresh(chain)
        @test (err.value.reason, err.value.detail) == ("no_mint_route", message)
        @test err.value.gateway == loopback_url(world.gateway)
        @test n_mints(world) == 1
    end
end

@testset "put_attachment through a gateway whose own call S3 refused" begin
    with_gateway_chain() do world, chain
        message = "S3 answered 403 AccessDenied to the HEAD"
        world.double.respond = _ -> gwtest_json(502, "s3_refused", message)
        err = @test_throws WriteRefusedError "deployed wrongly" put_fresh(chain)
        @test (err.value.reason, err.value.detail) == ("s3_refused", message)
    end
end

@testset "put_attachment through a gateway answered $(case.code)" for case in MINT_FAILURES
    with_gateway_chain() do world, chain
        answer = gwtest_json(case.status, case.code, "the gateway's word")
        world.double.respond = _ -> answer
        err = @test_throws TransportError case.next_move put_fresh(chain)
        @test err.value.status == case.status
        @test err.value.detail == "$(case.code): the gateway's word"
        @test n_mints(world) == case.n_mints
        @test !haskey(world.s3.objects, FRESH_KEY)
    end
end

@testset "put_attachment through a gateway whose session ends too soon" begin
    with_gateway_chain() do world, chain
        message = "this environment's session ends too soon"
        world.double.respond = request -> request.rawpath == "/mint" ?
            gwtest_json(503, "session_ending", message) : nothing
        fragment = "Put the attachment again later"
        err = @test_throws GatewaySessionEndingError fragment put_fresh(chain)
        @test (err.value.key, err.value.detail) == (FRESH_KEY, message)
        @test err.value.gateway == loopback_url(world.gateway)
        @test n_mints(world) == 1
        world.double.respond = _ -> nothing
        @test put_fresh(chain) == sha256_hex(FRESH)
        @test n_mints(world) == 2
    end
end

@testset "put_attachment through a gateway is under the policy of the chain's prefix" begin
    with_gateway_chain(; policy = ["p/_attachments" => [ALICE]]) do world, chain
        @test_throws WriteRefusedError "may not write under p/_attachments" put_fresh(chain)
    end
end

@testset "touch_attachment through a gateway asks the bucket, then mints its size" begin
    with_gateway_chain() do world, chain
        h = put_attachment(chain, IOBuffer(BYTES))
        empty!(world.gateway.requests)
        empty!(world.s3.requests)
        @test touch_attachment(chain, h) === nothing
        @test [r.method for r in world.s3.requests] == ["HEAD"]
        @test only(mint_requests(world)).query ==
            ["key" => KEY, "size" => string(length(BYTES))]
    end
end

@testset "touch_attachment through a gateway of an absent attachment does not mint" begin
    with_gateway_chain() do world, chain
        @test_throws AttachmentAbsentError "it was never put" touch_attachment(
            chain, NEVER_PUT
        )
        @test isempty(world.gateway.requests)
    end
end

@testset "touch_attachment through a gateway that finds absent what the bucket holds" begin
    with_gateway_chain() do world, chain
        world.s3.objects[FRESH_KEY], world.s3.modified[FRESH_KEY] = FRESH, 0
        script_mint!(world)
        fragment = "the bucket holds the attachment, and the gateway found it absent"
        err = @test_throws GatewayMismatchError fragment touch_attachment(
            chain, sha256_hex(FRESH)
        )
        @test (err.value.key, err.value.bucket) == (FRESH_KEY, "bkt")
        @test n_uploads(world) == 0
    end
end

@testset "touch_attachment through a gateway throws the mint's refusal" begin
    with_gateway_chain() do world, chain
        h = put_attachment(chain, IOBuffer(BYTES))
        world.double.caller = "bob@example.com"
        err = @test_throws WriteRefusedError "not_allowed" touch_attachment(chain, h)
        @test err.value.reason == "not_allowed"
    end
end

@testset "attachment on a gateway chain reads from the bucket, never the gateway" begin
    with_gateway_chain(; COMMITTING...) do world, chain
        create_chain(chain)
        h = put_attachment(chain, IOBuffer(BYTES))
        key = "exp/run-1/_attachments/$h"
        mktempdir() do root
            with_copy(chain, joinpath(root, "one")) do local_copy
                sync!(local_copy)
                empty!(world.gateway.requests)
                empty!(world.s3.requests)
                @test read(attachment(local_copy, h)) == BYTES
                @test requested(world.s3) == [("GET", "/bkt/$key")]
                @test attachment(local_copy, h) == attachment(local_copy, h)
                @test length(world.s3.requests) == 1
                @test isempty(world.gateway.requests)
            end
        end
    end
end

@testset "attachment on a gateway chain asks the bucket once through a second copy" begin
    with_gateway_chain(; COMMITTING...) do world, chain
        create_chain(chain)
        h = put_attachment(chain, IOBuffer(BYTES))
        key = "exp/run-1/_attachments/$h"
        with_copy(chain, joinpath(mktempdir(), "one")) do one
            sync!(one)
            attachment(one, h)
            with_copy_beside(one, "two") do two
                sync!(two)
                empty!(world.s3.requests)
                empty!(world.gateway.requests)
                @test attachment(two, h) == attachment(two, h)
                @test requested(world.s3) == [("HEAD", "/bkt/$key")]
                @test verify(two; full = true) === nothing
                @test isempty(world.gateway.requests)
            end
        end
    end
end

@testset "expected_attachment_url of an AWS store is the bucket's regional host" begin
    credentials = Credentials("AKIATEST", "topsecret"; session_token = "tok")
    regional = "https://bkt.s3.eu-north-1.amazonaws.com/$KEY"
    @testset "$(case.endpoint) $(case.path_style)" for case in AWS_ENDPOINTS
        store = Chain(
            "bkt", "p"; gateway = URL, region = "eu-north-1", credentials, case.endpoint,
            case.path_style,
        ).store
        @test ChainTables.expected_attachment_url(store, KEY) == regional
    end
end

@testset "expected_attachment_url of a store that is not AWS is its object URL" begin
    credentials = Credentials("AKIATEST", "topsecret"; session_token = "tok")
    store = Chain(
        "bkt", "p"; gateway = URL, region = "eu-north-1", credentials,
        endpoint = "http://127.0.0.1:9000", path_style = true,
    ).store
    @test ChainTables.expected_attachment_url(store, KEY) ==
        "http://127.0.0.1:9000/bkt/$KEY"
end
