using Test
using ChainTables: ChainTables, AttachmentAbsentError, AttachmentChangedError,
    AttachmentURLExpiredError, Chain, GatewayMismatchError, GatewayObjectStore,
    GatewaySessionEndingError, TransportError, WriteRefusedError, put_attachment,
    touch_attachment
using SHA: sha256
using StableRNGs: StableRNG

include("fixtures/attachments.jl")
include("fixtures/s3_server.jl")
include("fixtures/gateway_double.jl")
include("fixtures/gateway_attachments.jl")

const BIG = rand(StableRNG(3), UInt8, 2 * 1024 * 1024 + 3)
const BIG_KEY = "p/_attachments/" * bytes2hex(sha256(BIG))
@testset "put_attachment via a gateway mints, uploads and returns true" begin
    with_gateway() do g
        @test @inferred(put_attachment(g.store, BIG_KEY, IOBuffer(BIG))) == true
        @test g.s3.objects[BIG_KEY] == BIG
    end
end

@testset "put_attachment via a gateway mints by a signed POST with key and size" begin
    with_gateway() do g
        put_attachment(g.store, BIG_KEY, IOBuffer(BIG))
        mint = only(mints(g))
        @test mint.method == "POST"
        @test mint.query == ["key" => BIG_KEY, "size" => string(length(BIG))]
        @test isempty(mint.body)
        signed = "/eu-north-1/lambda/aws4_request, " *
            "SignedHeaders=host;x-amz-content-sha256;x-amz-date;x-amz-security-token,"
        @test occursin(signed, mint.headers["authorization"])
    end
end

@testset "put_attachment via a gateway uploads with exactly the minted headers" begin
    with_gateway() do g
        put_attachment(g.store, BIG_KEY, IOBuffer(BIG))
        upload = only(filter(r -> r.method == "PUT", g.s3.requests))
        @test upload.path == "/bkt/$BIG_KEY"
        @test any(kv -> first(kv) == "X-Amz-Signature", upload.query)
        @test !haskey(upload.headers, "authorization")
        amz = sort(filter(startswith("x-amz-"), collect(keys(upload.headers))))
        @test amz == ["x-amz-checksum-sha256", "x-amz-tagging"]
        checksum = ChainTables.checksum_sha256(bytes2hex(sha256(BIG)))
        @test upload.headers["x-amz-checksum-sha256"] == checksum
    end
end

@testset "put_attachment via a gateway confirms the key by a HEAD of the bucket" begin
    with_gateway() do g
        put_attachment(g.store, BIG_KEY, IOBuffer(BIG))
        @test last(g.s3.requests).method == "HEAD"
        @test last(g.s3.requests).path == "/bkt/$BIG_KEY"
    end
end

@testset "put_attachment via a gateway of a present key uploads nothing" begin
    with_gateway() do g
        put_attachment(g.store, BIG_KEY, IOBuffer(BIG))
        empty!(g.s3.requests)
        @test put_attachment(g.store, BIG_KEY, IOBuffer(BIG)) == false
        @test [r.method for r in g.s3.requests] == ["HEAD"]
    end
end

@testset "put_attachment via a gateway that loses a race mints again" begin
    with_gateway() do g
        g.s3.objects[FRESH_KEY] = FRESH
        g.s3.modified[FRESH_KEY] = 0
        minted = Ref(false)
        once = () -> (minted[] = true; gwtest_minted(g.s3, FRESH_KEY, length(FRESH)))
        g.double.respond = req -> req.rawpath == "/mint" && !minted[] ? once() : nothing
        @test put_attachment(g.store, FRESH_KEY, IOBuffer(FRESH)) == false
        @test length(mints(g)) == 2
        @test g.s3.objects[FRESH_KEY] == FRESH
    end
end

@testset "put_attachment via a gateway throws when a 412 is absent on a second mint" begin
    with_gateway() do g
        g.s3.objects[FRESH_KEY] = FRESH
        g.s3.modified[FRESH_KEY] = 0
        answer_mint(g)
        e = put_fresh(g)
        @test e isa GatewayMismatchError
        @test (e.key, e.bucket, e.gateway) == (FRESH_KEY, "bkt", loopback_url(g.gw))
        detail = "as present (412), and a second mint found it absent"
        @test occursin(detail, sprint(showerror, e))
    end
