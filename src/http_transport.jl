# What a failed streamed GET wrote to its file is the error document, read back for the
# error. Capped, since a misbehaving peer could send anything.
const ERROR_DOCUMENT_BYTES = 64 * 1024

# Every header sent is signed, as the reference implementations do, except
# `content-length`, which libcurl owns (ADR-0010, ADR-0028). A body streamed from a file
# (ADR-0046) gives `payload_hash` and `content_length` in place of `body`.
function signed_headers(
        credentials::Credentials; region, service, host, method, path,
        query = Pair{String, String}[], body = UInt8[], headers = Pair{String, String}[],
        at = floor(Int64, time()), payload_hash = bytes2hex(sha256(body)),
        content_length = length(body),
    )
    base = ["host" => String(host), "x-amz-content-sha256" => String(payload_hash)]
    given = [lowercase(String(name)) => String(value) for (name, value) in headers]
    date = "x-amz-date" => SigV4.amz_date(at)
    signed = [base; date; session_token_headers(credentials); given]
    signature = SigV4.sign_request(
        credentials; method, path, query, headers = signed, payload_hash, at, region,
        service,
    )
    authorization = "authorization" => signature.authorization
    return [signed; authorization; content_length_headers(method, content_length)]
end

function session_token_headers(credentials::Credentials)
    token = credentials.session_token
    token === nothing && return Pair{String, String}[]
    return ["x-amz-security-token" => token]
end

function content_length_headers(method::AbstractString, content_length::Integer)
    method in ("PUT", "POST") || return Pair{String, String}[]
    return ["content-length" => string(content_length)]
end

query_string(query) = isempty(query) ? "" : "?" * SigV4.canonical_query(query)

# One request with no retry (ADR-0010): the response whatever its status, for the verb to
# read. `body` is sent with a `PUT` or a `POST`.
function http_request(
        method::AbstractString, url::AbstractString; headers, body = UInt8[],
        timeout::Real,
    )
    output = IOBuffer()
    input = method in ("PUT", "POST") ? IOBuffer(body) : nothing
    response = Downloads.request(
        url; method, headers, input, output, timeout, throw = false
    )
    response isa Downloads.RequestError && throw(TransportError(method, url, response))
    return (; status = response.status, headers = response.headers, body = take!(output))
end

# One streamed request with no retry (ADR-0010, ADR-0046): the body is read from `input`
# and the response's body written to `output`. The response is returned whatever its
# status, a `3xx` too, since no redirect is followed. A stall of `stall` seconds, or a
# transfer still running `deadline` seconds after it began (a presigned URL's end), is a
# `TransportError` with no status. A `PUT` needs a `content-length` header: without one
# libcurl sends a chunked body, which S3 refuses.
function http_stream(
        method::AbstractString, url::AbstractString; headers, input = nothing,
        output = nothing, stall::Real, deadline::Union{Nothing, Real} = nothing,
    )
    stall > 0 ||
        throw(ArgumentError("http_stream: stall is $stall seconds; it must be positive"))
    (deadline === nothing || deadline > 0) || throw(
        ArgumentError("http_stream: deadline is $deadline seconds; it must be positive")
    )
    method == "PUT" && !has_content_length(headers) && throw(
        ArgumentError(
            "http_stream: a streamed PUT needs a content-length header; without one " *
                "libcurl sends a chunked body, which S3 refuses"
        )
    )
    response = Downloads.request(
        url; method, headers, input, output = something(output, devnull), throw = false,
        downloader = stream_downloader(stall, deadline),
    )
    response isa Downloads.RequestError &&
        throw(TransportError(method, bare_url(url), response))
    return (; status = response.status, headers = response.headers)
end

function has_content_length(headers)
    return any(pair -> lowercase(first(pair)) == "content-length", headers)
end

# The query of a presigned URL is a credential, so an error leaves it out.
bare_url(url::AbstractString) = String(first(split(url, '?'; limit = 2)))

# One downloader per transfer, since its hook sets libcurl's options and the stall
# differs by store. Connection reuse matters little at these sizes.
function stream_downloader(stall::Real, deadline)
    downloader = Downloads.Downloader(; grace = 0)
    downloader.easy_hook = (easy, info) -> set_stream_options(easy, stall, deadline)
    return downloader
end

# style: non-public Downloads has no public option to refuse a redirect or end a stall
function set_stream_options(easy, stall::Real, deadline)
    seconds = ceil(Int, stall)  # libcurl counts the low-speed window in whole seconds
    Downloads.Curl.setopt(easy, Downloads.Curl.CURLOPT_FOLLOWLOCATION, false)
    Downloads.Curl.setopt(easy, Downloads.Curl.CURLOPT_LOW_SPEED_LIMIT, 1)
    Downloads.Curl.setopt(easy, Downloads.Curl.CURLOPT_LOW_SPEED_TIME, seconds)
    deadline === nothing && return nothing
    milliseconds = max(1, ceil(Int, deadline * 1000))
    Downloads.Curl.setopt(easy, Downloads.Curl.CURLOPT_TIMEOUT_MS, milliseconds)
    return nothing
end

function response_header(response, name::AbstractString)
    i = findfirst(pair -> first(pair) == name, response.headers)
    return i === nothing ? nothing : last(response.headers[i])
end

const XML_ENTITIES = Dict(
    "amp" => "&", "lt" => "<", "gt" => ">", "quot" => "\"", "apos" => "'"
)

const XML_REFERENCE = r"&(?:#x[0-9a-fA-F]+|#[0-9]+|amp|lt|gt|quot|apos);"

# The five entities and the character references of an S3 or STS response.
xml_unescape(text::AbstractString) = replace(text, XML_REFERENCE => reference_text)

function reference_text(reference::AbstractString)
    name = chop(reference; head = 1, tail = 1)
    haskey(XML_ENTITIES, name) && return XML_ENTITIES[name]
    startswith(name, "#x") && return string(Char(parse(Int, name[3:end]; base = 16)))
    return string(Char(parse(Int, name[2:end])))
end
