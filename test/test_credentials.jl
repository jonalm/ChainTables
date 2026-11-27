using Test
using ChainTables: Credentials

@testset "Credentials takes the session token as a keyword" begin
    credentials = @inferred Credentials("AKIAX", "s3cret"; session_token = "tok")
    @test credentials.access_key_id == "AKIAX"
    @test credentials.secret_access_key == "s3cret"
    @test credentials.session_token == "tok"
    @test (@inferred Credentials("AKIAX", "s3cret")).session_token === nothing
end

@testset "Credentials holds its text as String" begin
    credentials = Credentials(SubString("AKIAX"), "s3cret"; session_token = SubString("t"))
    @test credentials.access_key_id isa String
    @test credentials.session_token isa String
end

@testset "Credentials shows the key id and hides the secret and the token" begin
    @test sprint(show, Credentials("id", "secret")) == "Credentials(\"id\", \"***\")"
    @test sprint(show, Credentials("id", "secret"; session_token = "tok")) ==
        "Credentials(\"id\", \"***\"; session_token = \"***\")"
end
