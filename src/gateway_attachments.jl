# One `"name": "value"` of a minted reply's `headers`: a lowercase name, and a value of
# printable ASCII with no quote or backslash, so it needs no unescaping (ADR-0046).
const MINTED_HEADER = r"\"([a-z0-9-]+)\"\s*:\s*\"([\x20\x21\x23-\x5b\x5d-\x7e]*)\""
const MINTED_HEADERS =
    Regex("\\A\\s*(?:" * MINTED_HEADER.pattern * "\\s*(?:,\\s*(?=\")|\\z))*\\z")
const MINTED_HEADERS_OBJECT = r"\"headers\"\s*:\s*\{([^{}]*)\}"
const MINTED_SECONDS = r"\"seconds\"\s*:\s*(-?[0-9]{1,9})\s*[,}]"
const MINTED_CAPPED = r"\"capped\"\s*:\s*(true|false)\s*[,}]"
const NO_MINT_ROUTE = "is not the gateway's one route"

# A gateway bucket's write (ADR-0046): mint, check the URL and its signed headers before a
# byte is sent, stream the bytes to it, then confirm the key in the bucket this chain
# reads (ADR-0029). A mint answered `present` uploads nothing: the gateway extended the
# retention. An upload answered 412 lost a race to another writer, so a second mint must
# answer `present`, which extends the retention.
function put_attachment(store::GatewayObjectStore, key::AbstractString, io::IO)
    key = String(key)
    attachment_hash(key)
    size = stream_size(io)
    reply = mint(store, key, size)
    uploaded = reply.code == "minted" && upload_minted(store, key, io, size, reply)
    _is_lost_race = reply.code == "minted" && !uploaded
    _is_lost_race && check_present_on_second_mint(store, key, size)
    confirm_attachment(store, key, size)
    return uploaded
end

# A HEAD first, so an absent attachment fails and the mint gets the size its present
# path needs.
function touch_attachment(store::GatewayObjectStore, key::AbstractString)
    key = String(key)
    attachment_hash(key)
    meta = stat_object(store.s3, key)
    meta === nothing && return false
    mint(store, key, Int64(meta.size)).code == "present" && return true
    throw(
        GatewayMismatchError(;
            key, bucket = store.s3.bucket, gateway = store.function_url,
            detail = "the bucket holds the attachment, and the gateway minted a URL for it"
        )
    )
end

# Reads go to the bucket directly (ADR-0028).
function fetch_object_to(
        store::GatewayObjectStore, key::AbstractString, path::AbstractString
    )
    return fetch_object_to(store.s3, key, path)
end

"""
    mint(store, key, size)

Ask the gateway's mint route for the attachment at `key` of `size` bytes:
`(; code = "present", …)` when the bucket holds it, else
`(; code = "minted", url, expires, seconds, capped, headers, received)`, `received` the
`time_ns()` the reply arrived at. A refusal throws.
"""
function mint(store::GatewayObjectStore, key::String, size::Int64)
    query = ["key" => key, "size" => string(size)]
    credentials = current_credentials(store.s3)
    headers = signed_headers(
        credentials, store.s3.region, "lambda", store.host, "POST", "/mint"; query
    )
    url = store.function_url * "/mint" * query_string(query)
    response = http_request(url, "POST", headers, UInt8[], store.timeout)
    response.status == 200 || throw_mint_refusal(store, key, url, response)
    return mint_answer(url, first(gateway_reply(response.body)), response.body)
end

function mint_answer(url, code, body)
    code == "present" &&
        return (; code = "present", url = nothing, expires = nothing, headers = nothing)
    code == "minted" && return minted_reply(url, body)
    detail = "POST $url: HTTP 200 with code $(repr(code)), neither present nor minted"
    throw(TransportError(detail; status = 200))
end

