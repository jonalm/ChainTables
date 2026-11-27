# Seconds before the end of exported credentials at which the CLI is run again.
const SSO_REFRESH_MARGIN = 300.0

# `AWS_CREDENTIAL_EXPIRATION` as the CLI prints it: `YYYY-MM-DDThh:mm:ss[.fff]`, then `Z`
# or `±hh:mm`.
const EXPIRY_FORMAT =
    r"\A(\d{4})-(\d\d)-(\d\d)T(\d\d):(\d\d):(\d\d)(?:\.\d+)?(?:Z|([+-])(\d\d):(\d\d))\z"

"""
    ExportedCredentials

The credentials that the AWS CLI exported, and when they end in Unix seconds (`Inf`
when the CLI printed no end).
"""
struct ExportedCredentials
    credentials::Credentials
    expiry::Float64
end

# `cli` holds the steps that a test replaces: the export, the login, the reader of a
# setting, whether the session is interactive, and the clock.
"""
    ProfileCredentials

What `sso_credentials` returns: a callable that returns the `Credentials` of a profile's
login session.
"""
mutable struct ProfileCredentials{C}
    const profile::String
    const login::Bool
    const cli::C
    exported::Union{Nothing, ExportedCredentials}
end

# A long docstring: when the CLI runs, and what `login` does where, is the contract.
# `exporter`, `login_with`, `setting` and `clock` are the CLI and the clock, which a test
# replaces with Fakes.
"""
    sso_credentials(profile; login = false, interactive = isinteractive)

Return a `ProfileCredentials` for `profile`: a callable that returns the `Credentials`
of the AWS CLI's login session, as `Chain`'s `credentials`.

A call runs `aws configure export-credentials --profile <profile>` when it holds no
credentials, or when they end within five minutes, and keeps what the CLI exported. It
needs the AWS CLI v2 on PATH. A call throws `CredentialsExportError` when the CLI
exports none.

- `login`: in an interactive session, a failed export runs `sso_login(profile)` once and
  exports again. Elsewhere it changes nothing, so a job fails rather than wait on a
  browser.
- `interactive`: the test of an interactive session.

Examples: test/test_sso_credentials_examples.jl
"""
function sso_credentials(
        profile::AbstractString; login = false, interactive = isinteractive,
        exporter = run_export_credentials, login_with = sso_login,
        setting = run_configure_get, clock = time,
    )
    isempty(profile) && throw(ArgumentError("sso_credentials: profile must not be empty"))
    cli = (; exporter, login_with, setting, interactive, clock)
    return ProfileCredentials(String(profile), login, cli, nothing)
end

function (source::ProfileCredentials)()
    exported = source.exported
    is_fresh(exported, source.cli.clock()) && return exported.credentials
    exported = export_credentials(source)
    source.exported = exported
    return exported.credentials
end

is_fresh(::Nothing, now) = false
is_fresh(exported::ExportedCredentials, now) = exported.expiry - now > SSO_REFRESH_MARGIN

function export_credentials(source::ProfileCredentials)
    text = exported_text(source)
    exported = try
        parse_export_credentials(text)
    catch e
        e isa AWSCLIError || rethrow()
        profile = source.profile
        throw(CredentialsExportError(; profile, reason = :unreadable_output, e.detail))
    end
    return exported
end

function exported_text(source::ProfileCredentials)
    profile, setting = source.profile, source.cli.setting
    # style: catch-all the exporter may be the caller's; any failure means no credentials
    try
        return export_with_login(source)
    catch e
        e isa Exception || rethrow()
        detail = failure_text(e)
        is_role_refusal(detail) && throw(
            CredentialsExportError(;
                profile, role = setting(profile, "sso_role_name"),
                account = setting(profile, "sso_account_id"),
                reason = :role_not_assigned, detail,
            )
        )
        throw(CredentialsExportError(; profile, reason = :login_needed, detail))
    end
end

# A login only on request and in an interactive session (ADR-0029): elsewhere a browser
# would block the run.
function export_with_login(source::ProfileCredentials)
    profile, cli = source.profile, source.cli
    (source.login && cli.interactive()) || return cli.exporter(profile)
    # style: catch-all any failed export is answered by one login and one more export
    try
        return cli.exporter(profile)
    catch e
        e isa Exception || rethrow()
        cli.login_with(profile)
        return cli.exporter(profile)
    end
end

# Logged in, but the identity is not assigned the profile's role.
function is_role_refusal(text::AbstractString)
    return occursin("ForbiddenException", text) && occursin("GetRoleCredentials", text)
end

function parse_export_credentials(text::AbstractString)
    lines = split(text, r"\r?\n"; keepempty = false)
    variables = Dict(map(variable_pair, lines))
    all(name -> haskey(variables, name), CREDENTIAL_VARIABLES) || throw(
        AWSCLIError(
            "the export printed no AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY, only " *
                "$(sort!(collect(keys(variables))))"
        )
    )
    session_token = get(variables, "AWS_SESSION_TOKEN", nothing)
    keys_and_secret = map(name -> variables[name], CREDENTIAL_VARIABLES)
    credentials = Credentials(keys_and_secret...; session_token)
    expiry = get(variables, "AWS_CREDENTIAL_EXPIRATION", nothing)
    return ExportedCredentials(credentials, expiry === nothing ? Inf : parse_expiry(expiry))
end

# A value may hold `=` itself.
function variable_pair(line::AbstractString)
    occursin('=', line) || throw(AWSCLIError("the export printed $(repr(line))"))
    name, value = split(line, '='; limit = 2)
    return String(name) => String(value)
end

function parse_expiry(text::AbstractString)
    m = match(EXPIRY_FORMAT, text)
    m === nothing && throw(
        AWSCLIError("the export printed AWS_CREDENTIAL_EXPIRATION $(repr(text))")
    )
    year, month, day, hour, minute, second = captured_ints(m, 1:6)
    local_seconds = unix_seconds(year, month, day, hour * 3600 + minute * 60 + second)
    return Float64(local_seconds - utc_offset_seconds(m))
end

function utc_offset_seconds(m::RegexMatch)
    m[7] === nothing && return 0
    hours, minutes = captured_ints(m, 8:9)
    return (m[7] == "+" ? 1 : -1) * (hours * 3600 + minutes * 60)
end
