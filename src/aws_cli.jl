const AWS_CLI_MISSING = "the AWS CLI (aws) is not on PATH"

"""
    AWSCLIError(detail)

Thrown when the AWS CLI fails, or prints what this client cannot read. `sso_credentials`
throws `CredentialsExportError` for it, and `sso_login` throws `LoginError`.
"""
struct AWSCLIError <: Exception
    detail::String
end

# The text of what stopped the CLI or a Fake of it, for `detail`.
failure_text(e::AWSCLIError) = e.detail
failure_text(e::Exception) = sprint(showerror, e)

# The default exporter of `sso_credentials`. Its stderr is kept, so that a refusal
# carries the CLI's own text.
function run_export_credentials(profile::AbstractString)
    Sys.which("aws") === nothing && throw(AWSCLIError(AWS_CLI_MISSING))
    output, errors = IOBuffer(), IOBuffer()
    command = `aws configure export-credentials --profile $profile --format env-no-export`
    run_succeeded = success(pipeline(command; stdout = output, stderr = errors))
    run_succeeded || throw(AWSCLIError(strip(String(take!(errors)))))
    return String(take!(output))
end

# The default runner of `sso_login`. The CLI has this process's terminal, since the login
# prints a URL and a code and waits.
function run_sso_login(command::Cmd)
    Sys.which("aws") === nothing && throw(AWSCLIError(AWS_CLI_MISSING))
    run(command)
    return nothing
end

# The default reader of a profile's setting, for an error only. A failed read returns
# what it printed, so that it never hides the failure it explains.
function run_configure_get(profile::AbstractString, key::AbstractString)
    Sys.which("aws") === nothing && return "<$key: $AWS_CLI_MISSING>"
    output, errors = IOBuffer(), IOBuffer()
    command = `aws configure get $key --profile $profile`
    success(pipeline(command; stdout = output, stderr = errors)) ||
        return "<$key: $(strip(String(take!(errors))))>"
    return String(strip(String(take!(output))))
end
