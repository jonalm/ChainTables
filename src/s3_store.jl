const REGION_VARIABLES = ("AWS_REGION", "AWS_DEFAULT_REGION")

const NO_REGION =
    "Chain: region is required by the S3 client, since SigV4 signs it, and neither the " *
    "region keyword nor AWS_REGION nor AWS_DEFAULT_REGION is set. Pass " *
    "region = \"eu-north-1\" (the bucket's region)."

const LISTING_PROBLEM =
    "GET /?list-type=2: a <Contents> entry lacks Key, Size or LastModified"

const NO_CONTINUATION_TOKEN =
    "GET /?list-type=2: IsTruncated without a NextContinuationToken"

"""
    S3ObjectStore(bucket; region, credentials, endpoint = nothing, path_style = false,
                  timeout = 60)

The S3 client: the four verbs of the object store over a SigV4 signer and
stdlib `Downloads`, one request per call and no retry inside. `Chain` builds one when
`store = nothing`, with `region` and `credentials` already resolved.

`endpoint = nothing` is AWS: `https://<bucket>.s3.<region>.amazonaws.com`, or
`https://s3.<region>.amazonaws.com/<bucket>` with `path_style = true`. Any other
`scheme://host[:port]` is supported only when the host ends in `.amazonaws.com` or
`.amazonaws.com.cn`: elsewhere a commit refuses unless the chain's
`assume_first_writer_wins` is set. A bucket name containing a dot is refused: it breaks
certificate matching under the virtual-hosted URL.

- `credentials`: a `Credentials`, or a callable returning one before every request.
- `timeout`: seconds for one request to complete. An attachment's streamed transfer
  has no total timeout; `timeout` is instead how long it may move no byte.

Examples: test/test_s3_store_examples.jl
"""
struct S3ObjectStore <: AbstractObjectStore
    bucket::String
    region::String
    # A Credentials or any callable returning one. A type parameter would make
    # `Chain{S3ObjectStore}` and `Chain{GatewayObjectStore}`, which callers test, abstract.
    # style: field the credentials supplier is any callable
    credentials::Any
    endpoint::Union{Nothing, String}
    endpoint_host::Union{Nothing, String} # without port; `nothing` for AWS's own URL
    path_style::Bool
    host::String # the Host header, as libcurl derives it from `base`
    base::String # scheme://host; `object_path` adds the bucket under path-style
    timeout::Float64
end

function S3ObjectStore(
        bucket::AbstractString; region::AbstractString, credentials, endpoint = nothing,
        path_style::Bool = false, timeout::Real = 60
    )
    isempty(bucket) && throw(ArgumentError("S3ObjectStore: the bucket name is empty"))
    '.' in bucket && throw(ArgumentError(dotted_bucket_message(bucket)))
    timeout > 0 ||
        throw(ArgumentError("S3ObjectStore: timeout is $timeout; it must be positive"))
    scheme, hostport = scheme_and_host(endpoint, region)
    endpoint_host = endpoint === nothing ? nothing : first(split(hostport, ':'))
    host = path_style ? hostport : bucket * "." * hostport
    return S3ObjectStore(
        bucket, region, credentials, endpoint, endpoint_host, path_style, host,
        scheme * "://" * host, timeout
    )
end

scheme_and_host(::Nothing, region) = ("https", "s3.$region.amazonaws.com")
scheme_and_host(endpoint, region) = parse_endpoint(endpoint)

function dotted_bucket_message(bucket)
    return "S3ObjectStore: bucket name $(repr(bucket)) contains a dot, which breaks " *
        "certificate matching under the virtual-hosted URL ChainTables builds " *
        "(ADR-0010); " *
        "use a bucket without one"
end

# The default would print the credentials supplier, whose own `show` may leak a secret.
function Base.show(io::IO, s::S3ObjectStore)
    print(io, "S3ObjectStore(")
    show(io, s.bucket)
    print(io, "; region = ")
    show(io, s.region)
    s.endpoint === nothing || print_keyword(io, "endpoint", s.endpoint)
    s.path_style && print(io, ", path_style = true")
    print(io, ")")
    return nothing
end

function print_keyword(io::IO, name, value)
    print(io, ", ", name, " = ")
    show(io, value)
    return nothing
end

"""
    resolve_region(region)

Return the region the S3 client signs for: `region` when given, else
`AWS_REGION`, else `AWS_DEFAULT_REGION`. Never guessed, because a wrong region is a
signature error instead of a useful message.
"""
function resolve_region(region)
    region === nothing || return String(region)
    found = findfirst(name -> !isempty(get(ENV, name, "")), REGION_VARIABLES)
    found === nothing && throw(ArgumentError(NO_REGION))
    return ENV[REGION_VARIABLES[found]]