# 409, 429 and any other 5xx end as a retryable `TransportError`. A `session_ending` is not
# retried: the next request most likely meets the same old environment (ADR-0046).
function throw_mint_refusal(store, key, url, response)
    status = response.status
    code, message = gateway_reply(response.body)
    reason = something(code, "forbidden")
    detail = "the mint was refused" * message_suffix(message)
    caller = store.author
    status == 403 && throw(WriteRefusedError(; key, caller, reason, detail))
    code == "s3_refused" && throw(WriteRefusedError(; key, caller, reason, detail))
    no_route = "the gateway has no mint route"
    is_missing_mint_route(status, code, message) &&
        throw(WriteRefusedError(; key, reason = "no_mint_route", detail = no_route))
    gateway = store.function_url
    status == 503 && code == "session_ending" && throw(
        GatewaySessionEndingError(; key, gateway, detail = something(message, "no message"))
    )
    throw(TransportError("POST $url: HTTP $status$(code_suffix(code, message))"; status))
end

function is_missing_mint_route(status, code, message)
    return status == 400 && code == "bad_request" && message !== nothing &&
        occursin(NO_MINT_ROUTE, message)
end

message_suffix(message) = message === nothing ? "" : ": " * message
code_suffix(code, message) = code === nothing ? "" : " " * code * message_suffix(message)

# Read without a JSON parser (ADR-0027) and strictly: a reply this cannot read is refused,
# never guessed at. A reply with neither `seconds` nor `capped` is from a gateway older than
# them, which `upload_minted` refuses. The URL was signed before the reply arrived, so it
# expires no later than `received` plus `seconds`.
function minted_reply(url, body::Vector{UInt8})
    # Not an `at` keyword: the monotonic clock sets a deadline that `upload_minted` reads
    # again, and tests reach it by waiting.
    received = Int64(time_ns())
    text = String(copy(body))
    minted_url = minted_field(url, text, "url")
    expires = minted_field(url, text, "expires")
    headers = minted_headers(url, text)
    seconds, capped = minted_lifetime(url, text)
    url = minted_url
    return (; code = "minted", url, expires, seconds, capped, headers, received)
end

function minted_field(url, text, name)
    m = match(Regex("\"$name\"\\s*:\\s*\"((?:[^\"\\\\]|\\\\.)*)\""), text)
    m === nothing &&
        throw(TransportError(unreadable_reply(url, text, "no \"$name\""); status = 200))
    return json_unescape(m.captures[1])
end

function minted_headers(url, text)
    object = match(MINTED_HEADERS_OBJECT, text)
    object === nothing &&
        throw(TransportError(unreadable_reply(url, text, NO_HEADERS); status = 200))
    inner = object.captures[1]
    occursin(MINTED_HEADERS, inner) ||
        throw(TransportError(unreadable_reply(url, text, NOT_FLAT_HEADERS); status = 200))
    headers = map(minted_header_pair, eachmatch(MINTED_HEADER, inner))
    isempty(headers) &&
        throw(TransportError(unreadable_reply(url, text, EMPTY_HEADERS); status = 200))
    return headers
end

minted_header_pair(m::RegexMatch) = String(m.captures[1]) => String(m.captures[2])

const NO_HEADERS = "no \"headers\" object"
const EMPTY_HEADERS = "an empty \"headers\" object"
const NOT_FLAT_HEADERS =
    "a \"headers\" object that is not a flat map of lowercase names to plain ASCII strings"
const SECONDS_ALONE = "\"seconds\" without \"capped\""
const CAPPED_ALONE = "\"capped\" without \"seconds\""
const BAD_SECONDS = "a \"seconds\" that is not a whole number"
const BAD_CAPPED = "a \"capped\" that is not true or false"

function minted_lifetime(url, text)
    _has_seconds = occursin(r"\"seconds\"\s*:", text)
    _has_capped = occursin(r"\"capped\"\s*:", text)
    _has_seconds || _has_capped || return (nothing, nothing)
    _has_capped ||
        throw(TransportError(unreadable_reply(url, text, SECONDS_ALONE); status = 200))
    _has_seconds ||
        throw(TransportError(unreadable_reply(url, text, CAPPED_ALONE); status = 200))
    s = match(MINTED_SECONDS, text)
    s === nothing &&
        throw(TransportError(unreadable_reply(url, text, BAD_SECONDS); status = 200))
    c = match(MINTED_CAPPED, text)
    c === nothing &&
        throw(TransportError(unreadable_reply(url, text, BAD_CAPPED); status = 200))
    return (parse(Int64, s.captures[1]), c.captures[1] == "true")
