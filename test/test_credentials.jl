using Test
using ChainTables: ChainTables, Chain, Credentials, CredentialsError, S3ObjectStore

const SECRET_ENV = ("AWS_ACCESS_KEY_ID" => "AKIAX", "AWS_SECRET_ACCESS_KEY" => "s3cret")

@testset "Credentials infers" begin
    @test @inferred(Credentials("id", "secret")).session_token === nothing
    @test @inferred(Credentials("id", "secret"; session_token = "t")).session_token == "t"
end

@testset "Credentials coerces its arguments" begin
    token = SubString("t")
    c = Credentials(SubString("xid", 2), SubString("secret"); session_token = token)
    @test c == Credentials("id", "secret"; session_token = "t")
    @test c.access_key_id isa String
end

@testset "Credentials shows the key id and redacts the secret and the token" begin
    @test sprint(show, Credentials("id", "secret")) == "Credentials(\"id\", \"***\")"
    @test sprint(show, Credentials("id", "secret"; session_token = "tok")) ==
        "Credentials(\"id\", \"***\"; session_token = \"***\")"
end

@testset "Chain reads credentials from the environment" begin
    withenv(SECRET_ENV..., "AWS_SESSION_TOKEN" => nothing) do
        chain = Chain("bkt", "p"; region = "eu-north-1", cache_dir = "/c")
        @test chain.credentials == Credentials("AKIAX", "s3cret")
    end
    withenv(SECRET_ENV..., "AWS_SESSION_TOKEN" => "tok") do
        chain = Chain("bkt", "p"; region = "eu-north-1", cache_dir = "/c")
        @test chain.credentials.session_token == "tok"
    end
end

const UNSET_CASES = [
    (
        name = "no key id",
        env = ("AWS_ACCESS_KEY_ID" => nothing, "AWS_SECRET_ACCESS_KEY" => "s"),
        says = "AWS_ACCESS_KEY_ID is not set",
    ),
    (
        name = "neither",
        env = ("AWS_ACCESS_KEY_ID" => "", "AWS_SECRET_ACCESS_KEY" => nothing),
        says = "AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY is not set",
    ),
]

@testset "Chain refuses an environment without keys: $(case.name)" for case in UNSET_CASES
    withenv(case.env...) do
        make = () -> Chain("bkt", "p"; region = "eu-north-1")
        @test_throws CredentialsError case.says make()
        @test_throws CredentialsError "aws-vault exec" make()
    end
end

signing_with(credentials) = Chain("bkt", "p"; region = "r", credentials, cache_dir = "/c")

@testset "Chain takes a Credentials or a value with key properties" begin
    c = Credentials("id", "secret"; session_token = "tok")
    @test signing_with(c).credentials === c
    plain = (; access_key_id = "id", secret_access_key = "secret")
    @test signing_with(plain).credentials == Credentials("id", "secret")
    session = (; plain..., session_token = "t")
    @test signing_with(session).credentials.session_token == "t"
end

@testset "Chain calls a credentials callable once now and before every request" begin
    calls = Ref(0)
    supplier = () -> (calls[] += 1; Credentials("id$(calls[])", "secret"))
    chain = signing_with(supplier)
    @test chain.credentials === supplier
    @test calls[] == 1
    @test ChainTables.current_credentials(chain.store).access_key_id == "id2"
    @test ChainTables.current_credentials(chain.store).access_key_id == "id3"
end

@testset "Chain refuses what is not credentials" begin
    @test_throws ArgumentError "credentials must be a ChainTables.Credentials" Chain(
        "bkt", "p"; region = "r", credentials = () -> "nope"
    )
    @test_throws ArgumentError "credentials is a Int64, which is neither" Chain(
        "bkt", "p"; region = "r", credentials = 1
    )
end

@testset "S3ObjectStore shows no secret" begin
    store = S3ObjectStore("bkt"; region = "r", credentials = Credentials("id", "topsecret"))
    @test !occursin("topsecret", sprint(show, store))
end
