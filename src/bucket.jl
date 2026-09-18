# ADR-0029 — `Bucket`: the facts of one deployment that must agree, as one value, and the
# `Chain` method that takes it. Plain data: no I/O, no resolved credentials.

"""
    Bucket(name; region = nothing, gateway = nothing, profile = nothing)

A bucket and how this client reaches it (ADR-0029): the values that are facts about one
deployment and must agree, held as one value instead of loose keywords at every
[`Chain`](@ref) call.

- `name`: the bucket. Empty, or containing a dot (ADR-0010), is refused.
- `region`: where the bucket — and its gateway — live. `nothing` leaves it to `Chain`'s
  rule (`AWS_REGION`, else `AWS_DEFAULT_REGION`, never guessed; ADR-0019).
- `gateway`: the function URL of the gateway of a gateway bucket (ADR-0028),
  `https://host[:port]`; `nothing` for a plain bucket. A bucket has one gateway and a
  gateway fills one bucket, which is why they live in one value. A `region` that disagrees
  with the one in a `*.lambda-url.<region>.on.aws` host is refused.
- `profile`: the AWS CLI profile whose permission set reaches this bucket and may invoke
  this gateway — a *name*, local to `~/.aws/config`, never credentials. `nothing` for the
  `AWS_*` environment or a `credentials` keyword.

Constructing one performs no I/O and resolves nothing, so it is printable — nothing in it
is secret — and loadable from a TOML file or Preferences. The type is generic; the values
belong to the deployment and live with the consumer:

```julia
const BUCKET = ChainTables.Bucket("<bucket>"; region = "<region>",
                                  gateway = "https://<id>.lambda-url.<region>.on.aws", profile = "<profile>")
ChainTables.sso_login(BUCKET)                       # aws sso login --profile <profile>
chain = ChainTables.Chain(BUCKET, "<prefix>")
```

    Chain(bucket::Bucket, prefix; credentials = nothing, profile = bucket.profile, login = false, kw...)

The chain under `prefix` in `bucket`: `Chain(bucket.name, prefix; region, gateway, credentials, kw...)`
with the bucket's `region` and `gateway`, and `credentials` defaulting to
[`sso_credentials(profile; login)`](@ref sso_credentials) when there is a profile, else to
`nothing` (the environment). A `credentials` keyword wins over the profile; a `profile`
keyword replaces the bucket's, since profile names are each user's own. Every other `Chain`
keyword passes through, except `region` and `gateway`, which are the bucket's to say and
are refused. With a supplied `store` — `Testing.InMemoryObjectStore` — the bucket's
`gateway` is not forwarded, because `Chain` refuses `gateway` together with `store`.
"""
struct Bucket
    name::String
    region::Union{Nothing,String}
    gateway::Union{Nothing,String}
    profile::Union{Nothing,String}
    function Bucket(name, region, gateway, profile)
        check_bucket_name(name)
        gateway === nothing || (gateway = first(gateway_base(gateway, region)))
        profile === nothing || !isempty(profile) || throw(ArgumentError("Bucket: profile must not be empty; " *
            "leave it out for the AWS_* environment"))
        return new(name, region, gateway, profile)
    end
end
Bucket(name; region = nothing, gateway = nothing, profile = nothing) = Bucket(name, region, gateway, profile)

Base.show(io::IO, b::Bucket) = print(io, "Bucket(", repr(b.name), "; region = ", repr(b.region),
    ", gateway = ", repr(b.gateway), ", profile = ", repr(b.profile), ")")

function Chain(bucket::Bucket, prefix; credentials = nothing, profile = bucket.profile, login = false, store = nothing, kw...)
    for name in (:region, :gateway)
        haskey(kw, name) && throw(ArgumentError("Chain: $name was given together with a Bucket, which already says " *
            "it ($(repr(getfield(bucket, name)))); build another Bucket rather than overriding one (ADR-0029)"))
    end
    credentials === nothing && profile !== nothing && (credentials = sso_credentials(profile; login))
    gateway = store === nothing ? bucket.gateway : nothing
    return Chain(bucket.name, prefix; bucket.region, gateway, credentials, store, kw...)
end

"""
    sso_login(bucket::Bucket; device_code = false)

[`sso_login`](@ref) for the bucket's profile; an `ArgumentError` when it has none.
"""
function sso_login(bucket::Bucket; kw...)
    bucket.profile === nothing && throw(ArgumentError("sso_login: $bucket has no profile to log in with; " *
        "pass one to Bucket, or call sso_login(profile)"))
    return sso_login(bucket.profile; kw...)
end
