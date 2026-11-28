using Test
using ChainTables: Chain, Credentials

@testset "Credentials example" begin
    # Credentials for a plain bucket: a key id, its secret, and the token of a session.
    credentials = Credentials("AKIAEXAMPLE", "secret"; session_token = "token")

    # `show` never prints the secret.
    @test !occursin("secret", sprint(show, credentials))

    # A chain signs its requests with them. Constructing it performs no I/O.
    chain = Chain("lab-bucket", "experiments/run-7"; region = "eu-north-1", credentials)
    @test chain.bucket == "lab-bucket"
end
