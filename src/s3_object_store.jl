const ENDPOINT_FORM = r"\A(https?)://([^/?#\s]+)/?\z"i

const UNREADABLE_HEAD = "the response has no Content-Length or Last-Modified that " *
    "this client reads"

# style: field a value or any callable that returns one, read once per request
"""
    S3ObjectStore(bucket; region, credentials, endpoint = nothing, path_style = false,
                  timeout = 60)

The object store of a bucket on S3: one signed request per call, never retried here.
`Chain` builds one when `store = nothing`, with the region and credentials resolved.

- `endpoint`: `nothing` is AWS's own URL. Else `scheme://host[:port]`.
- `path_style`: put the bucket in the path, not in the host.
- `timeout`: seconds for one request. For a streamed transfer, the seconds in which no
  byte may move.
"""
struct S3ObjectStore <: AbstractObjectStore
    bucket::String
    region::String
    credentials::Any
    endpoint::Union{Nothing, String}
    endpoint_host::Union{Nothing, String}  # the endpoint's host, without its port
    path_style::Bool
    host::String  # the Host header, as libcurl derives it from `base`
    base::String  # scheme://host; `object_path` adds the bucket under path-style
    timeout::Float64
end

# `timeout`: only a test sets another, to meet a timeout in seconds.
function S3ObjectStore(
        bucket::AbstractString; region::AbstractString, credentials, endpoint = nothing,
        path_style::Bool = false, timeout::Real = 60,
    )
    isempty(bucket) && throw(ArgumentError("S3ObjectStore: the bucket name is empty"))
    # A dot breaks certificate matching under the virtual-hosted URL (ADR-0010).
    '.' in bucket && throw(
        ArgumentError(
            "S3ObjectStore: bucket name $(repr(bucket)) contains a dot, which breaks " *
                "certificate matching under the virtual-hosted URL; use a bucket " *
                "without one"
        )
    )
    timeout > 0 ||
        throw(ArgumentError("S3ObjectStore: timeout is $timeout; it must be positive"))
    scheme, hostport = endpoint_parts(endpoint, region)
    host = path_style ? hostport : bucket * "." * hostport
    endpoint_host = endpoint === nothing ? nothing : first(split(hostport, ':'))
    return S3ObjectStore(
        bucket, region, credentials, endpoint, endpoint_host, path_style, host,
        scheme * "://" * host, timeout,
    )
end

endpoint_parts(::Nothing, region) = ("https", "s3.$region.amazonaws.com")
endpoint_parts(endpoint::AbstractString, region) = parse_endpoint(endpoint)

function Base.show(io::IO, store::S3ObjectStore)
    print(io, "S3ObjectStore(")
    show(io, store.bucket)
    show_keyword(io, "; ", "region", store.region)
    store.endpoint === nothing || show_keyword(io, ", ", "endpoint", store.endpoint)
    store.path_style && show_keyword(io, ", ", "path_style", true)
    print(io, ")")
    return nothing
end

function show_keyword(io::IO, separator::String, name::String, value)
    print(io, separator, name, " = ")
    show(io, value)
    return nothing
end

# `scheme://host[:port]`, nothing more: a path, a query or a fragment is refused, not
# dropped. A default port is dropped, since libcurl leaves it out of the Host header
# that the signature covers.
function parse_endpoint(endpoint::AbstractString; what = "endpoint")
    m = match(ENDPOINT_FORM, endpoint)
    m === nothing && throw(
        ArgumentError(
            "Chain: $what $(repr(endpoint)) is not of the form scheme://host[:port] " *
                "(http or https, no path); ChainTables adds the bucket and the key"
        )
    )
    scheme = lowercase(m[1])
    default_port = scheme == "https" ? ":443" : ":80"
    return scheme, String(chopsuffix(lowercase(m[2]), default_port))
end

# What counts as AWS (ADR-0016): AWS's own URL, or an endpoint host under
# `.amazonaws.com` or `.amazonaws.com.cn`, which admits the FIPS, dual-stack, GovCloud
# and China endpoints. A suffix test of a host, not a security control.
function is_aws(store::S3ObjectStore)
    host = store.endpoint_host
    host === nothing && return true
    return endswith(host, ".amazonaws.com") || endswith(host, ".amazonaws.com.cn")
