const NS_PER_SECOND = 1_000_000_000

const CAPPED_HINT = "; the gateway's AWS session shortened this URL (capped), and " *
    "another put may reach a younger gateway environment, which mints a longer one"

# ADR-0046's write on a gateway bucket: the mint route, the upload to the URL it
# mints, then a HEAD that the bucket this chain reads holds the key. A gateway that
# fronts another bucket would otherwise store the attachment where no reader looks
# (ADR-0029).
function upload_attachment(store::GatewayObjectStore, key::AbstractString, io::IO)
    upload = AttachmentUpload(key, io)
    uploaded = upload_to_mint(store, upload, mint(store, upload.key, upload.size))
    confirm_attachment(store, upload)
    return uploaded
end

upload_to_mint(store::GatewayObjectStore, upload::AttachmentUpload, ::MintPresent) = false

# A `412`: another writer stored it first. The mint is asked again, which must find
# it present and so extends its retention.
function upload_to_mint(
        store::GatewayObjectStore, upload::AttachmentUpload, minted::MintedURL
    )
    upload_minted(store, upload, minted) && return true
    again = mint(store, upload.key, upload.size)
    again isa MintPresent || throw(
        GatewayMismatchError(
            store, upload.key;
            detail = "S3 refused the upload as already present (412), and the gateway " *
                "then found it absent and minted another URL",
        )
    )
    return false
end

function GatewayMismatchError(store::GatewayObjectStore, key; detail)
    return GatewayMismatchError(;
        key, store.s3.bucket, gateway = store.function_url, detail
    )
end

# `POST /mint?key=<key>&size=<bytes>` to the function URL, signed for `lambda`, with no
# body. A `409`, a `429` and a `5xx` are `TransportError`s that a caller retries.
function mint(store::GatewayObjectStore, key::String, size::Int64)
    query = ["key" => key, "size" => string(size)]
    headers = signed_headers(
        current_credentials(store.s3); store.s3.region, service = "lambda", store.host,
        method = "POST", path = "/mint", query,
    )
    url = store.function_url * "/mint" * query_string(query)
    response = http_request("POST", url; headers, store.s3.timeout)
    status, reply = response.status, gateway_reply(response.body)
    status == 200 && return mint_answer(url, reply.code, response.body)
    check_mint_refusal(store, key, status, reply)
    throw(TransportError(; method = "POST", url, status, detail = reply_text(reply)))
end

# The answers that name who must act, or that no retry can help.
function check_mint_refusal(store::GatewayObjectStore, key::String, status, reply)
    is_refusal(status, reply.code) && throw(
        WriteRefusedError(;
            key, gateway = store.function_url, caller = memoized_author(store),
            reason = something(reply.code, "forbidden"),
            detail = something(reply.message, ""),
        )
    )
    is_missing_mint_route(status, reply) && throw(
        WriteRefusedError(;
            key, gateway = store.function_url, caller = memoized_author(store),
            reason = "no_mint_route", detail = reply.message,
        )
    )
    is_session_ending(status, reply.code) && throw(
        GatewaySessionEndingError(;
            key, gateway = store.function_url, detail = something(reply.message, "")
        )
    )
    return nothing
end

# A gateway deployed before attachments has one route, and refuses any other.
function is_missing_mint_route(status::Integer, reply)
    (status == 400 && reply.code == "bad_request") || return false
    reply.message === nothing && return false
    return occursin("is not the gateway's one route", reply.message)
end

# The Lambda environment that answered is too old: its AWS session ends within 15 min,
# too soon to sign a URL. A retry now most likely reaches the same environment (#94).
is_session_ending(status::Integer, code) = status == 503 && code == "session_ending"