end

"""
    parse_endpoint(endpoint; what = "endpoint")

Return `(scheme, hostport)` of `endpoint`, lowercased, without a default port: libcurl
omits it from the Host header the signature covers. A path, query or fragment is refused
rather than dropped; `what` names the keyword in the message.
"""
function parse_endpoint(endpoint::AbstractString; what = "endpoint")
    m = match(r"\A(https?)://([^/?#\s]+)/?\z"i, endpoint)
    m === nothing && throw(ArgumentError(endpoint_message(what, endpoint)))
    scheme = lowercase(m.captures[1])
    default_port = scheme == "https" ? ":443" : ":80"
    return scheme, String(chopsuffix(lowercase(m.captures[2]), default_port))
end

function endpoint_message(what, endpoint)
    return "Chain: $what $(repr(endpoint)) is not of the form scheme://host[:port] " *
        "(http or https, no path); the bucket and key are added by ChainTables"
end

"""
    is_aws(store)

Return whether `store` is AWS S3: no endpoint configured, or one whose host
ends in `.amazonaws.com` or `.amazonaws.com.cn`, which admits the FIPS, dual-stack,
GovCloud and China endpoints. A suffix test on a host, not a security control.
"""
function is_aws end

function is_aws(store::S3ObjectStore)
    host = store.endpoint_host
    return host === nothing || endswith(host, ".amazonaws.com") ||
        endswith(host, ".amazonaws.com.cn")
end

# AWS's own URL is one namespace per partition, where bucket names are unique; a
# configured endpoint is hashed in `parse_endpoint`'s canonical form, so
# `HTTPS://Host:443/` and `https://host` share one (ADR-0040).
function cache_namespace(store::S3ObjectStore)
    store.endpoint === nothing && return aws_partition(store.region)
    scheme, hostport = parse_endpoint(store.endpoint)
    return "ep-" * bytes2hex(sha256(scheme * "://" * hostport))[1:8]
end

function aws_partition(region)
    startswith(region, "cn-") && return "aws-cn"
    startswith(region, "us-gov-") && return "aws-us-gov"
    return "aws"
end

# The S3 client a store reads through: itself, or a gateway store's S3 half.
s3_half(store::S3ObjectStore) = store

"""
    unsupported_store(chain)

Return whether `chain` reaches a host that is not AWS through ChainTables' own S3
client. A gateway store is judged by its S3 half, where reads and the
read-back go; a supplied store is never judged.
"""
function unsupported_store(chain::Chain)
    store = chain.store
    return store isa Union{S3ObjectStore, GatewayObjectStore} && !is_aws(store)
end

# Kept for `open`'s call in localcopy.jl. It warned once per process that commits would
# refuse; a package never warns, so the refusal at commit is the one signal.
warn_unsupported_store(chain) = nothing

"""
    refuse_unsupported_store(chain, call)

Throw `UnsupportedStoreError` when `chain`'s store is unsupported and the chain does
not set `assume_first_writer_wins`. `commit!` and `create_chain` run it before anything
is applied or written; it is never suppressed.
"""
function refuse_unsupported_store(chain::Chain, call)
    unsupported_store(chain) || return nothing
    chain.assume_first_writer_wins && return nothing
    throw(UnsupportedStoreError(; endpoint = s3_half(chain.store).endpoint, call))
end

function object_path(store::S3ObjectStore, key::AbstractString)
    bucket = store.path_style ? "/" * store.bucket : ""
    return bucket * "/" * uri_encode(key; keep_slash = true)
end

"""
    request_headers(store, method, key; query, body, headers, at, payload_hash,
                    content_length)

Return `(; url, headers)` of one signed S3 request: `signed_headers` for service `s3` at
the object's path. Split from `s3_request` so a streamed request can be
signed without its body.
"""
function request_headers(
        store::S3ObjectStore, method::AbstractString, key::AbstractString;
        query = Pair{String, String}[], body = UInt8[], headers = Pair{String, String}[],
        at::Integer = floor(Int64, time()),
        payload_hash::AbstractString = bytes2hex(sha256(body)),
        content_length::Integer = length(body)
    )
    path = object_path(store, key)
    sent = signed_headers(
        current_credentials(store), store.region, "s3", store.host, method, path;
        query, body, headers, at, payload_hash, content_length
    )
    return (; url = store.base * path * query_string(query), headers = sent)
end

"""
    s3_request(store, method, key; query, body, headers)

Return `(; status, headers, body)` of one signed request for `key` in `store`'s bucket.
"""
function s3_request(
        store::S3ObjectStore, method::AbstractString, key::AbstractString;
        query = Pair{String, String}[], body = UInt8[], headers = Pair{String, String}[]
    )
    request = request_headers(store, method, key; query, body, headers)
    return http_request(request.url, method, request.headers, body, store.timeout)