end

@testset "put_attachment via a gateway refuses BadDigest as a changed file" begin
    with_gateway() do g
        bad = "p/_attachments/" * "0"^64
        e = thrown(() -> put_attachment(g.store, bad, IOBuffer(BIG)))
        @test e isa AttachmentChangedError
        @test e.key == bad
        url = "$(s3test_endpoint(g.s3))/bkt/$bad"
        @test occursin("S3 at $url answered BadDigest", sprint(showerror, e))
        @test !haskey(g.s3.objects, bad)
    end
end

@testset "put_attachment via a gateway refuses a present key the bucket lacks" begin
    with_gateway() do g
        present = gwtest_json(200, "present", "already stored")
        g.double.respond = req -> req.rawpath == "/mint" ? present : nothing
        e = put_fresh(g)
        @test e isa GatewayMismatchError
        detail = "after the gateway's word, the bucket does not hold it"
        @test occursin(detail, sprint(showerror, e))
    end
end

@testset "put_attachment via a gateway throws another upload failure as S3's" begin
    with_gateway() do g
        answer_mint(g)
        internal = s3test_error("InternalError", "Please try again.")
        g.s3.respond = req -> req.method == "PUT" ? (500, [], internal) : nothing
        e = put_fresh(g)
        @test e isa TransportError
        @test e.status == 500
        @test ChainTables.retryable(e)
        url = "$(s3test_endpoint(g.s3))/bkt/$FRESH_KEY"
        @test occursin("PUT $url: HTTP 500 InternalError", sprint(showerror, e))
        @test !occursin("Signature", sprint(showerror, e))
    end
end

@testset "put_attachment via a gateway throws a mint the policy refuses" begin
    with_gateway() do g
        g.double.caller = "bob@example.com"
        e = put_fresh(g)
        @test e isa WriteRefusedError
        @test (e.reason, e.key) == ("not_allowed", FRESH_KEY)
        message = "the mint was refused: bob@example.com may not write under p"
        @test occursin(message, sprint(showerror, e))
    end
end

@testset "put_attachment via a gateway without a mint route throws" begin
    with_gateway() do g
        message = "POST /mint is not the gateway's one route, PUT /?key=<slot key>"
        g.double.respond = req -> gwtest_json(400, "bad_request", message)
        e = put_fresh(g)
        @test e isa WriteRefusedError
        @test e.reason == "no_mint_route"
        @test !ChainTables.retryable(e)
        @test occursin("the gateway has no mint route", sprint(showerror, e))
    end
end

@testset "put_attachment via a gateway throws the gateway's s3_refused" begin
    with_gateway() do g
        message = "S3 answered 403 AccessDenied to the HEAD"
        g.double.respond = req -> gwtest_json(502, "s3_refused", message)
        e = put_fresh(g)
        @test e isa WriteRefusedError
        @test e.reason == "s3_refused"
        @test occursin("the mint was refused: $message", sprint(showerror, e))
    end
end

const MINT_FAILURES = [
    (status = 502, code = "s3_error", retryable = true),
    (status = 413, code = "too_large", retryable = false),
    (status = 400, code = "not_a_slot", retryable = false),
]

@testset "put_attachment via a gateway throws a mint's HTTP $(case.status)" for case in
    MINT_FAILURES
    with_gateway() do g
        g.double.respond = req -> gwtest_json(case.status, case.code, "the gateway's word")
        e = put_fresh(g)
        @test e isa TransportError
        @test e.status == case.status
        @test ChainTables.retryable(e) == case.retryable
        detail = "HTTP $(case.status) $(case.code): the gateway's word"
        @test occursin(detail, sprint(showerror, e))
        @test !haskey(g.s3.objects, FRESH_KEY)
    end
end

