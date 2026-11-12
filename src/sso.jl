const SSO_REFRESH_MARGIN = 300.0 # seconds before expiry at which the CLI is run again

const AWS_CLI_MISSING = "the AWS CLI (aws) is not on PATH"

const EXPIRY_FORMAT =
    r"\A(\d{4})-(\d\d)-(\d\d)T(\d\d):(\d\d):(\d\d)(?:\.\d+)?(?:Z|([+-])(\d\d):(\d\d))\z"

"""
    SSOCredentials

The credentials callable `sso_credentials` returns: the last export of one profile's
credentials, and the seams that make the export, read the clock and log in.
"""
mutable struct SSOCredentials{E, C, L, I, S} <: Function
    const profile::String
    const login::Bool
    const exporter::E
    const clock::C
    const login_with::L
    const interactive::I
    const setting::S
    cached::Union{Nothing, Credentials}
    expiry::Float64 # seconds since the epoch; `Inf` when the CLI printed none
end

"""
    sso_credentials(profile; login = false)

Return a credentials callable for `Chain` over the AWS CLI's cache of an `aws sso login`
session.

A call runs `aws configure export-credentials --profile <profile>` and caches the
result until five minutes before the expiry the CLI printed, or forever when it printed
none. A failed export throws with the CLI's own text and the `aws sso login` command to
run, or, when the login worked but the identity lacks the profile's role, with that role
and account. Requires the AWS CLI v2 on `PATH`, and only when called.

- `login`: in an interactive session, a failed export runs `sso_login(profile)` once and
  exports again. Outside one it changes nothing, so a script never blocks on a browser.

Examples: test/test_sso_examples.jl
"""
function sso_credentials(
        profile::AbstractString; login = false,
        # Seams for tests, which need a fake CLI, a clock and an interactive session.
        exporter = run_export_credentials, clock = time, login_with = sso_login,
        interactive = isinteractive, setting = run_configure_get
    )
    isempty(profile) && throw(ArgumentError("sso_credentials: profile must not be empty"))
    return SSOCredentials(
        String(profile), Bool(login), exporter, clock, login_with, interactive, setting,
        nothing, -Inf
    )
end

function (s::SSOCredentials)()
    is_fresh(s) && return s.cached::Credentials
    exported = parse_export_credentials(s.profile, exported_text(s))
    s.cached = exported.credentials
    s.expiry = exported.expiry
    return exported.credentials
end

function is_fresh(s::SSOCredentials)
    return s.cached !== nothing && s.expiry - s.clock() > SSO_REFRESH_MARGIN
end

# No operation logs in by itself (ADR-0029): `login` is the opt-in, and only interactively.
function exported_text(s::SSOCredentials)
    attempt = export_attempt(s)
    if !attempt.ok && s.login && s.interactive()
        s.login_with(s.profile)
        attempt = export_attempt(s)
    end
    detail = export_failure_message(s, attempt.text)
    attempt.ok || throw(CredentialsError(; s.profile, detail))
    return attempt.text
end

# The exporter returns what the CLI printed or throws (BioMeCore's fakes throw an
# ErrorException), so any exception is a failed export whose text is the CLI's.
function export_attempt(s::SSOCredentials)
    return try
        (; ok = true, text = String(s.exporter(s.profile)))
    catch e
        e isa Exception || rethrow()
        (; ok = false, text = failure_text(e))
    end
end

failure_text(e::CredentialsError) = e.detail
failure_text(e::Exception) = sprint(showerror, e)

function export_failure_message(s::SSOCredentials, cli_text)
    failed = "aws configure export-credentials --profile $(s.profile) failed: $cli_text\n"
    is_role_refusal(cli_text) || return failed * login_hint(s.profile)
    role = s.setting(s.profile, "sso_role_name")
    account = s.setting(s.profile, "sso_account_id")
    return failed * "The login worked, but this identity is not assigned role $role on " *
        "account $account; an Identity Center admin must assign it."
end

# Logged in, but not assigned the profile's role: logging in again cannot help.
function is_role_refusal(cli_text)
    return occursin("ForbiddenException", cli_text) &&
        occursin("GetRoleCredentials", cli_text)
end

function login_hint(profile)
    return "Log in with `aws sso login --profile $profile` (add --use-device-code if " *
        "the browser cannot reach the authorize page)."
end