# The streamed PUT to a minted URL: `true` when stored, `false` on `412`. Every check
# of the reply runs before a byte is sent.
function upload_minted(
        store::GatewayObjectStore, upload::AttachmentUpload, minted::MintedURL
    )
    check_minted_reply(store, upload, minted)
    started = Int64(time_ns())
    started < url_deadline(minted) || throw(
        AttachmentURLExpiredError(
            store, minted, upload.key; reason = :expired_before_upload,
            detail = "this process waited $(whole_seconds(started - minted.received)) " *
                "s after the mint, and the URL lived $(lifetime_seconds(minted)) s; " *
                "nothing was sent",
        )
    )
    response = stream_to_minted_url(store, upload, minted, started)
    status, body = response.status, response.body
    status == 200 && return true
    status == 412 && return false
    is_bad_digest(status, body) &&
        throw(AttachmentChangedError(; store.s3.bucket, upload.key))
    is_expired_refusal(status, body) ||
        throw(TransportError("PUT", bare_url(minted.url), response))
    late = expired_refusal(upload, minted, started)
    throw(AttachmentURLExpiredError(store, minted, upload.key; late.reason, late.detail))
end

# S3 calls a URL expired up to about a second before the end that this client counts.
# Near that end the upload outlasted the URL; well before it, a clock is off.
function expired_refusal(upload::AttachmentUpload, minted::MintedURL, started::Int64)
    is_near_deadline(minted) &&
        return (; reason = :outlasted, detail = outlasted_text(upload, minted, started))
    ran = whole_seconds(Int64(time_ns()) - started)
    detail = "S3 refused the upload as expired after $ran s, though the URL lives " *
        "$(lifetime_seconds(minted)) s"
    return (; reason = :expired_early, detail)
end

function AttachmentURLExpiredError(
        store::GatewayObjectStore, minted::MintedURL, key; reason, detail
    )
    return AttachmentURLExpiredError(;
        key, gateway = store.function_url, minted.expires, reason, detail
    )
end

# A gateway that mints otherwise than ADR-0046 says (a bug, or a gateway older than the
# rule) is refused before a byte is sent.
function check_minted_reply(
        store::GatewayObjectStore, upload::AttachmentUpload, minted::MintedURL
    )
    check_minted_url(store, upload.key, minted.url)
    check_minted_headers(store, upload, minted.headers)
    minted.lifetime === nothing && throw(
        GatewayMismatchError(
            store, upload.key;
            detail = "the gateway minted a URL without its lifetime (\"seconds\", " *
                "\"capped\"); nothing was sent",
        )
    )
    return nothing
end

# The URL must be the attachment's place in this chain's bucket, and carry a query: the
# signature.
function check_minted_url(store::GatewayObjectStore, key::String, url::String)
    expected = expected_attachment_url(store, key)
    bare = bare_url(url)
    bare == expected || throw(
        GatewayMismatchError(
            store, key;
            detail = "the gateway minted a URL at $bare, not at $expected, the " *
                "attachment's place in the bucket on its regional host; nothing was sent",
        )
    )
    length(url) > length(bare) + 1 || throw(
        GatewayMismatchError(
            store, key;
            detail = "the gateway minted a URL with no query, so no signature; nothing " *
                "was sent",
        )
    )
    return nothing
end

# The gateway presigns the chain's bucket on its regional host, virtual-hosted, whatever
# endpoint or addressing the reads use (ADR-0046, ADR-0029). Only a store that is not
# AWS (a test's loopback) is expected at the S3 half's own object URL.
function expected_attachment_url(store::GatewayObjectStore, key::AbstractString)
    s3 = store.s3
    is_aws(s3) || return object_url(s3, key)
    path = SigV4.uri_encode(key; keep_slash = true)
    return "https://$(s3.bucket).s3.$(s3.region).amazonaws.com/" * path
end