end

function unreadable_reply(url, text, what)
    return "POST $url: the minted reply has $what: $(first(text, 500))"
end

"""
    upload_minted(store, key, io, size, reply)

Stream the `size` bytes of `io` to the URL `reply` minted for `key`, with exactly its
signed headers: `true` when stored, `false` on `412`. The URL and the headers are checked
first, and nothing is sent when they are wrong. Throws `AttachmentChangedError` on S3's
`BadDigest` and `AttachmentURLExpiredError` when the URL expired.
"""
function upload_minted(store::GatewayObjectStore, key::String, io::IO, size::Int64, reply)
    check_minted_reply(store, key, reply, size)
    # S3 refuses an upload still running when its URL expires (ADR-0046), so the PUT stops
    # at the URL's end: `deadline`, on this process's monotonic clock, is no earlier than
    # S3's.
    deadline = reply.received + reply.seconds * 1_000_000_000
    started = Int64(time_ns())
    (; expires) = reply
    waited = waited_detail(reply, started)
    started < deadline || throw(AttachmentURLExpiredError(; key, expires, detail = waited))
    sent = put_minted_body(reply, io, deadline, started; stall = store.timeout)
    outlasted = outlasted_detail(size, reply, started)
    sent === nothing && throw(AttachmentURLExpiredError(; key, expires, detail = outlasted))
    sent.status == 200 && return true
    sent.status == 412 && return false
    where = bare_url(reply.url)
    is_bad_digest(sent.status, sent.body) &&
        throw(AttachmentChangedError(; key, detail = "S3 at $where answered BadDigest"))
    expired = expired_detail(size, reply, started, deadline)
    is_expired_refusal(sent) &&
        throw(AttachmentURLExpiredError(; key, expires, detail = expired))
    throw(failure("PUT", where, sent))
end

const NO_LIFETIME = "it minted a URL without its lifetime (\"seconds\", \"capped\")"

# A gateway that mints otherwise, a bug or one that predates the lifetime, is refused
# before a byte is sent.
function check_minted_reply(store::GatewayObjectStore, key::String, reply, size::Int64)
    check_minted_url(store, key, reply.url)
    check_minted_headers(store, key, reply.headers, size)
    (; bucket) = store.s3
    gateway = store.function_url
    reply.seconds === nothing &&
        throw(GatewayMismatchError(; key, bucket, gateway, detail = NO_LIFETIME))
    return nothing
end

# Where a minted URL must point (ADR-0046, ADR-0029): the chain's bucket on its regional
# host, virtual-hosted, which is what the gateway presigns, whatever endpoint or
# addressing the reads use; only a store that is not AWS (a test's loopback) is expected
# at the S3 half's own object URL. A URL with no query carries no signature.
function check_minted_url(store::GatewayObjectStore, key::String, url::String)
    expected = expected_attachment_url(store, key)
    where = bare_url(url)
    where == expected || throw(
        GatewayMismatchError(;
            key, bucket = store.s3.bucket, gateway = store.function_url,
            detail = "it minted a URL at $where, not at $expected"
        )
    )
    length(url) > length(where) + 1 || throw(
        GatewayMismatchError(;
            key, bucket = store.s3.bucket, gateway = store.function_url,
            detail = "it minted a URL with no query, so no signature"
        )
    )
    return nothing
end

function expected_attachment_url(store::GatewayObjectStore, key::AbstractString)
    s3 = store.s3
    is_aws(s3) || return s3.base * object_path(s3, key)
    return "https://$(s3.bucket).s3.$(s3.region).amazonaws.com/" *
        uri_encode(key; keep_slash = true)
end