end

# The record cache's namespace (ADR-0040). Bucket names are unique within one partition
# of AWS. An endpoint is hashed in the form `parse_endpoint` gives it, so that
# `HTTPS://Host:443/` and `https://host` share one.
function cache_namespace(store::S3ObjectStore)
    store.endpoint === nothing && return aws_namespace(store.region)
    scheme, hostport = parse_endpoint(store.endpoint)
    return "ep-" * first(bytes2hex(sha256(scheme * "://" * hostport)), 8)
end

function aws_namespace(region::AbstractString)
    startswith(region, "cn-") && return "aws-cn"
    startswith(region, "us-gov-") && return "aws-us-gov"
    return "aws"
end

# The S3 store that a store reads through: itself, or a gateway store's S3 half.
s3_half(store::S3ObjectStore) = store

# What `Chain` does with `region` for the S3 store (ADR-0019). Never guessed: a wrong
# region is a signature error, not a useful message.
function resolve_region(region)
    region === nothing || return String(region)
    value = something(env_value("AWS_REGION"), env_value("AWS_DEFAULT_REGION"), "")
    isempty(value) && throw(
        ArgumentError(
            "Chain: the S3 store needs a region, since the signature covers it, and " *
                "neither the region keyword nor AWS_REGION nor AWS_DEFAULT_REGION is " *
                "set. Pass the bucket's region, such as region = \"eu-north-1\""
        )
    )
    return value
end

function env_value(name::AbstractString)
    value = get(ENV, name, "")
    return isempty(value) ? nothing : value
end

function object_path(store::S3ObjectStore, key::AbstractString)
    bucket_path = store.path_style ? "/" * store.bucket : ""
    return bucket_path * "/" * SigV4.uri_encode(key; keep_slash = true)
end

object_url(store::S3ObjectStore, key::AbstractString) = store.base * object_path(store, key)

# The URL and the headers of one signed S3 request, apart from the request, so that a
# streamed one (ADR-0046) is signed without its body.
function request_headers(
        store::S3ObjectStore, method::AbstractString, key::AbstractString;
        query = Pair{String, String}[], body = UInt8[], headers = Pair{String, String}[],
        at = floor(Int64, time()), payload_hash = bytes2hex(sha256(body)),
        content_length = length(body),
    )
    path = object_path(store, key)
    signed = signed_headers(
        current_credentials(store); store.region, service = "s3", store.host, method,
        path, query, headers, at, payload_hash, content_length,
    )
    return (; url = store.base * path * query_string(query), headers = signed)
end

function s3_request(
        store::S3ObjectStore, method::AbstractString, key::AbstractString;
        query = Pair{String, String}[], body = UInt8[], headers = Pair{String, String}[],
    )
    request = request_headers(store, method, key; query, body, headers)
    return http_request(method, request.url; request.headers, body, store.timeout)
end

function fetch_object(store::S3ObjectStore, key::AbstractString)
    response = s3_request(store, "GET", key)
    response.status == 200 && return response.body
    response.status == 404 && return nothing
    throw(TransportError("GET", object_url(store, key), response))
end

# The bare asterisk of `If-None-Match` (ADR-0016). A `409` is a `TransportError`, which
# the commit layer retries.
function put_object_if_absent(store::S3ObjectStore, key::AbstractString, bytes)
    body = convert(Vector{UInt8}, bytes)
    response = s3_request(store, "PUT", key; body, headers = ["if-none-match" => "*"])
    response.status == 200 && return PutOutcome(true, 200)
    response.status == 412 && return PutOutcome(false, 412)
    throw(TransportError("PUT", object_url(store, key), response))
end

