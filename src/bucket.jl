const EMPTY_PROFILE =
    "Bucket: profile must not be empty; leave it out for the AWS_* environment"

"""
    Bucket(name; region = nothing, gateway = nothing, profile = nothing)

A bucket and how this client reaches it: the facts of one deployment that
must agree, held as one value instead of loose keywords at every `Chain` call.

Plain data: constructing one performs no I/O and resolves nothing, and nothing in it is
secret. `Chain(bucket, prefix; credentials, profile, login, kw...)` builds the chain
under `prefix`, with the bucket's region and gateway and, when there is a profile and no
`credentials`, `sso_credentials(profile; login)`. A `profile` keyword replaces the
bucket's; `region` and `gateway` are the bucket's to say and are refused. With a supplied
`store` the gateway is not forwarded.

- `name`: refused when empty or containing a dot, as by `Chain`.
- `region`: `nothing` leaves it to `Chain`'s rule (`AWS_REGION`, else
  `AWS_DEFAULT_REGION`).
- `gateway`: a gateway bucket's function URL, `https://host[:port]`; it must agree with
  `region` when its host names one.
- `profile`: the AWS CLI profile that reaches this bucket; a name, never credentials.

Examples: test/test_bucket_examples.jl
"""
struct Bucket
    name::String
    region::Union{Nothing, String}
    gateway::Union{Nothing, String}
    profile::Union{Nothing, String}
    function Bucket(name, region, gateway, profile)
        check_bucket_name(name)
        profile == "" && throw(ArgumentError(EMPTY_PROFILE))
        return new(name, region, gateway_url(gateway, region), profile)
    end
end

function Bucket(name; region = nothing, gateway = nothing, profile = nothing)
    return Bucket(name, region, gateway, profile)
end

gateway_url(::Nothing, region) = nothing
gateway_url(gateway, region) = first(gateway_base(gateway, region))

function Chain(
        bucket::Bucket, prefix; credentials = nothing, profile = bucket.profile,
        login = false, store = nothing, kw...
    )
    haskey(kw, :region) && throw(ArgumentError(overridden_message(:region, bucket.region)))
    haskey(kw, :gateway) &&
        throw(ArgumentError(overridden_message(:gateway, bucket.gateway)))
    resolved = credentials === nothing ? profile_credentials(profile, login) : credentials
    gateway = store === nothing ? bucket.gateway : nothing
    return Chain(
        bucket.name, prefix; bucket.region, gateway, credentials = resolved, store, kw...
    )
end

function overridden_message(name, value)
    return "Chain: $name was given together with a Bucket, which already says it " *
        "($(repr(value))); build another Bucket rather than overriding one (ADR-0029)"
end

profile_credentials(::Nothing, login) = nothing
profile_credentials(profile, login) = sso_credentials(profile; login)

function sso_login(bucket::Bucket; kw...)
    bucket.profile === nothing && throw(ArgumentError(no_profile_message(bucket)))
    return sso_login(bucket.profile; kw...)
end

function no_profile_message(bucket)
    return "sso_login: $bucket has no profile to log in with; pass one to Bucket, or " *
        "call " *
        "sso_login(profile)"
end
