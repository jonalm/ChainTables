using Test
using ChainTables: Chain, Credentials, CredentialsExportError, ProfileCredentials,
    sso_credentials

# 2009-10-12T17:50:00Z in Unix seconds, and the forms the AWS CLI prints it in.
const END_SECONDS = 1255369800
const EXPIRY_FORMS = [
    "2009-10-12T17:50:00Z", "2009-10-12T17:50:00.123Z", "2009-10-12T19:50:00+02:00",
    "2009-10-12T12:20:00-05:30",
]
const FORBIDDEN = "An error occurred (ForbiddenException) when calling the " *
    "GetRoleCredentials operation: No access"
const SETTINGS = Dict("sso_role_name" => "writer", "sso_account_id" => "123456789012")
const UNREADABLE = [
    (name = "empty", text = ""),
    (name = "no secret", text = "AWS_ACCESS_KEY_ID=a\n"),
    (name = "no =", text = "AWS_ACCESS_KEY_ID\n"),
    (
        name = "a date-only expiry",
        text = "AWS_ACCESS_KEY_ID=a\nAWS_SECRET_ACCESS_KEY=b\n" *
            "AWS_CREDENTIAL_EXPIRATION=2009-10-12\n",
    ),
]

function export_text(id; expiry = "2009-10-12T17:50:00Z")
    text = "AWS_ACCESS_KEY_ID=$id\nAWS_SECRET_ACCESS_KEY=s3cret\nAWS_SESSION_TOKEN=tok\n"
    return expiry === nothing ? text : text * "AWS_CREDENTIAL_EXPIRATION=$expiry\n"
end

# A Fake exporter that counts its runs: the n-th run exports the key id AKIA<n>.
struct CountingExporter
    runs::Vector{String}
    expiry::Union{Nothing, String}
end

CountingExporter(expiry) = CountingExporter(String[], expiry)

function (exporter::CountingExporter)(profile)
    push!(exporter.runs, profile)
    return export_text("AKIA$(length(exporter.runs))"; exporter.expiry)
end

failing_exporter(message) = _ -> error(message)

@testset "sso_credentials returns the credentials that the CLI exported" begin
    source = sso_credentials("team"; exporter = CountingExporter(nothing))
    @test source() == Credentials("AKIA1", "s3cret"; session_token = "tok")
end

@testset "sso_credentials keeps the credentials until five minutes before their end" begin
    clock = Ref(END_SECONDS - 3600.0)
    exporter = CountingExporter("2009-10-12T17:50:00Z")
    source = sso_credentials("team"; exporter, clock = () -> clock[])
    @test source().access_key_id == "AKIA1"
    @test source().access_key_id == "AKIA1"
    @test exporter.runs == ["team"]
    clock[] = END_SECONDS - 299
    @test source().access_key_id == "AKIA2"
    clock[] = END_SECONDS - 301
    @test source().access_key_id == "AKIA2"
    @test length(exporter.runs) == 2
end

@testset "sso_credentials reads each form of the end the CLI prints" begin
    @testset "$expiry" for expiry in EXPIRY_FORMS
        clock = Ref(END_SECONDS - 301.0)
        exporter = CountingExporter(expiry)
        source = sso_credentials("team"; exporter, clock = () -> clock[])
        source()
        source()
        @test length(exporter.runs) == 1
        clock[] = END_SECONDS - 299
        source()
        @test length(exporter.runs) == 2
    end
end

@testset "sso_credentials exports once when the CLI prints no end" begin
    exporter = CountingExporter(nothing)
    source = sso_credentials("static"; exporter, clock = () -> 1.0e12)
    @test source().access_key_id == "AKIA1"
    @test source().access_key_id == "AKIA1"
    @test length(exporter.runs) == 1
end

@testset "sso_credentials reads a value that holds = and lines that end in CRLF" begin
    text = "AWS_ACCESS_KEY_ID=a\r\nAWS_SECRET_ACCESS_KEY=b=c\r\n"
    @test sso_credentials("team"; exporter = _ -> text)() == Credentials("a", "b=c")
