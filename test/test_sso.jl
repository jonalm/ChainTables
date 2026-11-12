using Test
using ChainTables: ChainTables, Credentials, CredentialsError, S3ObjectStore, sso_credentials, sso_login

const T0 = 1255369800.0 # 2009-10-12T17:50:00Z

function export_text(id, expiry)
    return "AWS_ACCESS_KEY_ID=$id\nAWS_SECRET_ACCESS_KEY=s3cret\nAWS_SESSION_TOKEN=tok\n" *
        "AWS_CREDENTIAL_EXPIRATION=$expiry\n"
end

exported(text) = (; ok = true, text)
refused(text) = (; ok = false, text)

# A fake CLI that prints `text` and counts its runs in `runs`.
function counting_exporter(runs, text)
    return profile -> (push!(runs, profile); exported(text(length(runs))))
end

@testset "sso_credentials infers" begin
    @test @inferred(sso_credentials("team")) isa Function
end

@testset "sso_credentials refuses an empty profile" begin
    @test_throws ArgumentError "profile must not be empty" sso_credentials("")
end

const EXPIRY_CASES = [
    (name = "Z", stamp = "2009-10-12T17:50:00Z"),
    (name = "fraction", stamp = "2009-10-12T17:50:00.123Z"),
    (name = "east of UTC", stamp = "2009-10-12T19:50:00+02:00"),
    (name = "west of UTC", stamp = "2009-10-12T12:20:00-05:30"),
]

@testset "sso_credentials reads the expiry: $(case.name)" for case in EXPIRY_CASES
    runs = String[]
    clock = Ref(T0 - 301)
    get_credentials = sso_credentials(
        "team"; exporter = counting_exporter(runs, n -> export_text("AKIA$n", case.stamp)),
        clock = () -> clock[]
    )
    @test get_credentials() == Credentials("AKIA1", "s3cret"; session_token = "tok")
    @test get_credentials().access_key_id == "AKIA1" # cached: outside the margin
    clock[] = T0 - 299
    @test get_credentials().access_key_id == "AKIA2" # refreshed within five minutes
    @test runs == ["team", "team"]
end

@testset "sso_credentials exports once when no expiry is printed" begin
    runs = String[]
    printed(n) = "AWS_ACCESS_KEY_ID=K$n\nAWS_SECRET_ACCESS_KEY=s"
    static = sso_credentials("static"; exporter = counting_exporter(runs, printed))
    @test static().access_key_id == "K1"
    @test static().access_key_id == "K1"
    @test runs == ["static"]
end

const EXPORT_CASES = [
    (
        name = "CRLF and = in a value",
        text = "AWS_ACCESS_KEY_ID=a\r\nAWS_SECRET_ACCESS_KEY=b=c\r\n",
        credentials = Credentials("a", "b=c"),
    ),
    (
        name = "no token", text = "AWS_ACCESS_KEY_ID=a\nAWS_SECRET_ACCESS_KEY=b\n",
        credentials = Credentials("a", "b"),
    ),
]

@testset "sso_credentials parses the export: $(case.name)" for case in EXPORT_CASES
    @test sso_credentials("team"; exporter = _ -> exported(case.text))() == case.credentials
end

const BAD_EXPORT_CASES = [
    (
        name = "unparsable expiry", text = export_text("a", "2009-10-12"),
        says = "cannot parse AWS_CREDENTIAL_EXPIRATION \"2009-10-12\"",
    ),
    (
        name = "no secret", text = "AWS_ACCESS_KEY_ID=a\n",
        says = "export-credentials --profile team printed no AWS_ACCESS_KEY_ID",
    ),
    (name = "nothing", text = "", says = "printed no AWS_ACCESS_KEY_ID/AWS_SECRET"),
]

@testset "sso_credentials refuses an export: $(case.name)" for case in BAD_EXPORT_CASES
    get_credentials = sso_credentials("team"; exporter = _ -> exported(case.text))
    @test_throws CredentialsError case.says get_credentials()
end

const EXPIRED = "The SSO session associated with this profile has expired"

@testset "sso_credentials names the login command when the export fails" begin
    failing = sso_credentials("team"; exporter = _ -> refused(EXPIRED))
    @test_throws CredentialsError "aws sso login --profile team" failing()
    @test_throws CredentialsError "--use-device-code" failing()
    @test_throws CredentialsError EXPIRED failing()
end

