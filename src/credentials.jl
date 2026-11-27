const CREDENTIAL_VARIABLES = ("AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY")

"""
    Credentials(access_key_id, secret_access_key; session_token = nothing)

The AWS credentials that a request is signed with. A session from `aws-vault`, SSO or
MFA has a `session_token`, which goes with every request. `show` hides the secret and
the token.

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

function Base.show(io::IO, credentials::Credentials)
    print(io, "Credentials(")
    show(io, credentials.access_key_id)
    print(io, ", \"***\"")
    credentials.session_token isa String && print(io, "; session_token = \"***\"")
    print(io, ")")
    return nothing
end

# What `Chain` does with `credentials` for the S3 store (ADR-0019). A callable is called
# once now, so that one that gives no credentials fails here, and again before each
# request, so that a long reader outlives a session (ADR-0010).
resolve_credentials(::Nothing) = credentials_from_env()
resolve_credentials(credentials::Credentials) = credentials

function resolve_credentials(source)
    hasproperty(source, :access_key_id) && return as_credentials(source)
    isempty(methods(source)) && throw(
        ArgumentError(
            "Chain: credentials is a $(typeof(source)), which is not a " *
                "ChainTables.Credentials, a value with the fields access_key_id and " *
                "secret_access_key, or a callable that returns one"
        )
    )
    as_credentials(source())
    return source
end

# The environment that `aws-vault exec` sets.
function credentials_from_env()
    unset = filter(name -> isempty(get(ENV, name, "")), CREDENTIAL_VARIABLES)
    isempty(unset) || throw(
        ArgumentError(
            "Chain: credentials = nothing reads the credentials from the environment, " *
                "and $(join(unset, " and ")) is not set. Run under " *
                "`aws-vault exec <profile> --`, or pass credentials"
        )
    )
    token = get(ENV, "AWS_SESSION_TOKEN", "")
    session_token = isempty(token) ? nothing : token
    return Credentials(map(name -> ENV[name], CREDENTIAL_VARIABLES)...; session_token)
end

# A value with the fields `access_key_id` and `secret_access_key`, and maybe
# `session_token`, such as a NamedTuple, is taken as credentials.
as_credentials(credentials::Credentials) = credentials

function as_credentials(source)
    names = propertynames(source)
    (:access_key_id in names && :secret_access_key in names) || throw(
        ArgumentError(
            "Chain: credentials must be a ChainTables.Credentials, or a value with the " *
                "fields access_key_id and secret_access_key; got a $(typeof(source))"
        )
    )
    session_token = :session_token in names ? source.session_token : nothing
    return Credentials(source.access_key_id, source.secret_access_key; session_token)
end

# The credentials that the next request of `store` is signed with.
current_credentials(store) = credentials_now(store.credentials)

credentials_now(credentials::Credentials) = credentials
credentials_now(source) = as_credentials(source())
