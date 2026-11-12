using Test
using ChainTables: ChainTables, Chain, Credentials

@testset "Credentials example" begin
    # The keys a request is signed with; the session token is optional.
    credentials = Credentials("AKIAEXAMPLE", "secret"; session_token = "token")
    # Printing never shows the secret.
    shown = "Credentials(\"AKIAEXAMPLE\", \"***\"; session_token = \"***\")"
    @test sprint(show, credentials) == shown
    # A chain on the S3 client signs with them.
    chain = Chain("bkt", "exp/run-1"; region = "eu-north-1", credentials, cache_dir = "/c")
    @test chain.credentials === credentials
end