@testset "sso_credentials names the role when the identity lacks it" begin
    forbidden = "An error occurred (ForbiddenException) when calling the " *
        "GetRoleCredentials operation: No access"
    settings = Dict("sso_role_name" => "writer", "sso_account_id" => "123456789012")
    no_access = sso_credentials(
        "team"; exporter = _ -> refused(forbidden), setting = (p, k) -> settings[k]
    )
    says = "not assigned role writer on account 123456789012"
    e = (@test_throws CredentialsError says no_access()).value
    @test occursin("No access", sprint(showerror, e))
    @test !occursin("aws sso login", sprint(showerror, e))
end

@testset "sso_credentials without the CLI on PATH says so" begin
    mktempdir() do dir
        withenv("PATH" => dir) do
            get_credentials = sso_credentials("team")
            @test_throws CredentialsError "the AWS CLI (aws) is not on PATH" get_credentials()
        end
    end
end

# An exporter that fails `failures` times, then exports.
function flaky_exporter(exports, failures)
    return _ -> (exports[] += 1) <= failures ? refused(EXPIRED) :
        exported("AWS_ACCESS_KEY_ID=AKIA1\nAWS_SECRET_ACCESS_KEY=s3cret\n")
end

@testset "sso_credentials with login logs in once, interactively, and exports again" begin
    exports, logins = Ref(0), String[]
    get_credentials = sso_credentials(
        "team"; login = true, exporter = flaky_exporter(exports, 1),
        login_with = p -> push!(logins, p), interactive = () -> true
    )
    @test get_credentials().access_key_id == "AKIA1"
    @test get_credentials().access_key_id == "AKIA1"
    @test (exports[], logins) == (2, ["team"])
end

@testset "sso_credentials with login fails after one login when the export fails" begin
    exports, logins = Ref(0), String[]
    still = sso_credentials(
        "team"; login = true, exporter = flaky_exporter(exports, 2),
        login_with = p -> push!(logins, p), interactive = () -> true
    )
    @test_throws CredentialsError "aws sso login --profile team" still()
    @test logins == ["team"]
end

@testset "sso_credentials with login reports a failed login and exports no more" begin
    exports = Ref(0)
    cancelled = _ -> throw(ArgumentError("aws sso login --profile team failed: cancelled"))
    no_login = sso_credentials(
        "team"; login = true, exporter = flaky_exporter(exports, 9), login_with = cancelled,
        interactive = () -> true
    )
    @test_throws ArgumentError "aws sso login --profile team failed: cancelled" no_login()
    @test exports[] == 1
end

const NO_LOGIN_CASES = [
    (name = "login outside an interactive session", login = true, interactive = false),
    (name = "no login, interactive", login = false, interactive = true),
]

@testset "sso_credentials never logs in: $(case.name)" for case in NO_LOGIN_CASES
    logins = String[]
    batch = sso_credentials(
        "team"; case.login, exporter = flaky_exporter(Ref(0), 9),
        login_with = p -> push!(logins, p), interactive = () -> case.interactive
    )
    @test_throws CredentialsError EXPIRED batch()
    @test isempty(logins)
end

@testset "sso_credentials is a callable S3ObjectStore signs with" begin
    text = export_text("AKIA1", "2999-01-01T00:00:00Z")
    get_credentials = sso_credentials("team"; exporter = _ -> exported(text))
    store = S3ObjectStore("bkt"; region = "eu-north-1", credentials = get_credentials)
    @test ChainTables.current_credentials(store).access_key_id == "AKIA1"
    @test !occursin("s3cret", sprint(show, store))
end

@testset "sso_login infers" begin
    @test @inferred(sso_login("team"; runner = identity)) === nothing
end

const LOGIN_CASES = [
    (name = "browser", device_code = false, command = `aws sso login --profile team`),
    (
        name = "device code", device_code = true,
        command = `aws sso login --profile team --use-device-code`,
    ),
]

@testset "sso_login runs the CLI: $(case.name)" for case in LOGIN_CASES
    ran = Cmd[]
    @test sso_login("team"; case.device_code, runner = cmd -> push!(ran, cmd)) === nothing
    @test only(ran) == case.command
end

@testset "sso_login refuses an empty profile" begin
    @test_throws ArgumentError "sso_login: profile must not be empty" sso_login("")
end

const NO_CLI = "aws sso login --profile team --use-device-code failed: " *
    "the AWS CLI (aws) is not on PATH"

@testset "sso_login without the CLI on PATH names the command" begin
    mktempdir() do dir
        withenv("PATH" => dir) do
            @test_throws CredentialsError NO_CLI sso_login("team"; device_code = true)
        end
    end
end
