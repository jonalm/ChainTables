using Test
using SHA: sha256
using ChainTables: Credentials
using ChainTables.SigV4: amz_date, canonical_query, sign_request, uri_encode

# AWS's worked examples of Signature Version 4 for S3: access key AKIAIOSFODNN7EXAMPLE,
# bucket examplebucket, us-east-1, 2013-05-24T00:00:00Z. The one check against the
# standard rather than against this client.
const AWS_CREDENTIALS =
    Credentials("AKIAIOSFODNN7EXAMPLE", "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY")
const AWS_AT = 1369353600
const AWS_DATE = "20130524T000000Z"
const AWS_HOST = "host" => "examplebucket.s3.amazonaws.com"
const EMPTY_HASH = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
const AWS_SIGNED =
    [AWS_HOST, "x-amz-content-sha256" => EMPTY_HASH, "x-amz-date" => AWS_DATE]

const ENCODED = [
    (text = "a-b_c.d~e", encoded = "a-b_c.d~e"),
    (text = "p/000000000001", encoded = "p%2F000000000001"),
    (text = "a b+c&d=e", encoded = "a%20b%2Bc%26d%3De"),
    (text = "*", encoded = "%2A"),
    (text = "test\$file.text", encoded = "test%24file.text"),
]

const AMZ_DATES = [
    (at = 0, date = "19700101T000000Z"),
    (at = 1369353600, date = "20130524T000000Z"),
    (at = 951782400, date = "20000229T000000Z"),
    (at = 1700000000, date = "20231114T221320Z"),
    (at = 4102444800, date = "21000101T000000Z"),
]

function sign_aws_example(method, path, query, headers, payload_hash)
    return sign_request(
        AWS_CREDENTIALS; method, path, query, headers, payload_hash, at = AWS_AT,
        region = "us-east-1", service = "s3",
    )
end

@testset "sign_request matches AWS's example of a GET with a Range header" begin
    headers = [AWS_HOST, "range" => "bytes=0-9", AWS_SIGNED[2:3]...]
    signed = sign_aws_example("GET", "/test.txt", [], headers, EMPTY_HASH)
    @test signed.canonical_request ==
        "GET\n/test.txt\n\nhost:examplebucket.s3.amazonaws.com\nrange:bytes=0-9\n" *
        "x-amz-content-sha256:$EMPTY_HASH\nx-amz-date:$AWS_DATE\n\n" *
        "host;range;x-amz-content-sha256;x-amz-date\n$EMPTY_HASH"
    @test signed.string_to_sign ==
        "AWS4-HMAC-SHA256\n$AWS_DATE\n20130524/us-east-1/s3/aws4_request\n" *
        "7344ae5b7ee6c3e7e6b0fe0640412a37625d1fbfff95c48bbb2dc43964946972"
    @test signed.signature ==
        "f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41"
    @test signed.authorization ==
        "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/" *
        "aws4_request, SignedHeaders=host;range;x-amz-content-sha256;x-amz-date, " *
        "Signature=f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41"
end

@testset "sign_request matches AWS's example of a PUT with a Date header" begin
    body_hash = bytes2hex(sha256("Welcome to Amazon S3."))
    headers = [
        "date" => "Fri, 24 May 2013 00:00:00 GMT", AWS_HOST,
        "x-amz-content-sha256" => body_hash, "x-amz-date" => AWS_DATE,
        "x-amz-storage-class" => "REDUCED_REDUNDANCY",
    ]
    signed = sign_aws_example("PUT", "/test%24file.text", [], headers, body_hash)
    @test signed.signature ==
        "98ad721746da40c64f1a55b78f14c238d841ea1380cd77a1b5971af0ece108bd"
end

@testset "sign_request matches AWS's example of a query parameter with no value" begin
    signed = sign_aws_example("GET", "/", ["lifecycle" => ""], AWS_SIGNED, EMPTY_HASH)
    @test occursin("\nlifecycle=\n", signed.canonical_request)
    @test signed.signature ==
        "fea454ca298b7da1c68078a5d1bdbfbbe0d65c699e0f91ac7a200a0136783543"
end

@testset "sign_request matches AWS's example of a listing with two parameters" begin
    query = ["prefix" => "J", "max-keys" => "2"]
    signed = sign_aws_example("GET", "/", query, AWS_SIGNED, EMPTY_HASH)
    @test occursin("\nmax-keys=2&prefix=J\n", signed.canonical_request)
    @test signed.signature ==
        "34b48302e7b5fa45bde8084f4b7868a86f0a534bc59db6670ed5711ef69dc6f7"
end

@testset "sign_request lowercases header names and trims their values" begin
    headers = [
        "X-Amz-Date" => AWS_DATE, "Range" => "  bytes=0-9 ",
        "x-amz-content-sha256" => EMPTY_HASH, "Host" => last(AWS_HOST),
    ]
    signed = sign_aws_example("GET", "/test.txt", [], headers, EMPTY_HASH)
    @test signed.signature ==
        "f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41"
end

@testset "sign_request signs for the service given" begin
    s3 = sign_aws_example("GET", "/", [], AWS_SIGNED, EMPTY_HASH)
    lambda = sign_request(
        AWS_CREDENTIALS; method = "GET", path = "/", query = [], headers = AWS_SIGNED,
        payload_hash = EMPTY_HASH, at = AWS_AT, region = "us-east-1", service = "lambda",
    )
    @test occursin("/us-east-1/lambda/aws4_request\n", lambda.string_to_sign)
    @test lambda.signature != s3.signature
end

@testset "sign_request infers" begin
    signed = @inferred sign_request(
        AWS_CREDENTIALS; method = "GET", path = "/", query = ["lifecycle" => ""],
        headers = AWS_SIGNED, payload_hash = EMPTY_HASH, at = AWS_AT,
        region = "us-east-1", service = "s3",
    )
    @test signed.signature ==
        "fea454ca298b7da1c68078a5d1bdbfbbe0d65c699e0f91ac7a200a0136783543"
end

@testset "uri_encode encodes every byte outside the unreserved set" begin
    @testset "$(repr(case.text))" for case in ENCODED
        @test @inferred(uri_encode(case.text)) == case.encoded
    end
end

@testset "uri_encode keeps a slash with keep_slash" begin
    @test uri_encode("p/000000000001"; keep_slash = true) == "p/000000000001"
    @test uri_encode("é/ü"; keep_slash = true) == "%C3%A9/%C3%BC"
end

@testset "canonical_query sorts the pairs and encodes names and values" begin
    query = ["b" => "2", "a" => "x y", "c" => ""]
    @test @inferred(canonical_query(query)) == "a=x%20y&b=2&c="
    @test canonical_query(Pair{String, String}[]) == ""
end

@testset "amz_date writes Unix seconds in UTC" begin
    @testset "$(case.at)" for case in AMZ_DATES
        @test @inferred(amz_date(case.at)) == case.date
    end
end
