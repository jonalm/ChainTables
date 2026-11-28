const LOGIN_NEEDED_NEXT_MOVE = "Log in with `aws sso login --profile <profile>` (add " *
    "`--use-device-code` when the browser cannot reach the authorize page), or with " *
    "`ChainTables.sso_login(profile)`."

const CREDENTIALS_EXPORT_NEXT_MOVES = Dict(
    :login_needed => LOGIN_NEEDED_NEXT_MOVE,
    :role_not_assigned => "The login worked, but the identity is not assigned the " *
        "profile's role on its account, and a login does not change that. An Identity " *
        "Center admin must assign it.",
    :unreadable_output => "The AWS CLI printed no credentials this client can read. " *
        "Update the AWS CLI to v2.",
)

"""
    CredentialsExportError

Thrown when the AWS CLI exports no credentials for a profile.

`reason` is `:login_needed` when the export failed: no login, an expired one, an unknown
profile or no CLI. It is `:role_not_assigned` when AWS refused the role (a
`ForbiddenException`); `role` and `account` are the profile's. It is
`:unreadable_output` when the CLI printed no credentials this client reads. `detail` is
what the CLI or the export said.
"""
Base.@kwdef struct CredentialsExportError <: ChainTablesError
    profile::Union{Nothing, String} = nothing
    role::Union{Nothing, String} = nothing
    account::Union{Nothing, String} = nothing
    reason::Union{Nothing, Symbol} = nothing
    detail::String = ""
end

function Base.showerror(io::IO, e::CredentialsExportError)
    print_summary(io, e, "the AWS CLI exported no credentials for the profile.")
    print_evidence(io, e)
    next_move = get(CREDENTIALS_EXPORT_NEXT_MOVES, e.reason, LOGIN_NEEDED_NEXT_MOVE)
    print(io, replace(next_move, "<profile>" => something(e.profile, "<profile>")))
    return nothing
end

"""
    LoginError

Thrown when `sso_login` runs `aws sso login` and it fails. `command` is the command it
ran, and `detail` what the run said.
"""
Base.@kwdef struct LoginError <: ChainTablesError
    profile::Union{Nothing, String} = nothing
    command::Union{Nothing, String} = nothing
    detail::String = ""
end

function Base.showerror(io::IO, e::LoginError)
    print_summary(io, e, "the login failed.")
    print_evidence(io, e)
    print(io, "Run the command in a terminal to see what the AWS CLI says. ")
    print(io, "It needs the AWS CLI v2 on PATH.")
    return nothing
end