# The minted headers that make S3 check the bytes against the hash, refuse to overwrite
# the key and bound the body, each exactly once: an upload without them could store
# bytes that no hash vouches for, or replace the key (ADR-0046).
function check_minted_headers(
        store::GatewayObjectStore, upload::AttachmentUpload, headers
    )
    wanted = (
        ("x-amz-checksum-sha256", checksum_sha256(upload.hash), "check the bytes"),
        ("if-none-match", "*", "refuse to overwrite the key"),
        ("content-length", string(upload.size), "bound the upload to its size"),
    )
    for (name, value, purpose) in wanted
        got = [last(pair) for pair in headers if first(pair) == name]
        got == [value] && continue
        detail = minted_header_text(name, value, got) * "; nothing was sent. Without " *
            "it once, S3 might not $purpose"
        throw(GatewayMismatchError(store, upload.key; detail))
    end
    return nothing
end

function minted_header_text(name, value, got)
    isempty(got) && return "the gateway minted no $name header, where $(repr(value))"
    length(got) == 1 &&
        return "the gateway minted $name $(repr(only(got))), where $(repr(value))"
    return "the gateway minted $name $(length(got)) times ($(join(repr.(got), ", "))), " *
        "where once, $(repr(value))"
end

url_deadline(minted::MintedURL) = minted.received + lifetime_seconds(minted) * NS_PER_SECOND

lifetime_seconds(minted::MintedURL) = something(minted.lifetime).seconds

whole_seconds(ns::Integer) = max(0, round(Int64, ns / NS_PER_SECOND))

# S3 refuses an upload still running when its URL expires (ADR-0046), so the PUT stops
# at the URL's end, on this process's monotonic clock, which is no later than S3's.
function stream_to_minted_url(
        store::GatewayObjectStore, upload::AttachmentUpload, minted::MintedURL,
        started::Int64,
    )
    deadline = url_deadline(minted)
    output = IOBuffer()
    response = try
        http_stream(
            "PUT", minted.url; minted.headers, input = upload.io, output,
            stall = store.s3.timeout, deadline = (deadline - started) / NS_PER_SECOND,
        )
    catch e
        e isa TransportError || rethrow()
        Int64(time_ns()) >= deadline || rethrow()
        throw(
            AttachmentURLExpiredError(
                store, minted, upload.key; reason = :outlasted,
                detail = outlasted_text(upload, minted, started),
            )
        )
    end
    return (; response.status, body = take!(output))
end

function is_expired_refusal(status::Integer, body::Vector{UInt8})
    status == 403 || return false
    return occursin("Request has expired", String(copy(body)))
end

function is_near_deadline(minted::MintedURL)
    return Int64(time_ns()) + NS_PER_SECOND >= url_deadline(minted)
end

# The rate is what the size needs in the URL's life, so the advice is concrete. A
# capped URL may be longer from another gateway environment.
function outlasted_text(upload::AttachmentUpload, minted::MintedURL, started::Int64)
    seconds = lifetime_seconds(minted)
    rate = max(cld(upload.size, 1024 * max(seconds, 1)), 1)
    ran = whole_seconds(Int64(time_ns()) - started)
    text = "the upload ran $ran s, past the URL's life of $seconds s; its " *
        "$(upload.size) bytes need $rate KiB/s or more"
    return something(minted.lifetime).capped ? text * CAPPED_HINT : text
end

function confirm_attachment(store::GatewayObjectStore, upload::AttachmentUpload)
    meta = stat_object(store.s3, upload.key)
    _is_held = meta !== nothing && meta.size == upload.size
    _is_held && return nothing
    held = held_attachment_text(meta, upload.size)
    detail = "the gateway has stored the attachment, and " * held
    throw(GatewayMismatchError(store, upload.key; detail))
end

held_attachment_text(::Nothing, size) = "the bucket does not hold it"

function held_attachment_text(meta::ObjectMeta, size)
    return "the bucket holds $(meta.size) bytes there, not $size"
end

# Reads go to the bucket directly (ADR-0028).
function fetch_object_to(
        store::GatewayObjectStore, key::AbstractString, path::AbstractString
    )
    return fetch_object_to(store.s3, key, path)
end
