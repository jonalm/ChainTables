const ENV_CREDENTIALS_HINT =
    "Export them (aws-vault exec <profile> -- julia …), or pass credentials = " *
    "ChainTables.Credentials(id, secret) or a callable returning one"

"""
    Credentials(access_key_id, secret_access_key; session_token = nothing)

The AWS keys a request is signed with.

`session_token` is sent as `x-amz-security-token` when present, so an aws-vault session,
SSO and MFA all work. Shown with the secret and the token redacted.

Examples: test/test_credentials_examples.jl
"""
struct Credentials
    access_key_id::String
    secret_access_key::String
    session_token::Union{Nothing, String}
end

function Credentials(access_key_id, secret_access_key; session_token = nothing)
    return Credentials(access_key_id, secret_access_key, session_token)
end

function Base.show(io::IO, c::Credentials)
    print(io, "Credentials(")
    show(io, c.access_key_id)
    print(io, ", \"***\"")
    c.session_token isa String && print(io, "; session_token = \"***\"")
    print(io, ")")
    return nothing
end

"""
    credentials_from_env()

Return the credentials in `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` and, when set,
`AWS_SESSION_TOKEN`: what `aws-vault exec` exports.
"""
function credentials_from_env()
    id = get(ENV, "AWS_ACCESS_KEY_ID", "")
    secret = get(ENV, "AWS_SECRET_ACCESS_KEY", "")
    variables = (("AWS_ACCESS_KEY_ID", id), ("AWS_SECRET_ACCESS_KEY", secret))
    unset = [name for (name, value) in variables if isempty(value)]
    isempty(unset) || throw(ArgumentError(unset_keys_message(unset)))
    token = get(ENV, "AWS_SESSION_TOKEN", "")
    return Credentials(id, secret; session_token = isempty(token) ? nothing : token)
end

function unset_keys_message(unset)
    return "Chain: credentials = nothing reads AWS_ACCESS_KEY_ID and " *
        "AWS_SECRET_ACCESS_KEY from the environment, and $(join(unset, " and ")) is not " *
        "set. " * ENV_CREDENTIALS_HINT
end

"""
    resolve_credentials(credentials)

Return what a store signs with, from `Chain`'s `credentials` keyword:
`nothing` reads the environment now; a `Credentials`, or a value with `access_key_id`
and `secret_access_key` properties, is taken as a `Credentials`; a callable is returned
as is, after one call now so that a callable that cannot produce credentials fails at
construction. A callable is called again before every request.
"""
function resolve_credentials(credentials)
    credentials === nothing && return credentials_from_env()
    hasproperty(credentials, :access_key_id) && return to_credentials(credentials)
    isempty(methods(credentials)) &&
        throw(ArgumentError(not_credentials_message(credentials)))
    to_credentials(credentials())
    return credentials
end

function not_credentials_message(x)
    return "Chain: credentials is a $(typeof(x)), which is neither a " *
        "ChainTables.Credentials, a value with access_key_id and secret_access_key " *
        "properties, nor a callable returning one"
end

"""
    to_credentials(x)

Return `x` as a `Credentials`: `x` itself, or the `access_key_id`, `secret_access_key`
and optional `session_token` properties of `x`, such as a NamedTuple's.
"""
to_credentials(c::Credentials) = c

function to_credentials(x)
    is_key_holder(x) || throw(ArgumentError(not_key_holder_message(x)))
    token = hasproperty(x, :session_token) ? x.session_token : nothing
    return Credentials(x.access_key_id, x.secret_access_key; session_token = token)
end

is_key_holder(x) = hasproperty(x, :access_key_id) && hasproperty(x, :secret_access_key)

function not_key_holder_message(x)
    return "Chain: credentials must be a ChainTables.Credentials, or a value with " *
        "access_key_id and secret_access_key properties; got a $(typeof(x))"
end

"""
    current_credentials(store)

Return the credentials `store` signs its next request with: its `Credentials`, or a
fresh call of its credentials callable.
"""
current_credentials(store) = credentials_now(store.credentials)::Credentials

credentials_now(c::Credentials) = c
credentials_now(supplier) = to_credentials(supplier())