@testset "put_attachment via a gateway checks the policy on the chain" begin
    with_gateway() do g
        nested = "p/_attachments/" * bytes2hex(sha256(b"n"))
        @test put_attachment(g.store, nested, IOBuffer(b"n"))
        g.double.policy = ["p/_attachments" => ["alice@example.com"]]
        other = "p/_attachments/" * bytes2hex(sha256(b"m"))
        e = thrown(() -> put_attachment(g.store, other, IOBuffer(b"m")))
        @test e isa WriteRefusedError
        @test e.reason == "not_allowed"
    end
end

@testset "put_attachment via a gateway stops at session_ending" begin
    with_gateway() do g
        message = "this environment's session ends too soon"
        ending = gwtest_json(503, "session_ending", message)
        g.double.respond = req -> req.rawpath == "/mint" ? ending : nothing
        chain = Chain("bkt", "p"; store = g.store, cache_dir = g.dir)
        e = thrown(() -> put_attachment(chain, IOBuffer(FRESH)))
        @test e isa GatewaySessionEndingError
        @test (e.key, e.gateway) == (FRESH_KEY, loopback_url(g.gw))
        @test !ChainTables.retryable(e)
        @test occursin(message, sprint(showerror, e))
        @test length(mints(g)) == 1
        @test !haskey(g.s3.objects, FRESH_KEY)
        g.double.respond = _ -> nothing
        @test put_attachment(chain, IOBuffer(FRESH)) == bytes2hex(sha256(FRESH))
        @test length(mints(g)) == 2
    end
end

@testset "fetch_object_to on a gateway bucket reads the bucket" begin
    with_gateway() do g
        put_attachment(g.store, BIG_KEY, IOBuffer(BIG))
        path = joinpath(g.dir, "b")
        @test ChainTables.fetch_object_to(g.store, BIG_KEY, path) == length(BIG)
        @test read(path) == BIG
    end
end

@testset "touch_attachment via a gateway HEADs, then mints with the size" begin
    with_gateway() do g
        chain = Chain("bkt", "p"; store = g.store, cache_dir = g.dir)
        hash = put_attachment(chain, IOBuffer(FRESH))
        empty!(g.gw.requests)
        empty!(g.s3.requests)
        @test touch_attachment(chain, hash) === nothing
        @test [r.method for r in g.s3.requests] == ["HEAD"]
        @test only(mints(g)).query == ["key" => FRESH_KEY, "size" => string(length(FRESH))]
        @test @inferred(touch_attachment(g.store, FRESH_KEY)) == true
    end
end

@testset "touch_attachment via a gateway of an absent attachment does not mint" begin
    with_gateway() do g
        chain = Chain("bkt", "p"; store = g.store, cache_dir = g.dir)
        absent = bytes2hex(sha256(b"absent"))
        e = thrown(() -> touch_attachment(chain, absent))
        @test e isa AttachmentAbsentError
        @test e.key == "p/_attachments/$absent"
        @test isempty(g.gw.requests)
    end
end

@testset "touch_attachment via a gateway refuses a gateway that mints" begin
    with_gateway() do g
        chain = Chain("bkt", "p"; store = g.store, cache_dir = g.dir)
        hash = put_attachment(chain, IOBuffer(FRESH))
        answer_mint(g)
        e = thrown(() -> touch_attachment(chain, hash))
        @test e isa GatewayMismatchError
        @test (e.key, e.bucket) == (FRESH_KEY, "bkt")
        detail = "the bucket holds the attachment, and the gateway minted a URL for it"
        @test occursin(detail, sprint(showerror, e))
        @test count(r -> r.method == "PUT", g.s3.requests) == 1
    end
end

@testset "touch_attachment via a gateway throws a refusal as WriteRefusedError" begin
    with_gateway() do g
        chain = Chain("bkt", "p"; store = g.store, cache_dir = g.dir)
        hash = put_attachment(chain, IOBuffer(FRESH))
        g.double.caller = "bob@example.com"
        e = thrown(() -> touch_attachment(chain, hash))
        @test e isa WriteRefusedError
        @test e.reason == "not_allowed"
    end
end