end

@testset "sso_credentials throws CredentialsExportError when the export fails" begin
    exporter = failing_exporter("The SSO session has expired")
    source = sso_credentials("team"; exporter)
    login = "aws sso login --profile team"
    err = (@test_throws CredentialsExportError login source()).value
    @test err.reason === :login_needed
    @test err.profile == "team"
    @test err.detail == "The SSO session has expired"
    @test occursin("--use-device-code", sprint(showerror, err))
end

@testset "sso_credentials names the role and the account when AWS refuses the role" begin
    source = sso_credentials(
        "team"; exporter = failing_exporter(FORBIDDEN), setting = (p, k) -> SETTINGS[k]
    )
    err = (@test_throws CredentialsExportError "role = writer" source()).value
    @test err.reason === :role_not_assigned
    @test err.account == "123456789012"
    @test occursin("No access", err.detail)
    @test !occursin("aws sso login", sprint(showerror, err))
end

@testset "sso_credentials throws CredentialsExportError for output it cannot read" begin
    @testset "$(case.name)" for case in UNREADABLE
        source = sso_credentials("team"; exporter = _ -> case.text)
        err = (@test_throws CredentialsExportError "Update the AWS CLI" source()).value
        @test err.reason === :unreadable_output
    end
end

@testset "sso_credentials refuses an empty profile" begin
    @test_throws ArgumentError "profile must not be empty" sso_credentials("")
end

@testset "sso_credentials with login logs in once in an interactive session" begin
    exports, logins = Ref(0), String[]
    good = export_text("AKIA1"; expiry = nothing)
    expired_once = _ -> (exports[] += 1) == 1 ? error("expired") : good
    source = sso_credentials(
        "team"; login = true, exporter = expired_once, interactive = () -> true,
        login_with = profile -> push!(logins, profile),
    )
    @test source().access_key_id == "AKIA1"
    @test source().access_key_id == "AKIA1"
    @test exports[] == 2
    @test logins == ["team"]
end

@testset "sso_credentials with login throws when the export fails after the login" begin
    logins = String[]
    source = sso_credentials(
        "team"; login = true, exporter = failing_exporter("expired"),
        interactive = () -> true, login_with = profile -> push!(logins, profile),
    )
    @test_throws CredentialsExportError "aws sso login --profile team" source()
    @test logins == ["team"]
end

@testset "sso_credentials with login does not export again after a failed login" begin
    exports = Ref(0)
    source = sso_credentials(
        "team"; login = true, exporter = _ -> (exports[] += 1; error("expired")),
        interactive = () -> true, login_with = _ -> error("cancelled"),
    )
    err = (@test_throws CredentialsExportError "cancelled" source()).value
    @test err.reason === :login_needed
    @test exports[] == 1
end

@testset "sso_credentials with login does not log in outside an interactive session" begin
    logins = String[]
    source = sso_credentials(
        "team"; login = true, exporter = failing_exporter("expired"),
        interactive = () -> false, login_with = profile -> push!(logins, profile),
    )
    @test_throws CredentialsExportError "expired" source()
    @test isempty(logins)
end

@testset "sso_credentials without login never logs in" begin
    logins = String[]
    source = sso_credentials(
        "team"; exporter = failing_exporter("expired"), interactive = () -> true,
        login_with = profile -> push!(logins, profile),
    )
    @test_throws CredentialsExportError "aws sso login --profile team" source()
    @test isempty(logins)
end

@testset "sso_credentials gives Chain credentials that it reads before each request" begin
    exporter = CountingExporter(nothing)
    source = sso_credentials("team"; exporter)
    chain = Chain("bkt", "p"; region = "eu-north-1", credentials = source, cache_dir = "/c")
    @test length(exporter.runs) == 1
    @test !occursin("s3cret", sprint(show, chain.store))
end

@testset "sso_credentials infers" begin
    source = @inferred sso_credentials("team"; exporter = CountingExporter(nothing))
    @test source isa ProfileCredentials
    @test @inferred(source()) isa Credentials
end
