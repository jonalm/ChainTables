# One request over stdlib `Downloads`, no retry inside (ADR-0010): libcurl retries
# nothing on its own, so "the transport never retries" is obtained, not configured.

# What a failed streamed GET wrote to its file is the error document, read back for the
# message; capped, since a misbehaving peer could send anything.
const ERROR_DOCUMENT_BYTES = 64 * 1024

const XML_ENTITY = r"&(#x[0-9a-fA-F]+|#[0-9]+|amp|lt|gt|quot|apos);"

const XML_NAMED_ENTITIES = Dict(
    "&amp;" => "&", "&lt;" => "<", "&gt;" => ">", "&quot;" => "\"", "&apos;" => "'"
)

const CHUNKED_PUT =
    "http_stream: a streamed PUT needs a content-length header; without one libcurl " *
    "sends a chunked body, which S3 refuses"

"""
    StreamOptions

The libcurl options of one streamed transfer: no redirect followed, a stall
of `stall_seconds` with no byte moved aborts it, and so does `deadline_ms` when set.
A `Function`, because `Downloads.Downloader`'s `easy_hook` field holds one.
"""
struct StreamOptions <: Function
    stall_seconds::Int # libcurl counts the low-speed window in whole seconds
    deadline_ms::Union{Nothing, Int}
end

function (o::StreamOptions)(easy, info)
    Downloads.Curl.setopt(easy, Downloads.Curl.CURLOPT_FOLLOWLOCATION, false)
    Downloads.Curl.setopt(easy, Downloads.Curl.CURLOPT_LOW_SPEED_LIMIT, 1)
    Downloads.Curl.setopt(easy, Downloads.Curl.CURLOPT_LOW_SPEED_TIME, o.stall_seconds)
    o.deadline_ms === nothing ||
        Downloads.Curl.setopt(easy, Downloads.Curl.CURLOPT_TIMEOUT_MS, o.deadline_ms)
    return nothing
end

"""
    http_request(url, method, headers, body, timeout)

Return `(; status, headers, body)` of one request, whatever its status. `body` is sent
for a `PUT` or `POST`. Throws `TransportError` with no status when there is no response
at all: a connect failure, a timeout, TLS.
"""
function http_request(
        url::AbstractString, method::AbstractString, headers, body, timeout::Real
    )
    output = IOBuffer()
    input = method in ("PUT", "POST") ? IOBuffer(body) : nothing
    response = Downloads.request(
        url; method, headers, input, output, timeout, throw = false
    )
    response isa Downloads.RequestError &&
        throw(TransportError("$method $url: no response: $(response.message)"))
    return (; status = response.status, headers = response.headers, body = take!(output))
end

"""
    http_stream(url, method, headers; input = nothing, output = nothing, stall,
                deadline = nothing)

Return `(; status, headers)` of one streamed request, whatever its
status, a `3xx` among them: no redirect is followed.

The body is read from `input`, an IO at its start, and the response's body written to
`output`. Throws `TransportError` with no status when there is no response, when no byte
moves for `stall` seconds, or when the transfer still runs `deadline` seconds after it
began: a presigned URL's end. The message leaves out the URL's query, which for a
presigned URL is a credential. A `PUT` must carry `content-length`, else libcurl sends a
chunked body, which S3 refuses.
"""
function http_stream(
        url::AbstractString, method::AbstractString, headers; input = nothing,
        output = nothing, stall::Real, deadline::Union{Nothing, Real} = nothing
    )
    stall > 0 ||
        throw(ArgumentError("http_stream: stall is $stall seconds; it must be positive"))
    deadline === nothing || deadline > 0 ||
        throw(ArgumentError("http_stream: deadline is $deadline seconds; must be positive"))
    method == "PUT" && lacks_content_length(headers) && throw(ArgumentError(CHUNKED_PUT))
    downloader = Downloads.Downloader(; grace = 0)
    downloader.easy_hook = StreamOptions(ceil(Int, stall), deadline_ms(deadline))
    response = Downloads.request(
        url; method, headers, input, output = something(output, devnull), throw = false,
        downloader
    )
    response isa Downloads.RequestError &&
        throw(TransportError(no_response_detail(method, url, response.message)))
    return (; status = response.status, headers = response.headers)
end

function no_response_detail(method, url, why)
    return "$method $(url_without_query(url)): no response: $why"
end

function lacks_content_length(headers)
    return !any(kv -> lowercase(first(kv)) == "content-length", headers)
end

deadline_ms(::Nothing) = nothing
deadline_ms(seconds::Real) = max(1, ceil(Int, seconds * 1000))

url_without_query(url::AbstractString) = first(split(url, '?'; limit = 2))

"""
    with_partial_file_removed(f, path)

Return `f()`; when `f` throws, remove the file at `path` first, so a failed transfer
leaves no partial file behind.
"""
function with_partial_file_removed(f, path::AbstractString)
    finished = false
    return try
        value = f()
        finished = true
        value
    finally
        finished || rm(path; force = true)
    end
end

"""
    read_error_document!(path)

Return the first `ERROR_DOCUMENT_BYTES` of the file at `path`, and remove the file.
"""
function read_error_document!(path::AbstractString)
    body = Base.open(io -> read(io, ERROR_DOCUMENT_BYTES), path)
    rm(path)
    return body
end

"""
    failure(method, url, response)

Throw the `TransportError` of a failed request: its status and, when AWS sent its XML
error document (S3's or STS's), the document's `Code` and `Message`.
"""
function failure(method, url, response)
    throw(TransportError(failure_detail(method, url, response.body); response.status))
end

function failure_detail(method, url, body)
    text = String(copy(body))
    code = match(r"<Code>([^<]*)</Code>", text)
    message = match(r"<Message>([^<]*)</Message>", text)
    code === nothing && return "$method $url"
    message === nothing && return "$method $url: $(xml_unescape(code.captures[1]))"
    said = xml_unescape(message.captures[1])
    return "$method $url: $(xml_unescape(code.captures[1])): $said"
end

function header(response, name)
    i = findfirst(kv -> kv[1] == name, response.headers)
    return i === nothing ? nothing : response.headers[i][2]
end

"""
    xml_unescape(s)

Return `s` with XML's five named entities and its numeric character references undone.
"""
xml_unescape(s::AbstractString) = replace(s, XML_ENTITY => xml_entity_text)

function xml_entity_text(entity::AbstractString)
    haskey(XML_NAMED_ENTITIES, entity) && return XML_NAMED_ENTITIES[entity]
    hex = startswith(entity, "&#x")
    digits = entity[(hex ? 4 : 3):(end - 1)]
    return string(Char(parse(Int, digits; base = hex ? 16 : 10)))
end