# The headers that make S3 check the bytes against the hash, refuse to overwrite the key
# and bound the body (ADR-0046), each exactly once: an upload without them could store
# bytes no hash vouches for, or replace the key, and a header minted twice leaves it to S3
# which one counts.
function check_minted_headers(store::GatewayObjectStore, key::String, headers, size::Int64)
    wanted = [
        "x-amz-checksum-sha256" => checksum_sha256(key[(end - 63):end]),
        "if-none-match" => "*",
        "content-length" => string(size),
    ]
    foreach(w -> check_minted_header(store, key, headers, w), wanted)
    return nothing
end

function check_minted_header(store, key, headers, (name, value))
    got = [last(kv) for kv in headers if first(kv) == name]
    length(got) == 1 && only(got) == value && return nothing
    throw(
        GatewayMismatchError(;
            key, bucket = store.s3.bucket, gateway = store.function_url,
            detail = minted_header_problem(name, value, got)
        )
    )
end

function minted_header_problem(name, value, got)
    isempty(got) && return "it minted no $name header, where $(repr(value))"
    length(got) == 1 && return "it minted $name $(repr(only(got))), where $(repr(value))"
    values = join(repr.(got), ", ")
    return "it minted $name $(length(got)) times ($values), where once, $(repr(value))"
end

# `nothing` when the PUT failed at or past `deadline`: then the URL expired under it.
function put_minted_body(reply, io::IO, deadline::Int64, started::Int64; stall)
    output = IOBuffer()
    window = (deadline - started) / 1.0e9
    response = try
        http_stream(
            reply.url, "PUT", reply.headers; input = io, output, stall, deadline = window
        )
    catch e
        e isa TransportError || rethrow()
        Int64(time_ns()) >= deadline || rethrow()
        nothing
    end
    response === nothing && return nothing
    return (; response.status, body = take!(output))
end

whole_seconds(ns) = max(0, round(Int64, ns / 1.0e9))

function waited_detail(reply, started)
    waited = whole_seconds(started - reply.received)
    return "the URL lived $(reply.seconds) s, and this process waited $waited s after " *
        "the mint before uploading; nothing was sent"
end

# The rate is what the size needs in the URL's life, so the advice is concrete; a capped
# URL may be longer from another gateway environment.
function outlasted_detail(size, reply, started)
    ran = whole_seconds(Int64(time_ns()) - started)
    rate = max(cld(size, 1024 * max(reply.seconds, 1)), 1)
    capped = reply.capped ? "; the gateway's AWS session capped this URL, so another " *
        "put may get a longer one" : ""
    return "the upload ran $ran s, past the URL's $(reply.seconds) s life; its $size " *
        "bytes need $rate KiB/s or more" * capped
end

function is_expired_refusal(sent)
    return sent.status == 403 && occursin("Request has expired", String(copy(sent.body)))
end

function expired_detail(size, reply, started, deadline)
    ran = Int64(time_ns()) - started
    _is_at_end = ran + 1_000_000_000 >= deadline - started
    _is_at_end && return outlasted_detail(size, reply, started)
    return "S3 refused the upload as expired after $(whole_seconds(ran)) s of the URL's " *
        "$(reply.seconds) s: the gateway's clock is off, or S3's"
end

# Another writer stored the attachment first: the gateway, which checks its own bucket,
# must then find it present.
function check_present_on_second_mint(store::GatewayObjectStore, key::String, size::Int64)
    mint(store, key, size).code == "present" && return nothing
    throw(
        GatewayMismatchError(;
            key, bucket = store.s3.bucket, gateway = store.function_url,
            detail = "S3 refused the upload as present (412), and a second mint found " *
                "it absent"
        )
    )
end

# A gateway's word is believed only once the bucket this chain reads holds the key at the
# size sent (ADR-0029): a gateway fronting another bucket would otherwise store the
# attachment where no reader of this chain looks.
function confirm_attachment(store::GatewayObjectStore, key::String, size::Int64)
    meta = stat_object(store.s3, key)
    meta !== nothing && meta.size == size && return nothing
    held = meta === nothing ? "does not hold it" : "holds $(meta.size) bytes, not $size"
    throw(
        GatewayMismatchError(;
            key, bucket = store.s3.bucket, gateway = store.function_url,
            detail = "after the gateway's word, the bucket $held"
        )
    )
end
