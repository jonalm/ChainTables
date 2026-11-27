using Test
using ChainTables: LoginError, sso_login

@testset "sso_login runs aws sso login for the profile" begin
    ran = Cmd[]
    @test sso_login("team"; runner = command -> push!(ran, command)) === nothing
    @test sso_login("team"; device_code = true, runner = command -> push!(ran, command)) ===
        nothing
    @test ran[1].exec == ["aws", "sso", "login", "--profile", "team"]
    @test ran[2].exec == ["aws", "sso", "login", "--profile", "team", "--use-device-code"]
end

@testset "sso_login throws LoginError when the runner fails" begin
    missing_cli = _ -> error("the AWS CLI (aws) is not on PATH")
    err = (
        @test_throws LoginError "not on PATH" sso_login("team"; runner = missing_cli)
    ).value
    @test err.command == "aws sso login --profile team"
    @test err.profile == "team"
end

@testset "sso_login throws LoginError when the command exits with an error" begin
    err = (
        @test_throws LoginError "failed process" sso_login(
            "team"; device_code = true, runner = _ -> run(`false`)
        )
    ).value
    @test err.command == "aws sso login --profile team --use-device-code"
end

@testset "sso_login refuses an empty profile" begin
    @test_throws ArgumentError "profile must not be empty" sso_login("")
end

@testset "sso_login infers" begin
    @test @inferred(sso_login("team"; runner = identity)) === nothing
end
