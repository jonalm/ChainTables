using Test
using ChainTables: CredentialsExportError, LoginError

const LOGIN = "Log in with `aws sso login --profile team` (add `--use-device-code` " *
    "when the browser cannot reach the authorize page), or with " *
    "`ChainTables.sso_login(profile)`."
const NEXT_MOVES = [
    (reason = :login_needed, fragment = "Log in with `aws sso login --profile team`"),
    (reason = :role_not_assigned, fragment = "An Identity Center admin must assign it."),
    (reason = :unreadable_output, fragment = "Update the AWS CLI to v2."),
    (reason = nothing, fragment = "Log in with `aws sso login --profile team`"),
]

@testset "CredentialsExportError shows what happened, the evidence and the next move" begin
    e = CredentialsExportError(;
        profile = "team", reason = :login_needed, detail = "The SSO session has expired"
    )
    @test sprint(showerror, e) ==
        "CredentialsExportError: the AWS CLI exported no credentials for the profile.\n" *
        "The SSO session has expired\n" *
        "  profile = team\n" *
        "  reason = login_needed\n" *
        LOGIN
end

@testset "CredentialsExportError shows the role and the account it was refused" begin
    e = CredentialsExportError(;
        profile = "team", role = "writer", account = "123456789012",
        reason = :role_not_assigned,
    )
    text = sprint(showerror, e)
    @test occursin("  role = writer\n  account = 123456789012\n", text)
    @test !occursin("aws sso login", text)
end

@testset "CredentialsExportError takes its next move from the reason" begin
    @testset "$(repr(case.reason))" for case in NEXT_MOVES
        e = CredentialsExportError(; profile = "team", case.reason)
        @test occursin(case.fragment, last(split(sprint(showerror, e), "\n")))
    end
end

@testset "LoginError shows what happened, the evidence and the next move" begin
    e = LoginError(;
        profile = "team", command = "aws sso login --profile team",
        detail = "the AWS CLI (aws) is not on PATH",
    )
    @test sprint(showerror, e) ==
        "LoginError: the login failed.\n" *
        "the AWS CLI (aws) is not on PATH\n" *
        "  profile = team\n" *
        "  command = aws sso login --profile team\n" *
        "Run the command in a terminal to see what the AWS CLI says. It needs the AWS " *
        "CLI v2 on PATH."
end
