# The signer is checked against AWS's worked examples, an independent source, so these
# tests call it directly rather than through an API name.
using Test
using ChainTables: ChainTables, Credentials
using SHA: sha256

const SIGNER = ChainTables
const AWS_EXAMPLE_KEYS =
    Credentials("AKIAIOSFODNN7EXAMPLE", "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY")
const EMPTY_HASH = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
const DATE = "20130524T000000Z"
const HOST = "host" => "examplebucket.s3.amazonaws.com"
const UNSIGNED_GET = [HOST, "x-amz-content-sha256" => EMPTY_HASH, "x-amz-date" => DATE]
const GET_SIGNATURE = "f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41"

function sign_example(method, path, query, headers, payload_hash = EMPTY_HASH)
    return SIGNER.sign_request(
        AWS_EXAMPLE_KEYS, "us-east-1", method, path, query, headers, payload_hash, DATE
    )
end

@testset "sign_request matches AWS's GET object example" begin
    got = sign_example("GET", "/test.txt", [], [UNSIGNED_GET; "range" => "bytes=0-9"])
    @test got.canonical_request ==
        "GET\n/test.txt\n\nhost:examplebucket.s3.amazonaws.com\n" *
        "range:bytes=0-9\nx-amz-content-sha256:$EMPTY_HASH\nx-amz-date:$DATE\n\n" *
        "host;range;x-amz-content-sha256;x-amz-date\n$EMPTY_HASH"
    @test got.string_to_sign ==
        "AWS4-HMAC-SHA256\n$DATE\n20130524/us-east-1/s3/aws4_request\n" *
        "7344ae5b7ee6c3e7e6b0fe0640412a37625d1fbfff95c48bbb2dc43964946972"
    @test got.signature == GET_SIGNATURE
    @test got.authorization ==
        "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/" *
        "aws4_request, SignedHeaders=host;range;x-amz-content-sha256;x-amz-date, " *
        "Signature=$GET_SIGNATURE"
end

@testset "sign_request matches AWS's PUT object example" begin
    body_hash = bytes2hex(sha256("Welcome to Amazon S3."))
    headers = [
        "date" => "Fri, 24 May 2013 00:00:00 GMT", HOST,
        "x-amz-content-sha256" => body_hash, "x-amz-date" => DATE,
        "x-amz-storage-class" => "REDUCED_REDUNDANCY",
    ]
    got = sign_example("PUT", "/test%24file.text", [], headers, body_hash)
    @test got.signature ==
        "98ad721746da40c64f1a55b78f14c238d841ea1380cd77a1b5971af0ece108bd"
end

@testset "sign_request matches AWS's bucket examples" begin
    lifecycle = sign_example("GET", "/", ["lifecycle" => ""], UNSIGNED_GET)
    @test occursin("\nlifecycle=\n", lifecycle.canonical_request)
    @test lifecycle.signature ==
        "fea454ca298b7da1c68078a5d1bdbfbbe0d65c699e0f91ac7a200a0136783543"
    listing = sign_example("GET", "/", ["prefix" => "J", "max-keys" => "2"], UNSIGNED_GET)
    @test occursin("\nmax-keys=2&prefix=J\n", listing.canonical_request)
    @test listing.signature ==
        "34b48302e7b5fa45bde8084f4b7868a86f0a534bc59db6670ed5711ef69dc6f7"
end

@testset "sign_request lowercases names, trims values and sorts by name" begin
    headers = [
        "X-Amz-Date" => DATE, "Range" => "  bytes=0-9 ",
        "x-amz-content-sha256" => EMPTY_HASH, "Host" => HOST[2],
    ]
    @test sign_example("GET", "/test.txt", [], headers).signature == GET_SIGNATURE
end

const ENCODE_CASES = [
    (name = "unreserved", s = "a-b_c.d~e", keep_slash = false, encoded = "a-b_c.d~e"),
    (name = "key path", s = "p/0001", keep_slash = true, encoded = "p/0001"),
    (name = "query slash", s = "p/0001", keep_slash = false, encoded = "p%2F0001"),
    (name = "reserved", s = "a b+c&d=e", keep_slash = false, encoded = "a%20b%2Bc%26d%3De"),
    (name = "UTF-8", s = "é/ü", keep_slash = true, encoded = "%C3%A9/%C3%BC"),
    (name = "asterisk", s = "*", keep_slash = false, encoded = "%2A"),
    (name = "dollar, once", s = "t\$f.text", keep_slash = true, encoded = "t%24f.text"),
]

@testset "uri_encode: $(case.name)" for case in ENCODE_CASES
    @test SIGNER.uri_encode(case.s; case.keep_slash) == case.encoded
end

@testset "query_string sorts and encodes the parameters" begin
    @test SIGNER.query_string(["b" => "2", "a" => "x y", "c" => ""]) == "?a=x%20y&b=2&c="
    @test SIGNER.query_string(Pair{String, String}[]) == ""
end

@testset "signed_headers adds the session token, authorization and length" begin
    c = Credentials("AKIAX", "s"; session_token = "tok")
    signed = SIGNER.signed_headers(c, "r", "s3", "h", "PUT", "/k"; body = b"abc", at = 0)
    sent = Dict(signed)
    @test sent["x-amz-date"] == "19700101T000000Z" && sent["content-length"] == "3"
    @test sent["x-amz-security-token"] == "tok"
    names = "SignedHeaders=host;x-amz-content-sha256;x-amz-date;x-amz-security-token,"
    @test occursin(names, sent["authorization"])
end
