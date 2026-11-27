"""
    Bucket(name; region = nothing, gateway = nothing, profile = nothing)

A bucket and how this client reaches it, as one value: its name, region, gateway and
profile must agree, so they are not loose keywords at every `Chain` call.

It is plain data: constructing one performs no I/O and resolves nothing, and nothing in
it is secret. The name is held to `Chain`'s rules. Throws `ArgumentError` when the
gateway's host names another region than `region`.

- `region`: `nothing` leaves it to `Chain`, which reads the environment.
- `gateway`: the function URL of a gateway bucket's gateway, `scheme://host[:port]`;
  `nothing` for a plain bucket.
- `profile`: the AWS CLI profile that reaches the bucket, a name and never credentials;
  `nothing` for the `AWS_*` environment.

Examples: test/test_bucket_examples.jl
"""
struct Bucket
    name::String
    region::Union{Nothing, String}
    gateway::Union{Nothing, String}
    profile::Union{Nothing, String}
    function Bucket(name, region, gateway, profile)
        check_bucket_name(name)
        profile == "" && throw(
            ArgumentError(
                "Bucket: profile is empty; leave it out for the AWS_* environment"
            )
        )
        base = gateway === nothing ? nothing : first(gateway_base(gateway, region))
        return new(name, region, base, profile)
    end
end

function Bucket(name; region = nothing, gateway = nothing, profile = nothing)
    return Bucket(name, region, gateway, profile)
end

function Base.show(io::IO, bucket::Bucket)
    print(io, "Bucket(")
    show(io, bucket.name)
    show_keyword(io, "; ", "region", bucket.region)
    show_keyword(io, ", ", "gateway", bucket.gateway)
    show_keyword(io, ", ", "profile", bucket.profile)
    print(io, ")")
    return nothing
end

# A bucket has one gateway and a gateway fills one bucket, so neither is given apart from
# the other (ADR-0029). A supplied store gets no gateway, which `Chain` would refuse
# together with it.
function Chain(
        bucket::Bucket, prefix; credentials = nothing, profile = bucket.profile,
        login = false, store = nothing, keywords...,
    )
    check_bucket_keyword(keywords, :region, bucket.region)
    check_bucket_keyword(keywords, :gateway, bucket.gateway)
    source = credentials_or_profile(credentials, profile, login)
    gateway = store === nothing ? bucket.gateway : nothing
    return Chain(
        bucket.name, prefix; bucket.region, gateway, credentials = source, store,
        keywords...,
    )
end

function check_bucket_keyword(keywords, name::Symbol, value)
    haskey(keywords, name) && throw(
        ArgumentError(
            "Chain: $name was given together with a Bucket, which already says it " *
                "($(repr(value))); build another Bucket"
        )
    )
    return nothing
end

# A `credentials` keyword wins over the profile.
function credentials_or_profile(credentials, profile, login)
    credentials === nothing && profile !== nothing &&
        return sso_credentials(profile; login)
    return credentials
end

function sso_login(bucket::Bucket; keywords...)
    bucket.profile === nothing && throw(
        ArgumentError(
            "sso_login: the Bucket has no profile to log in with; pass one to Bucket, " *
                "or call sso_login(profile)"
        )
    )
    return sso_login(bucket.profile; keywords...)
end