end

object_url(store::S3ObjectStore, key::AbstractString) = store.base * object_path(store, key)

function fetch_object(store::S3ObjectStore, key::AbstractString)
    response = s3_request(store, "GET", key)
    response.status == 200 && return response.body
    response.status == 404 && return nothing
    return failure("GET", object_url(store, key), response)
end

function put_object_if_absent(store::S3ObjectStore, key::AbstractString, bytes)
    body = convert(Vector{UInt8}, bytes)
    # The bare asterisk (ADR-0016 rule 3).
    response = s3_request(store, "PUT", key; body, headers = ["if-none-match" => "*"])
    response.status == 200 && return PutOutcome(true, 200)
    response.status == 412 && return PutOutcome(false, 412)
    # A 409 among them, which the commit layer retries.
    return failure("PUT", object_url(store, key), response)
end

function stat_object(store::S3ObjectStore, key::AbstractString)
    response = s3_request(store, "HEAD", key)
    response.status == 404 && return nothing
    response.status == 200 || failure("HEAD", object_url(store, key), response)
    size = header(response, "content-length")
    modified = header(response, "last-modified")
    (size === nothing || modified === nothing) &&
        throw(TransportError(header_missing_detail(store, key); status = 200))
    return ObjectMeta(String(key), parse(Int64, strip(size)), parse_http_date(modified))
end

function header_missing_detail(store, key)
    return "HEAD $(object_url(store, key)): the response lacks Content-Length or " *
        "Last-Modified"
end

# A listing's pages are each one request, and none is retried.
function list_objects(
        store::S3ObjectStore, prefix::AbstractString;
        start_after::Union{Nothing, AbstractString} = nothing
    )
    page = list_page(store, prefix, start_after, nothing)
    listed = page.entries
    while page.token !== nothing
        page = list_page(store, prefix, start_after, page.token)
        append!(listed, page.entries)
    end
    return listed
end

# One ListObjectsV2 page: `(; entries, token)`, `token` the next page's or `nothing`.
function list_page(store::S3ObjectStore, prefix, start_after, token)
    query = vcat(
        ["list-type" => "2", "prefix" => String(prefix)],
        optional_parameter("start-after", start_after),
        optional_parameter("continuation-token", token)
    )
    response = s3_request(store, "GET", ""; query)
    response.status == 200 || failure("GET", object_url(store, ""), response)
    body = String(copy(response.body))
    entries = map(listing_entry, eachmatch(r"<Contents>(.*?)</Contents>"s, body))
    return (; entries, token = continuation_token(body))
end

optional_parameter(name, ::Nothing) = Pair{String, String}[]
optional_parameter(name, value) = [name => String(value)]

function listing_entry(contents::RegexMatch)
    entry = contents.captures[1]
    key = match(r"<Key>([^<]*)</Key>", entry)
    size = match(r"<Size>([^<]*)</Size>", entry)
    modified = match(r"<LastModified>([^<]*)</LastModified>", entry)
    (key === nothing || size === nothing || modified === nothing) &&
        throw(TransportError(LISTING_PROBLEM; status = 200))
    return ObjectMeta(
        xml_unescape(key.captures[1]), parse(Int64, size.captures[1]),
        parse_iso_date(modified.captures[1])
    )
end

function continuation_token(body::AbstractString)
    truncated = match(r"<IsTruncated>([^<]*)</IsTruncated>", body)
    (truncated !== nothing && strip(truncated.captures[1]) == "true") || return nothing
    next = match(r"<NextContinuationToken>([^<]*)</NextContinuationToken>", body)
    next === nothing && throw(TransportError(NO_CONTINUATION_TOKEN; status = 200))
    return xml_unescape(next.captures[1])
end

"""
    fetch_object_to(store, key, path)

Stream the object at `key` into the file `path`, created or truncated, and
return its size in bytes, or `nothing` when the key is absent. On anything but a `200`
no file is left at `path`, and a failure throws as `fetch_object` does. Checks nothing
about the bytes; the caller hashes them.
"""
function fetch_object_to(store::S3ObjectStore, key::AbstractString, path::AbstractString)
    request = request_headers(store, "GET", key)
    response = with_partial_file_removed(path) do
        Base.open(path, "w") do io
            stall = store.timeout
            http_stream(request.url, "GET", request.headers; output = io, stall)
        end
    end
    response.status == 200 && return Int64(filesize(path))
    body = read_error_document!(path)
    response.status == 404 && return nothing
    return failure("GET", object_url(store, key), (; response.status, body))
end
