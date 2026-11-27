# `runner` runs the command: a test passes a Fake.
"""
    sso_login(profile; device_code = false)
    sso_login(bucket::Bucket; device_code = false)

Log in to the AWS CLI profile `profile`, or the bucket's: run
`aws sso login --profile <profile>` in this process's terminal, and return once it
succeeds. It opens a browser and waits, so it is always asked for: no call of
ChainTables runs it by itself.

- `device_code`: add `--use-device-code`, for a browser that cannot reach the authorize
  page.

Throws `LoginError` when the login fails.

Examples: test/test_sso_login_examples.jl
"""
function sso_login(profile::AbstractString; device_code = false, runner = run_sso_login)
    isempty(profile) && throw(ArgumentError("sso_login: profile must not be empty"))
    command = login_command(profile, device_code)
    # style: catch-all the runner may be the caller's; whatever stops it, the login failed
    try
        runner(command)
    catch e
        e isa Exception || rethrow()
        text = join(command.exec, ' ')
        throw(LoginError(; profile, command = text, detail = failure_text(e)))
    end
    return nothing
end

function login_command(profile::AbstractString, device_code::Bool)
    command = `aws sso login --profile $profile`
    return device_code ? `$command --use-device-code` : command
end
