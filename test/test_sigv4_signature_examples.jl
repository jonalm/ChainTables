using Test
using ChainTables: Credentials
using ChainTables.SigV4: amz_date, canonical_query, sign_request, uri_encode

@testset "sign_request example" begin
    # The headers to sign: the host, the hash of the body and the time, each as
    # `amz_date` writes it.
    credentials = Credentials("AKIDEXAMPLE", "secret")
    at = 1_700_000_000
    empty_hash = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    headers = [
        "host" => "bkt.s3.eu-north-1.amazonaws.com",
        "x-amz-content-sha256" => empty_hash, "x-amz-date" => amz_date(at),
    ]
    signed = sign_request(
        credentials; method = "GET", path = "/p/000000000001", query = [], headers,
        payload_hash = empty_hash, at, region = "eu-north-1", service = "s3",
    )

    # The value of the Authorization header names the key, the scope and the headers.
    @test startswith(
        signed.authorization,
        "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20231114/eu-north-1/s3/aws4_request, " *
            "SignedHeaders=host;x-amz-content-sha256;x-amz-date, Signature=",
    )
end

@testset "uri_encode example" begin
    # An object key keeps its slashes; a query value does not.
    @test uri_encode("p/a b"; keep_slash = true) == "p/a%20b"
    @test uri_encode("p/a b") == "p%2Fa%20b"
end

@testset "amz_date example" begin
    @test amz_date(1_700_000_000) == "20231114T221320Z"
end

@testset "canonical_query example" begin
    @test canonical_query(["prefix" => "p/", "list-type" => "2"]) ==
        "list-type=2&prefix=p%2F"
end
