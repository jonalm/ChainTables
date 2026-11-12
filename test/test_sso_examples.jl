using Test
using ExplicitImports: check_all_explicit_imports_are_public,
    check_all_qualified_accesses_are_public
using ChainTables: ChainTables, Chain, sso_credentials, sso_login

@testset "sso_credentials example" begin
    # After `aws sso login --profile team`, the CLI's cached session signs every request.
    # A fake CLI stands in here, so nothing is run.
    printed = "AWS_ACCESS_KEY_ID=AKIA1\nAWS_SECRET_ACCESS_KEY=s\n"
    fake_cli = profile -> printed
    credentials = sso_credentials("team"; exporter = fake_cli)
    chain = Chain("bkt", "exp/run-1"; region = "eu-north-1", credentials, cache_dir = "/c")
    @test chain.credentials().access_key_id == "AKIA1"
end

@testset "sso_login example" begin
    # Logs in with the AWS CLI, which opens a browser; `runner` stands in for the CLI here.
    ran = Cmd[]
    sso_login("team"; device_code = true, runner = cmd -> push!(ran, cmd))
    @test only(ran) == `aws sso login --profile team --use-device-code`
end

@testset "the examples use only public names" begin
    @test check_all_explicit_imports_are_public(@__MODULE__, @__FILE__) === nothing
    @test check_all_qualified_accesses_are_public(@__MODULE__, @__FILE__) === nothing
end