function stat_object(store::S3ObjectStore, key::AbstractString)
    response = s3_request(store, "HEAD", key)
    response.status == 404 && return nothing
    url = object_url(store, key)
    response.status == 200 || throw(TransportError("HEAD", url, response))
    size = parse_present(try_parse_size, response_header(response, "content-length"))
    modified_text = response_header(response, "last-modified")
    modified = parse_present(try_parse_http_date, modified_text)
    (size === nothing || modified === nothing) && throw(
        TransportError(; method = "HEAD", url, response.status, detail = UNREADABLE_HEAD)
    )
    return ObjectMeta(String(key), size, modified)
end

# Each page of a listing is one request, and none is retried.
function list_objects(
        store::S3ObjectStore, prefix::AbstractString;
        start_after::Union{Nothing, AbstractString} = nothing,
    )
    page = fetch_listing_page(store, prefix, start_after, nothing)
    listed = page.objects
    while page.next_token !== nothing
        page = fetch_listing_page(store, prefix, start_after, page.next_token)
        append!(listed, page.objects)
    end
    return listed
end

function fetch_listing_page(store::S3ObjectStore, prefix, start_after, token)
    query = listing_query(prefix, start_after, token)
    response = s3_request(store, "GET", ""; query)
    url = object_url(store, "") * query_string(query)
    response.status == 200 || throw(TransportError("GET", url, response))
    return listing_page(String(copy(response.body)), url)
end

function listing_query(prefix, start_after, token)
    optional = ("start-after" => start_after, "continuation-token" => token)
    given = Pair{String, String}[
        name => value for (name, value) in optional if value !== nothing
    ]
    return [["list-type" => "2", "prefix" => String(prefix)]; given]
end

function listing_page(xml::String, url::String)
    entries = eachmatch(r"<Contents>(.*?)</Contents>"s, xml)
    objects = [listed_object(m[1], url) for m in entries]
    element_text(xml, "IsTruncated") == "true" || return (; objects, next_token = nothing)
    next_token = parse_present(xml_unescape, element_text(xml, "NextContinuationToken"))
    next_token === nothing && throw(
        TransportError(;
            method = "GET", url, status = 200,
            detail = "the listing is truncated, and has no NextContinuationToken",
        )
    )
    return (; objects, next_token)
end

function listed_object(entry::AbstractString, url::String)
    key = parse_present(xml_unescape, element_text(entry, "Key"))
    size = parse_present(try_parse_size, element_text(entry, "Size"))
    modified = parse_present(try_parse_iso_date, element_text(entry, "LastModified"))
    (key === nothing || size === nothing || modified === nothing) && throw(
        TransportError(;
            method = "GET", url, status = 200,
            detail = "a <Contents> entry has no Key, Size or LastModified that this " *
                "client reads",
        )
    )
    return ObjectMeta(key, size, modified)
end

function element_text(xml::AbstractString, tag::String)
    m = match(Regex("<$tag>([^<]*)</$tag>"), xml)
    return m === nothing ? nothing : strip(m[1])
end

try_parse_size(text::AbstractString) = tryparse(Int64, strip(text))

# `nothing` when the text is absent, else what `parse` reads, `nothing` included.
parse_present(parse, ::Nothing) = nothing
parse_present(parse, text::AbstractString) = parse(text)

"""
    fetch_object_to(store, key, path)

Stream the object at `key` into the file `path`, created or truncated, and return its
size in bytes, or `nothing` when the key is absent. On any status but `200` no file is
left at `path`. It does not check the bytes: the caller hashes them.
"""
function fetch_object_to(store::S3ObjectStore, key::AbstractString, path::AbstractString)
    request = request_headers(store, "GET", key)
    response = stream_to_file(request, path, store.timeout)
    response.status == 200 && return Int64(filesize(path))
    body = Base.open(io -> read(io, ERROR_DOCUMENT_BYTES), path)
    rm(path)
    response.status == 404 && return nothing
    throw(TransportError("GET", object_url(store, key), (; response.status, body)))
end

# A failed transfer leaves no file.
function stream_to_file(request, path::AbstractString, stall::Real)
    _is_streamed = false
    try
        response = Base.open(path, "w") do io
            http_stream("GET", request.url; request.headers, output = io, stall)
        end
        _is_streamed = true
        return response
    finally
        _is_streamed || rm(path; force = true)
    end
end
