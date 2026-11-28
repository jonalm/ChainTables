# One `"name": "value"` of a minted reply's `headers`: a lowercase name, and a value of
# printable ASCII with no quote or backslash, so it needs no unescaping (ADR-0046).
const MINTED_HEADER = r"\"([a-z0-9-]+)\"\s*:\s*\"([\x20\x21\x23-\x5b\x5d-\x7e]*)\""

const MINTED_HEADERS =
    Regex("\\A\\s*(?:" * MINTED_HEADER.pattern * "\\s*(?:,\\s*(?=\")|\\z))*\\z")

const MINTED_HEADERS_OBJECT = r"\"headers\"\s*:\s*\{([^{}]*)\}"

const MINTED_SECONDS = r"\"seconds\"\s*:\s*(-?[0-9]{1,9})\s*[,}]"

const MINTED_CAPPED = r"\"capped\"\s*:\s*(true|false)\s*[,}]"

const URLLifetime = @NamedTuple{seconds::Int64, capped::Bool}

"""
    MintPresent()

The mint route's answer when the bucket holds the attachment: the gateway extended its
retention, and nothing is uploaded.
"""
struct MintPresent end

"""
    MintedURL(url, expires, lifetime, headers, received)

The mint route's answer when the bucket lacks the attachment: a presigned PUT of the
key, to send with exactly `headers`.

`lifetime` is the URL's life in seconds and whether the gateway's session capped it;
`nothing` from a gateway older than it. `received` is when the reply arrived, in
`time_ns()`: the URL was signed before then, so it expires no later than `received`
plus its life.
"""
struct MintedURL
    url::String
    expires::String  # ISO 8601 in UTC, as the gateway gives it
    lifetime::Union{Nothing, URLLifetime}
    headers::Vector{Pair{String, String}}
    received::Int64
end

"""
    UnreadableReplyError(detail)

Thrown when a minted reply lacks a part that this client reads, or has it in another
form. `mint` throws it again as a `TransportError` with status 200.
"""
struct UnreadableReplyError <: Exception
    detail::String
end

function mint_answer(url::String, code, body::Vector{UInt8})
    code == "present" && return MintPresent()
    code == "minted" && return minted_url(url, body)
    throw(
        TransportError(;
            method = "POST", url, status = 200,
            detail = "the code $(repr(code)) is neither present nor minted: this " *
                "gateway speaks a mint route that this client does not know",
        )
    )
end

function minted_url(url::String, body::Vector{UInt8})
    received = Int64(time_ns())
    text = String(copy(body))
    try
        return parse_minted_reply(text, received)
    catch e
        e isa UnreadableReplyError || rethrow()
        detail = "the minted reply has $(e.detail): $(first(text, 500))"
        throw(TransportError(; method = "POST", url, status = 200, detail))
    end
end

# Read without a JSON parser (ADR-0027), and strictly: a reply that this cannot read is
# refused, never guessed at.
function parse_minted_reply(text::String, received::Int64)
    url = minted_text(text, "url")
    expires = minted_text(text, "expires")
    lifetime = minted_lifetime(text)
    headers = minted_headers(text)
    return MintedURL(url, expires, lifetime, headers, received)
end

function minted_text(text::String, name::String)
    m = match(Regex("\"$name\"\\s*:\\s*\"((?:[^\"\\\\]|\\\\.)*)\""), text)
    m === nothing && throw(UnreadableReplyError("no \"$name\""))
    return json_unescape(m[1])
end

function minted_headers(text::String)
    object = match(MINTED_HEADERS_OBJECT, text)
    object === nothing && throw(UnreadableReplyError("no \"headers\" object"))
    inner = object[1]
    occursin(MINTED_HEADERS, inner) || throw(
        UnreadableReplyError(
            "a \"headers\" object that is not a flat map of lowercase names to plain " *
                "ASCII strings"
        )
    )
    headers = [String(m[1]) => String(m[2]) for m in eachmatch(MINTED_HEADER, inner)]
    isempty(headers) && throw(UnreadableReplyError("an empty \"headers\" object"))
    return headers
end

# A reply with neither `seconds` nor `capped` is from a gateway older than them, which
# `upload_minted` refuses.
function minted_lifetime(text::String)
    _has_seconds = occursin(r"\"seconds\"\s*:", text)
    _has_capped = occursin(r"\"capped\"\s*:", text)
    _has_seconds || _has_capped || return nothing
    _has_capped || throw(UnreadableReplyError("\"seconds\" without \"capped\""))
    _has_seconds || throw(UnreadableReplyError("\"capped\" without \"seconds\""))
    seconds = match(MINTED_SECONDS, text)
    seconds === nothing &&
        throw(UnreadableReplyError("a \"seconds\" that is not a whole number"))
    capped = match(MINTED_CAPPED, text)
    capped === nothing &&
        throw(UnreadableReplyError("a \"capped\" that is not true or false"))
    return URLLifetime((parse(Int64, seconds[1]), capped[1] == "true"))
end