"""
    run_export_credentials(profile)

Run `aws configure export-credentials` for `profile` and return what it printed. Throws
`CredentialsError` with the CLI's error output when it fails.
"""
function run_export_credentials(profile::AbstractString)
    Sys.which("aws") === nothing &&
        throw(CredentialsError(; profile, detail = AWS_CLI_MISSING))
    out, err = IOBuffer(), IOBuffer()
    command = `aws configure export-credentials --profile $profile --format env-no-export`
    ok = success(pipeline(command; stdout = out, stderr = err))
    text = String(strip(String(take!(ok ? out : err))))
    ok || throw(CredentialsError(; profile, detail = text))
    return text
end

# For an error message only: the profile's value of `key`, or why reading it failed, so
# the original failure is never masked.
function run_configure_get(profile::AbstractString, key::AbstractString)
    Sys.which("aws") === nothing && return "<$key: $AWS_CLI_MISSING>"
    out, err = IOBuffer(), IOBuffer()
    command = `aws configure get $key --profile $profile`
    success(pipeline(command; stdout = out, stderr = err)) ||
        return "<$key: $(strip(String(take!(err))))>"
    return String(strip(String(take!(out))))
end

"""
    parse_export_credentials(profile, text)

Return `(; credentials, expiry)` from the `KEY=value` lines `aws configure
export-credentials --format env-no-export` printed for `profile`; `expiry` is the
`AWS_CREDENTIAL_EXPIRATION` in seconds since the epoch, `Inf` when absent.
"""
function parse_export_credentials(profile, text::AbstractString)
    lines = Dict{String, String}(
        assignment(line) for line in eachline(IOBuffer(text)) if occursin('=', line)
    )
    has_keys = haskey(lines, "AWS_ACCESS_KEY_ID") && haskey(lines, "AWS_SECRET_ACCESS_KEY")
    has_keys || throw(CredentialsError(; profile, detail = no_keys_message(profile, lines)))
    credentials = Credentials(
        lines["AWS_ACCESS_KEY_ID"], lines["AWS_SECRET_ACCESS_KEY"];
        session_token = get(lines, "AWS_SESSION_TOKEN", nothing)
    )
    stamp = get(lines, "AWS_CREDENTIAL_EXPIRATION", nothing)
    expiry = stamp === nothing ? Inf : Float64(parse_expiry(profile, stamp))
    return (; credentials, expiry)
end

# A value may itself contain '='.
function assignment(line)
    name, value = split(line, '='; limit = 2)
    return String(name) => String(value)
end

function no_keys_message(profile, lines)
    return "aws configure export-credentials --profile $profile printed no " *
        "AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY, only $(sort!(collect(keys(lines))))"
end

# `YYYY-MM-DDThh:mm:ss[.fff](Z|±hh:mm)`, as the CLI prints it, in seconds since the epoch.
function parse_expiry(profile, text::AbstractString)
    m = match(EXPIRY_FORMAT, text)
    detail = expiry_message(profile, text)
    m === nothing && throw(CredentialsError(; profile, detail))
    utc = unix_seconds(map(parse_int, m.captures[1:6])...)
    m.captures[7] === nothing && return utc
    offset = parse(Int, m.captures[8]) * 3600 + parse(Int, m.captures[9]) * 60
    return m.captures[7] == "+" ? utc - offset : utc + offset
end

function expiry_message(profile, text)
    return "aws configure export-credentials --profile $profile: cannot parse " *
        "AWS_CREDENTIAL_EXPIRATION $(repr(text))"
end

"""
    sso_login(profile; device_code = false)
    sso_login(bucket::Bucket; device_code = false)

Run `aws sso login --profile <profile>` attached to this terminal and return `nothing`
once the CLI succeeds; for a `Bucket`, log in with its profile.

It opens a browser and blocks until the login completes, so no ChainTables operation
calls it. Throws when the CLI is not on `PATH` or exits non-zero.

- `device_code`: add `--use-device-code`, for a browser that cannot reach the authorize
  page.

Examples: test/test_sso_examples.jl
"""
function sso_login end

# `runner` is a seam for tests, which must not run the CLI.
function sso_login(profile::AbstractString; device_code = false, runner = run_sso_login)
    isempty(profile) && throw(ArgumentError("sso_login: profile must not be empty"))
    command = `aws sso login --profile $profile`
    runner(device_code ? `$command --use-device-code` : command)
    return nothing
end

# The login prints a URL and a code and waits, so the CLI gets this process's terminal.
const CLI_FAILED = "the CLI exited non-zero"

function run_sso_login(command::Cmd)
    Sys.which("aws") === nothing &&
        throw(CredentialsError(; detail = login_failure_message(command, AWS_CLI_MISSING)))
    success(command) ||
        throw(CredentialsError(; detail = login_failure_message(command, CLI_FAILED)))
    return nothing
end

login_failure_message(command, why) = "$(join(command.exec, ' ')) failed: $why"
