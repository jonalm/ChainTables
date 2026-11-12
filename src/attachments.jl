# ADR-0046 — attachments at the store: `put_attachment(store, key, io)` dispatched on the
# store, as `record_author` is. A plain bucket takes a direct streamed PUT with the
# checksum and `If-None-Match: *`; a gateway bucket asks the mint route, then streams the
# bytes to the URL it minted, with exactly the headers it signed. Not a verb of the port
# (ADR-0010): a store of the user's own needs none of this unless it holds attachments.

import Base64

"""
    ATTACHMENT_MAX_BYTES

The largest attachment, 5 GiB: S3's limit for one PUT, which is what carries an
attachment, since a multipart upload has no SHA-256 of the whole object (ADR-0046).
"""
const ATTACHMENT_MAX_BYTES = 5 * 1024^3

const ATTACHMENT_KEY = r"(?:\A|/)_attachments/([0-9a-f]{64})\z"

# The `<h>` of an attachment key, `[<prefix>/]_attachments/<h>`; anything else is a caller's bug.
function attachment_hash(key::AbstractString)
    m = match(ATTACHMENT_KEY, key)
    m === nothing && throw(
        ArgumentError(
            "$(repr(key)) is not an attachment key, [<prefix>/]_attachments/<SHA-256 in 64 " *
                "lowercase hex> (ADR-0046)"
        )
    )
    return String(m.captures[1])
end

# The bytes `io` holds from its start, which must be where it stands: libcurl rewinds an
# upload to offset 0, so a body that began further in would be sent wrong.
function stream_size(io::IO)
    position(io) == 0 || throw(ArgumentError("an attachment's IO must stand at its start, not at byte $(position(io))"))
    size = position(seekend(io))
    seekstart(io)
    size <= ATTACHMENT_MAX_BYTES || throw(
        ArgumentError(
            "an attachment of $size bytes is over the 5 GiB that one S3 PUT " *
                "takes ($ATTACHMENT_MAX_BYTES bytes; ADR-0046)"
        )
    )
    return Int64(size)
end

checksum_sha256(h::AbstractString) = Base64.base64encode(hex2bytes(h))

"""
    put_attachment(store, key, io) -> Bool

Store the bytes of `io`, a seekable IO at its start, as the attachment at `key`,
`[<prefix>/]_attachments/<h>` where `<h>` is their SHA-256 (ADR-0046). `true` when this
call stored them, `false` when the store already held the key. The caller hashed the
bytes; the store checks the hash on the way in, and bytes that do not match raise
[`AttachmentChangedError`](@ref) with nothing stored.

- [`S3ObjectStore`](@ref): one streamed PUT with `If-None-Match: *` and the checksum; `412`
  is `false`.
- [`GatewayObjectStore`](@ref): the mint route, then a streamed PUT to the minted URL;
  see its method.
- `Testing.InMemoryObjectStore`: the same outcomes, in memory.

Failures raise as the port's verbs do (ADR-0010): a `TransportError`, retried by no one
here.
"""
function put_attachment end

function put_attachment(store::S3ObjectStore, key::AbstractString, io::IO)
    h = attachment_hash(key)
    size = stream_size(io)
    req = request_headers(
        store, "PUT", key; payload_hash = h, content_length = size,
        headers = [
            "content-type" => "application/octet-stream", "if-none-match" => "*",
            "x-amz-checksum-sha256" => checksum_sha256(h),
        ]
    )
    output = IOBuffer()
    response = http_stream(req.url, "PUT", req.headers; input = io, output, stall = store.timeout)
    response.status == 200 && return true
    response.status == 412 && return false
    body = take!(output)
    url = store.base * object_path(store, key)
    bad_digest(response.status, body) && throw(changed(key, url))
    throw(failure("PUT", url, (; response.status, body)))
end

# S3's two words for bytes that do not hash as signed: `BadDigest` for the checksum header,
# `XAmzContentSHA256Mismatch` for a signed payload hash, which a direct PUT also sends.
bad_digest(status, body) = status == 400 && occursin(r"<Code>(?:BadDigest|XAmzContentSHA256Mismatch)</Code>", String(copy(body)))

changed(key, where) = AttachmentChangedError(
    "attachment changed: the upload of $key to $where was refused as BadDigest — " *
        "the bytes sent do not hash to the key's SHA-256, so the file changed between hashing and upload. Nothing was " *
        "stored. Stop whatever writes the file, then put the attachment again (ADR-0046)."; key = String(key)
)

# ---------------------------------------------------------------------------
# A gateway bucket (ADR-0046): mint, check the URL, stream the bytes to it with exactly
# the signed headers, then confirm the key in the bucket this chain reads (ADR-0029).
# ---------------------------------------------------------------------------

"""
    put_attachment(store::GatewayObjectStore, key, io) -> Bool

ADR-0046's write on a gateway bucket:

1. `POST /mint?key=<key>&size=<bytes>` to the function URL, signed for `lambda`, empty
   body. `present`: nothing is uploaded (the gateway extended a locked bucket's
   retention), go to 4.
2. `minted`: the URL must be the chain's bucket on its regional host and the key's path,
   with a query, the headers must carry the hash (`x-amz-checksum-sha256`),
   `if-none-match: *` and the size (`content-length`), and the reply must give the URL's
   lifetime (`seconds`, `capped`) — else [`GatewayMismatchError`](@ref), before a byte is
   sent.
3. A streamed PUT to it with exactly the reply's headers, following no redirect, stopped
   at the URL's end, since S3 refuses an upload still running then. `412`:
   another writer stored it first, and the mint is asked again, which must answer
   `present` and so extends the retention — else [`GatewayMismatchError`](@ref), as
   for `touch_attachment`: the gateway checks another bucket.
4. A HEAD of the key in this chain's bucket, which must hold it at this size — else
   [`GatewayMismatchError`](@ref): the gateway fills another bucket.

| reply | raised |
|---|---|
| mint `403`, or `502 s3_refused` | [`WriteRefusedError`](@ref), as for a slot |
| mint `400 bad_request` from a gateway that predates the route | [`WriteRefusedError`](@ref), `reason = "no_mint_route"`: redeploy it |
| mint `400`, `413` | `TransportError`, not retried |
| mint `503 session_ending` | [`GatewaySessionEndingError`](@ref), not retried: put again later (#94) |
| mint `409`, `429`, any other `5xx` | `TransportError`, retryable |
| upload `400 BadDigest` | [`AttachmentChangedError`](@ref) |
| upload `403` "Request has expired", or still running at the URL's end | [`AttachmentURLExpiredError`](@ref), not retried |
| any other upload status | `TransportError` carrying S3's code, the URL's signature left out |
"""
function put_attachment(store::GatewayObjectStore, key::AbstractString, io::IO)
    key = String(key)
    attachment_hash(key)
    size = stream_size(io)
    reply = mint(store, key, size)
    if reply.code == "minted"
        uploaded = upload_minted(store, key, io, size, reply)
        if !uploaded
            again = mint(store, key, size)
            again.code == "present" || throw(
                GatewayMismatchError(
                    "gateway mismatch: S3 refused the upload of $key to " *
                        "bucket $(store.s3.bucket) as already present (412), and the gateway at $(store.function_url) then found " *
                        "it absent and minted another URL: the gateway checks another bucket than the one its URLs and this " *
                        "chain write. Pair the bucket with its own gateway — one ChainTables.Bucket value holds both (ADR-0029, " *
                        "ADR-0046)."; key, bucket = store.s3.bucket, gateway = store.function_url
                )
            )
        end
        confirm_attachment(store, key, size)
        return uploaded
    end
    confirm_attachment(store, key, size)
    return false
end

# The mint route's reply, `(; code, url, expires, headers)` with the last three `nothing`
# when `present`; a refusal raises.
function mint(store::GatewayObjectStore, key::String, size::Int64)
    query = Pair{String, String}["key" => key, "size" => string(size)]
    headers = signed_headers(current_credentials(store.s3), store.s3.region, "lambda", store.host, "POST", "/mint"; query)
    url = store.function_url * "/mint" * query_string(query)
    response = http_request(url, "POST", headers, UInt8[], store.timeout)
    status = response.status
    code, message = gateway_reply(response.body)
    if status == 200
        code == "present" && return (; code, url = nothing, expires = nothing, headers = nothing)
        code == "minted" && return minted_reply(url, response.body)
        throw(
            TransportError(
                "POST $url: HTTP 200 with code $(repr(code)), neither present nor minted; this gateway " *
                    "speaks a mint route this client does not know"; status
            )
        )
    end
    if status == 403 || code == "s3_refused"
        reason = something(code, "forbidden")
        throw(WriteRefusedError(refusal_message(store, key, reason, message; mint = true); key, caller = store.author, reason))
    end
    if status == 400 && code == "bad_request" && message !== nothing && occursin("is not the gateway's one route", message)
        throw(
            WriteRefusedError(
                "write refused: the gateway at $(store.function_url) has no mint route, so it cannot " *
                    "store the attachment $key — it answered POST /mint with bad_request: $message. It was deployed before " *
                    "attachments (ADR-0046): ask the bucket's operator to redeploy it (gateway/deploy.sh)."; key,
                reason = "no_mint_route"
            )
        )
    end
    if status == 503 && code == "session_ending"
        throw(
            GatewaySessionEndingError(
                "gateway session ending: the gateway at $(store.function_url) did not mint the " *
                    "upload of $key — session_ending: $(something(message, "no message")). The Lambda execution environment " *
                    "that answered is too old: its AWS session ends within 15 min, too soon to sign a URL. A retry now most " *
                    "likely reaches the same environment, so put_attachment did not retry. Nothing was stored. Put the " *
                    "attachment again later, once Lambda has replaced that environment (ADR-0046, #94)."; key,
                gateway = store.function_url
            )
        )
    end
    detail = code === nothing ? "" : " " * code * (message === nothing ? "" : ": " * message)
    throw(TransportError("POST $url: HTTP $status$detail"; status))    # 409, 429 and 5xx are retryable
end

# One `"name": "value"` of a minted reply's `headers`: a lowercase name, and a value of
# printable ASCII with no quote or backslash, so it needs no unescaping (ADR-0046).
const MINTED_HEADER = r"\"([a-z0-9-]+)\"\s*:\s*\"([\x20\x21\x23-\x5b\x5d-\x7e]*)\""
const MINTED_HEADERS = Regex("\\A\\s*(?:" * MINTED_HEADER.pattern * "\\s*(?:,\\s*(?=\")|\\z))*\\z")

# `url`, `expires`, `seconds`, `capped` and the flat `headers` object of a `minted` reply,
# read without a JSON parser (ADR-0027) and strictly: a reply this cannot read is refused,
# never guessed at. A reply with neither `seconds` nor `capped` is from a gateway older than
# them, which `upload_minted` refuses. `received` is when the reply arrived (`time_ns`): the
# URL was signed before, so it expires no later than `received` plus `seconds`.
function minted_reply(url, body::Vector{UInt8})
    received = Int64(time_ns())
    text = String(copy(body))
    unreadable(what) = TransportError("POST $url: the gateway's minted reply has $what: $(first(text, 500))"; status = 200)
    field(name) = (
        m = match(Regex("\"$name\"\\s*:\\s*\"((?:[^\"\\\\]|\\\\.)*)\""), text);
        m === nothing ? throw(unreadable("no \"$name\"")) : json_unescape(m.captures[1])
    )
    minted_url, expires = field("url"), field("expires")
    object = match(r"\"headers\"\s*:\s*\{([^{}]*)\}", text)
    object === nothing && throw(unreadable("no \"headers\" object"))
    inner = object.captures[1]
    occursin(MINTED_HEADERS, inner) ||
        throw(unreadable("a \"headers\" object that is not a flat map of lowercase names to plain ASCII strings"))
    headers = Pair{String, String}[String(m.captures[1]) => String(m.captures[2]) for m in eachmatch(MINTED_HEADER, inner)]
    isempty(headers) && throw(unreadable("an empty \"headers\" object"))
    has(name) = occursin(Regex("\"$name\"\\s*:"), text)
    seconds = capped = nothing
    if has("seconds") || has("capped")
        has("capped") || throw(unreadable("\"seconds\" without \"capped\""))
        has("seconds") || throw(unreadable("\"capped\" without \"seconds\""))
        s = match(r"\"seconds\"\s*:\s*(-?[0-9]{1,9})\s*[,}]", text)
        s === nothing && throw(unreadable("a \"seconds\" that is not a whole number"))
        c = match(r"\"capped\"\s*:\s*(true|false)\s*[,}]", text)
        c === nothing && throw(unreadable("a \"capped\" that is not true or false"))
        seconds, capped = parse(Int64, s.captures[1]), c.captures[1] == "true"
    end
    return (; code = "minted", url = minted_url, expires, seconds, capped, headers, received)
end

# Where a minted URL must point (ADR-0046, ADR-0029): the chain's bucket on its regional
# host, virtual-hosted — what the gateway presigns — whatever endpoint or addressing the
# reads use, so an AWS endpoint (path-style, FIPS, dual-stack) uploads there too; only a
# store that is not AWS (a test's loopback) is expected at the S3 half's own object URL.
function expected_attachment_url(store::GatewayObjectStore, key::AbstractString)
    s3 = store.s3
    is_aws(s3) || return s3.base * object_path(s3, key)
    return "https://$(s3.bucket).s3.$(s3.region).amazonaws.com/" * uri_encode(key; keep_slash = true)
end

# The URL with its query — the signature, a bearer credential until it expires — left out.
bare_url(url::AbstractString) = first(split(url, '?'; limit = 2))

# The minted headers that make S3 check the bytes against the hash, refuse to overwrite the
# key and bound the body (ADR-0046), each exactly once: a gateway that mints them otherwise — a bug, or one
# that predates them — is refused before a byte is sent, since an upload without them
# could store bytes no hash vouches for, or replace the key.
function check_minted_headers(store::GatewayObjectStore, key::String, headers, size::Int64)
    wanted = (
        ("x-amz-checksum-sha256", checksum_sha256(key[(end - 63):end]), "check the bytes against the hash"),
        ("if-none-match", "*", "refuse to overwrite the key"),
        ("content-length", string(size), "bound the upload to the attachment's size"),
    )
    for (name, value, guards) in wanted
        got = [last(kv) for kv in headers if first(kv) == name]
        length(got) == 1 && only(got) == value && continue
        problem = if isempty(got)
            "no $name header, where $(repr(value)). Nothing was sent. Without it S3 would not $guards"
        elseif length(got) == 1
            "$name $(repr(only(got))), where $(repr(value)). Nothing was sent. Without it S3 would not $guards"
        else
            "$name $(length(got) == 2 ? "twice" : "$(length(got)) times") ($(join(repr.(got), ", "))), where once, " *
                "$(repr(value)). Nothing was sent. A header minted more than once leaves it to S3 which one counts, so it " *
                "might not $guards"
        end
        throw(
            GatewayMismatchError(
                "gateway mismatch: the gateway at $(store.function_url) minted the upload of $key " *
                    "with $problem: this gateway is not the one ADR-0046 specifies; ask the bucket's operator to redeploy it " *
                    "(gateway/deploy.sh)."; key, bucket = store.s3.bucket, gateway = store.function_url
            )
        )
    end
    return nothing
end

whole_seconds(ns) = max(0, round(Int64, ns / 1.0e9))

# An upload still running at its URL's end (ADR-0046). The rate is what the size needs in
# the URL's life, so the advice is concrete; a capped URL may be longer from another
# gateway environment.
function outlasted(key, size, reply, started)
    rate = cld(size, 1024 * max(reply.seconds, 1))
    return AttachmentURLExpiredError(
        "attachment URL expired: the upload of $key ran " *
            "$(whole_seconds(Int64(time_ns()) - started)) s, past the $(reply.seconds) s life of the URL the gateway minted " *
            "(until $(reply.expires)), and S3 refuses an upload still running when its URL expires. Nothing was stored. " *
            "Its $size bytes need $(max(rate, 1)) KiB/s or more. Put the attachment again over a faster link (ADR-0046)." *
            (
            reply.capped ? " The gateway's AWS session shortened this URL (capped): another put may reach a younger " *
                "gateway environment, which mints a longer one." : ""
        ); key, expires = reply.expires
    )
end

# The streamed PUT to a minted URL: `true` when stored, `false` on `412`.
function upload_minted(store::GatewayObjectStore, key::String, io::IO, size::Int64, reply)
    expected = expected_attachment_url(store, key)
    where = bare_url(reply.url)
    where == expected || throw(
        GatewayMismatchError(
            "gateway mismatch: the gateway " *
                "at $(store.function_url) minted a URL for $key at $where, not at $expected, the attachment's place in bucket " *
                "$(store.s3.bucket) on its regional host. Nothing was sent. This gateway fronts another bucket or region than " *
                "the one this chain reads: pair the bucket with its own gateway, as one ChainTables.Bucket value (ADR-0029, " *
                "ADR-0046)."; key, bucket = store.s3.bucket, gateway = store.function_url
        )
    )
    length(reply.url) > length(where) + 1 || throw(
        GatewayMismatchError(
            "gateway mismatch: the gateway at " *
                "$(store.function_url) minted a URL for $key with no query, so no signature. Nothing was sent. This gateway's " *
                "mint is broken: ask the bucket's operator to redeploy it (gateway/deploy.sh) (ADR-0046)."; key,
            bucket = store.s3.bucket, gateway = store.function_url
        )
    )
    check_minted_headers(store, key, reply.headers, size)
    reply.seconds === nothing && throw(
        GatewayMismatchError(
            "gateway mismatch: the gateway at $(store.function_url) " *
                "minted a URL for $key without its lifetime (\"seconds\", \"capped\"), which it gives since S3 was found to " *
                "refuse an upload still running when its URL expires. Nothing was sent. Ask the bucket's operator to redeploy " *
                "it (gateway/deploy.sh) (ADR-0046)."; key, bucket = store.s3.bucket, gateway = store.function_url
        )
    )
    # S3 refuses an upload still running when its URL expires (ADR-0046), so the PUT stops at
    # the URL's end: `deadline`, on this process's monotonic clock, is no earlier than S3's.
    deadline = reply.received + reply.seconds * 1_000_000_000
    started = Int64(time_ns())
    started < deadline || throw(
        AttachmentURLExpiredError(
            "attachment URL expired: the URL the gateway at " *
                "$(store.function_url) minted for $key lived $(reply.seconds) s (until $(reply.expires)), and this process " *
                "waited $(whole_seconds(started - reply.received)) s after the mint before uploading. Nothing was sent. Put " *
                "the attachment again, which mints a new URL (ADR-0046)."; key, expires = reply.expires
        )
    )
    output = IOBuffer()
    response = try
        http_stream(
            reply.url, "PUT", reply.headers; input = io, output, stall = store.timeout,
            deadline = (deadline - started) / 1.0e9
        )
    catch e
        e isa TransportError && Int64(time_ns()) >= deadline || rethrow()
        throw(outlasted(key, size, reply, started))
    end
    response.status == 200 && return true
    response.status == 412 && return false
    body = take!(output)
    bad_digest(response.status, body) && throw(changed(key, where))
    if response.status == 403 && occursin("Request has expired", String(copy(body)))
        ran = Int64(time_ns()) - started
        ran + 1_000_000_000 >= deadline - started && throw(outlasted(key, size, reply, started))
        throw(
            AttachmentURLExpiredError(
                "attachment URL expired: S3 refused the upload of $key as expired after " *
                    "$(whole_seconds(ran)) s, though the gateway gave its URL $(reply.seconds) s (until $(reply.expires)): the " *
                    "gateway's clock is off, or S3's. Nothing was stored. Put the attachment again; if this recurs, report it " *
                    "to the bucket's operator (ADR-0046)."; key, expires = reply.expires
            )
        )
    end
    throw(failure("PUT", where, (; response.status, body)))
end

# A gateway's word is believed only once the bucket this chain reads holds the key, at
# the size sent (ADR-0029): a gateway fronting another bucket would otherwise store the
# attachment where no reader of this chain looks.
function confirm_attachment(store::GatewayObjectStore, key::String, size::Int64)
    meta = stat_object(store.s3, key)
    meta !== nothing && meta.size == size && return nothing
    bucket = store.s3.bucket
    throw(
        GatewayMismatchError(
            "gateway mismatch: the gateway at $(store.function_url) has stored the attachment $key, " *
                "and bucket $bucket $(meta === nothing ? "does not hold it" : "holds $(meta.size) bytes there, not $size"): this " *
                "gateway fronts another bucket than the one this chain reads. Pair the bucket with its own gateway — one " *
                "ChainTables.Bucket value holds both (ADR-0029) — and put the attachment again."; key, bucket,
            gateway = store.function_url
        )
    )
end

"""
    fetch_object_to(store::GatewayObjectStore, key, path) -> Union{Int64,Nothing}

The S3 half's: reads go to the bucket directly (ADR-0028).
"""
fetch_object_to(store::GatewayObjectStore, key::AbstractString, path::AbstractString) = fetch_object_to(store.s3, key, path)

# ---------------------------------------------------------------------------
# The client surface (ADR-0046): `put_attachment(chain, path_or_io)` and
# `touch_attachment(chain, hash)`.
# ---------------------------------------------------------------------------

attachment_key(chain::Chain, h::AbstractString) = isempty(chain.prefix) ? "_attachments/" * h : chain.prefix * "/_attachments/" * h

# The bounded retry of a whole store-level call, ADR-0010's rule with the commit's
# constants: re-issued on a retryable `TransportError`, the last one rethrown. Safe
# because each call is idempotent — a put whose upload landed finds the key present.
function with_retries(f)
    for attempt in 1:PUT_ATTEMPTS
        attempt == 1 || sleep(PUT_BACKOFF_S[attempt - 1])
        try
            return f()
        catch e
            (retryable(e) && attempt < PUT_ATTEMPTS) || rethrow()
        end
    end
    return
end

"""
    put_attachment(chain, path_or_io) -> String

Store the bytes of a file, or of a seekable IO standing at its start, as an attachment of
`chain` (ADR-0046), and return their SHA-256 in 64 lowercase hex — the `<h>` a row refers
to it by. The bytes are hashed first, then put at `[<prefix>/]_attachments/<h>`: on a
plain bucket by one streamed PUT, on a gateway bucket through the mint route. Already
present: nothing is uploaded, and on a gateway bucket its retention is extended. At most
5 GiB.

A retryable `TransportError` (a timeout, a `5xx`, a `409`, a `429`) runs the whole put again, up to
[`PUT_ATTEMPTS`](@ref) times; a put whose upload landed then finds it present. A failure
partway through an upload therefore sends the file again.

Raises [`AttachmentChangedError`](@ref) if the file changes between hashing and upload,
[`AttachmentURLExpiredError`](@ref), [`GatewaySessionEndingError`](@ref) (the gateway's
`503 session_ending`, not retried), [`WriteRefusedError`](@ref) and
[`GatewayMismatchError`](@ref) on a gateway bucket; an `ArgumentError` for a non-seekable
IO, an IO not at its start, a path that is not a file, or over 5 GiB.
"""
function put_attachment(chain::Chain, path::AbstractString)
    isdir(path) && throw(ArgumentError("put_attachment: $path is a directory, not a file"))
    isfile(path) || throw(ArgumentError("put_attachment: no file at $path"))
    return Base.open(io -> put_attachment(chain, io), path)
end

function put_attachment(chain::Chain, io::IO)
    (applicable(position, io) && applicable(seekend, io)) || throw(
        ArgumentError(
            "put_attachment takes a path or a " *
                "seekable IO; a $(typeof(io)) cannot seek, so it cannot be hashed before the upload (ADR-0046)"
        )
    )
    stream_size(io)                            # at its start, at most 5 GiB: checked before the bytes are read
    h = bytes2hex(sha256(io))
    key = attachment_key(chain, h)
    with_retries() do
        seekstart(io)
        put_attachment(chain.store, key, io)
    end
    return h
end

const ATTACHMENT_HASH = r"\A[0-9a-f]{64}\z"

function check_attachment_hash(h::AbstractString)
    occursin(ATTACHMENT_HASH, h) || throw(
        ArgumentError(
            "$(repr(h)) is not an attachment hash, the SHA-256 of its " *
                "bytes in 64 lowercase hex (ADR-0046)"
        )
    )
    return String(h)
end

"""
    touch_attachment(store, key) -> Bool

ADR-0046's reuse of a stored attachment: `false` when `store` lacks `key`, else `true`,
having extended its retention where the store keeps one. A HEAD first, so an absent
attachment fails and a gateway bucket's mint is given the size the present path needs.
"""
function touch_attachment(store::AbstractObjectStore, key::AbstractString)
    attachment_hash(key)
    return stat_object(store, key) !== nothing
end

function touch_attachment(store::GatewayObjectStore, key::AbstractString)
    key = String(key)
    attachment_hash(key)
    meta = stat_object(store.s3, key)
    meta === nothing && return false
    reply = mint(store, key, Int64(meta.size))
    reply.code == "present" && return true
    bucket = store.s3.bucket
    throw(
        GatewayMismatchError(
            "gateway mismatch: bucket $bucket holds the attachment $key, but the gateway at " *
                "$(store.function_url) found it absent and minted a URL to upload it, so it extended no retention. This " *
                "gateway fronts another bucket than the one this chain reads: pair the bucket with its own gateway, as one " *
                "ChainTables.Bucket value (ADR-0029, ADR-0046)."; key, bucket, gateway = store.function_url
        )
    )
end

"""
    touch_attachment(chain, hash) -> nothing

Before a row reuses an attachment of `chain` — one a row does not refer to for the first
time — extend its retention, so that the row never outlives it (ADR-0046). `hash` is its
SHA-256 in 64 lowercase hex, as [`put_attachment`](@ref) returned it.

A HEAD of the key in the chain's bucket, then on a gateway bucket the mint route with its
size, which finds it present and moves a locked bucket's retain-until later; a plain
bucket keeps no retention, so the HEAD is all. Retried as `put_attachment` is.

Raises [`AttachmentAbsentError`](@ref) when the store lacks it, [`WriteRefusedError`](@ref)
when the gateway refuses, and [`GatewayMismatchError`](@ref) when the gateway finds absent
what the chain's bucket holds; an `ArgumentError` for a hash that is not 64 lowercase hex.
"""
function touch_attachment(chain::Chain, h::AbstractString)
    h = check_attachment_hash(h)
    key = attachment_key(chain, h)
    with_retries(() -> touch_attachment(chain.store, key)) && return nothing
    throw(
        AttachmentAbsentError(
            "attachment absent: the store of the chain at $(location(chain)) holds no attachment " *
                "$key — it was never put, or its retention ended and it was deleted. A row cannot refer to it until it is put " *
                "again: put_attachment(chain, file) (ADR-0046)."; key
        )
    )
end

# ---------------------------------------------------------------------------
# The attachment cache (ADR-0046): `cache_dir/attachments/<h[1:2]>/<h>`, shared by every
# chain and bucket, read-only, with a sidecar `<h>.meta` holding "<size> <mtime>" that a
# read checks the file against. A copy records each hash its chain's store confirmed as
# an empty file `<copy>/confirmed/<h>`.
# ---------------------------------------------------------------------------

attachment_cache_path(cache::RecordCache, h::AbstractString) = joinpath(cache.dir, ATTACHMENT_CACHE_NAME, h[1:2], h)
sidecar_path(path::AbstractString) = path * ".meta"
confirmed_path(copy::LocalCopy, h::AbstractString) = joinpath(copy.path, "confirmed", h)
sidecar_text(st) = "$(st.size) $(st.mtime)"

# The cache entry at `path`: `:absent` when the file or its sidecar is missing — an
# interrupted fill, filled again — `:ok` when the file is what its sidecar records, else
# the sidecar's text, for the error.
function cache_entry(path::AbstractString)
    meta = sidecar_path(path)
    (isfile(path) && isfile(meta)) || return :absent
    recorded = read(meta, String)
    return sidecar_text(stat(path)) == recorded ? :ok : recorded
end

# Write the sidecar of `path` recording `st`: to a `.tmp`, renamed.
function write_sidecar(path::AbstractString, st)
    meta = sidecar_path(path)
    metatmp = "$meta.$(bytes2hex(rand(UInt8, 8))).tmp"
    try
        write(metatmp, sidecar_text(st))
        Base.Filesystem.rename(metatmp, meta)
    catch
        rm(metatmp; force = true)
        rethrow()
    end
    return nothing
end

# Heal the entry at `path`, whose file differs from its sidecar or has none: the file is
# hashed, and when it hashes to `h` its sidecar is rewritten from it — `:ok`. Two fills of
# one hash at once can pair one's sidecar with the other's file, and both files hashed
# right. The hash and the sidecar's size and mtime come from one open file, so a file
# renamed in meanwhile only leaves another mismatch, healed by the next read. A file whose
# size or mtime changed while it was hashed is `:changed`, whatever it hashed to: something
# other than ChainTables writes the read-only cache. `:absent` when the file is gone, else
# the hash the file has. `hasher` is for the tests.
function heal_entry(path::AbstractString, h::AbstractString; hasher = hash_file)
    io = try
        Base.open(path)
    catch e
        e isa SystemError && e.errnum == Libc.ENOENT && return :absent
        rethrow()
    end
    st, found, after = try
        (stat(io), bytes2hex(hasher(io)), stat(io))
    finally
        close(io)
    end
    sidecar_text(st) == sidecar_text(after) || return :changed
    found == h || return found
    write_sidecar(path, st)
    return :ok
end

function damaged_entry(chain_id, key, path, recorded, found)
    st = stat(path)
    return AttachmentCacheError(
        "attachment cache: the cached file $path is $(st.size) bytes modified at $(st.mtime) " *
            "and hashes to $found, not to its name; its sidecar $path.meta records $(repr(recorded)). The file was " *
            "changed after it was cached. The cache is damaged, not the chain: deleting $path and $path.meta is always " *
            "safe, and the next read fetches it again (ADR-0046)."; chain_id, key, path
    )
end

function changed_entry(chain_id, key, path)
    return AttachmentCacheError(
        "attachment cache: the cached file $path changed while it was being hashed, so " *
            "something other than ChainTables writes to this cache, which ChainTables keeps read-only: stop it. The cache " *
            "is damaged, not the chain: deleting $path and $path.meta is always safe, and the next read fetches it again " *
            "(ADR-0046)."; chain_id, key, path
    )
end

# A cache hit whose HEAD gives another size than the cached file's: one side is wrong, and
# hashing the cached file says which.
function size_mismatch(chain::Chain, chain_id, key, h, path, stored)
    cached = filesize(path)
    found = bytes2hex(hash_file(path))
    found == h && return AttachmentDigestError(
        "attachment digest: the store of the chain at $(location(chain)) holds " *
            "$stored bytes at $key, but the cached file $path, which hashes to the key's hash, is $cached bytes, so the " *
            "store's bytes cannot hash to it. Nothing was confirmed, and the cached file was kept. S3 checked the hash when " *
            "the attachment was stored, so the bucket was written from outside the protocol: stop and report it (ADR-0046).";
        chain_id, key, size = stored
    )
    return AttachmentCacheError(
        "attachment cache: the cached file $path is $cached bytes and hashes to $found, not to " *
            "its name, while the store of the chain at $(location(chain)) holds $stored bytes at $key. The cache is damaged, " *
            "not the chain: deleting $path and $path.meta is always safe, and the next read fetches it again (ADR-0046).";
        chain_id, key, path
    )
end

function absent_for_reader(chain::Chain, chain_id, key)
    return AttachmentAbsentError(
        "attachment absent: the store of the chain at $(location(chain)) holds no attachment " *
            "$key — it was never put to this chain, or its retention ended and it was deleted — so attachment(copy, hash) " *
            "has nothing to serve, whatever this machine has cached. Only someone holding the file can bring it back, with " *
            "put_attachment(chain, file) (ADR-0046)."; chain_id, key
    )
end

# Rename `from` onto `to`. Windows refuses to rename over a read-only file, so there the
# old one is removed first.
function replace_file(from::AbstractString, to::AbstractString)
    if Sys.iswindows() && isfile(to)
        chmod(to, 0o644)
        rm(to)
    end
    Base.Filesystem.rename(from, to)
    return nothing
end

"""
    fill_attachment!(chain, chain_id, key, h, path) -> Bool

Fetch the attachment at `key` into the cache at `path`: `false` when the store lacks it.
The download goes to `<h>.<16 hex>.part` beside `path`, is hashed against `h` —
[`AttachmentDigestError`](@ref) otherwise, with the download deleted — and made
read-only; then the sidecar is written (to a `.tmp`, renamed), and last the file is
renamed into place, which is the commit: a rename keeps the size and mtime the sidecar
records. An entry another process completed meanwhile is kept, and the download dropped.
Two processes filling one hash at once can still pair one's sidecar with the other's
file; the next read hashes the file and rewrites the sidecar (`heal_entry`).
"""
function fill_attachment!(chain::Chain, chain_id, key::String, h::String, path::String)
    dir = dirname(path)
    mkpath(dir)
    tmp = joinpath(dir, "$h.$(bytes2hex(rand(UInt8, 8))).part")
    try
        size = with_retries(() -> fetch_object_to(chain.store, key, tmp))
        size === nothing && return false
        found = bytes2hex(hash_file(tmp))
        found == h || throw(
            AttachmentDigestError(
                "attachment digest: the store of the chain at $(location(chain)) " *
                    "returned $size bytes for $key, which hash to $found, not to the key's hash. Nothing was cached. S3 checked " *
                    "the hash when the attachment was stored, so the bucket was written from outside the protocol: stop and " *
                    "report it (ADR-0046)."; chain_id, key, found, size
            )
        )
        cache_entry(path) === :ok && return true
        chmod(tmp, 0o444)
        write_sidecar(path, stat(tmp))
        replace_file(tmp, path)
    finally
        if isfile(tmp)
            chmod(tmp, 0o644)
            rm(tmp)
        end
    end
    return true
end

function confirm!(copy::LocalCopy, h::String)
    mkpath(joinpath(copy.path, "confirmed"))
    touch(confirmed_path(copy, h))
    return nothing
end

"""
    attachment(copy, hash) -> String

The path of the attachment `hash` of `copy`'s chain, a read-only file in the attachment
cache, `cache_dir/attachments/<h[1:2]>/<h>`, shared by every chain and bucket (ADR-0046).
Fetched on first use, never by `sync!`; nothing checks that a row of the copy refers to
the hash.

The cache serves a file while it matches its sidecar's size and mtime — it is not hashed
on every read; `verify(copy; full = true)` hashes it. A file that differs from its
sidecar is hashed: when it hashes to `hash` the sidecar is rewritten and the read goes
on, else it raises. A cached file does not stand
in for the chain's word: the first read of a hash through a copy HEADs its key in the
chain's store, even on a cache hit, and records it as confirmed in the copy
(`<copy>/confirmed/<h>`); a miss is confirmed by its download. The HEAD's size must be
the cached file's; when it is not, the file is hashed to say which side is wrong.
`verify(copy; full = true)`
and `repair!(copy)` cover the confirmed hashes. Requests are retried as
[`put_attachment`](@ref)'s are.

Raises [`AttachmentAbsentError`](@ref) when the chain's store lacks it,
[`AttachmentDigestError`](@ref) when the store's bytes do not hash to it — or, on a hit,
the store's size differs from a cached file that does — and
[`AttachmentCacheError`](@ref) when the cached file differs from its sidecar and does
not hash to its name, or changes while it is hashed, or, on a hit, differs in size from the store's and does not hash
to its name; an
`ArgumentError` for a copy with no head yet, or a hash that is not 64 lowercase hex.
"""
attachment(copy::LocalCopy, h::AbstractString) = read_attachment(copy, h)

# `attachment`'s body; `hasher` is for the tests.
function read_attachment(copy::LocalCopy, h::AbstractString; hasher = hash_file)
    check_open(copy)
    copy.head === nothing && throw(
        ArgumentError(
            "attachment(copy, hash): the local copy at $(copy.path) has no head " *
                "yet, so it belongs to no chain whose attachment it could read; sync!(copy) binds it"
        )
    )
    h = check_attachment_hash(h)
    chain = chain_of(copy, "attachment(copy, hash)")
    chain_id = copy.head.chain_id
    key = attachment_key(chain, h)
    path = attachment_cache_path(chain.cache, h)
    entry = cache_entry(path)
    if entry isa String
        healed = heal_entry(path, h; hasher)
        healed === :changed && throw(changed_entry(chain_id, key, path))
        healed isa String && throw(damaged_entry(chain_id, key, path, entry, healed))
        entry = healed
    end
    if entry === :ok
        isfile(confirmed_path(copy, h)) && return path
        meta = with_retries(() -> stat_object(chain.store, key))
        meta === nothing && throw(absent_for_reader(chain, chain_id, key))
        meta.size == filesize(path) || throw(size_mismatch(chain, chain_id, key, h, path, meta.size))
    else
        fill_attachment!(chain, chain_id, key, h, path) || throw(absent_for_reader(chain, chain_id, key))
    end
    confirm!(copy, h)
    return path
end

# ---------------------------------------------------------------------------
# verify and repair! over the attachments a copy confirmed (ADR-0046).
# ---------------------------------------------------------------------------

confirmed_hashes(copy::LocalCopy) = (
    d = joinpath(copy.path, "confirmed");
    isdir(d) ? sort!(filter(f -> occursin(ATTACHMENT_HASH, f), readdir(d))) : String[]
)

# What is wrong with the cache entry of `h`, hashing the file, or `nothing`. A file that
# hashes right is sound whatever its sidecar says: the next read rewrites the sidecar. An
# entry that is gone is not damage — deleting one is always safe, and the next read
# fetches it again.
function attachment_problem(cache::RecordCache, h::String)
    path = attachment_cache_path(cache, h)
    cache_entry(path) === :absent && return nothing
    found = bytes2hex(hash_file(path))
    found == h || return "$path hashes to $found, not its name"
    return nothing
end

# `verify(copy; full = true)`'s pass over the confirmed attachments: local, every file hashed.
function verify_attachments(copy::LocalCopy, chain::Chain)
    problems = String[]
    for h in confirmed_hashes(copy)
        problem = attachment_problem(chain.cache, h)
        problem === nothing || push!(problems, problem)
    end
    isempty(problems) && return nothing
    throw(
        AttachmentCacheError(
            "verify(copy; full = true): the attachment cache is damaged for attachments this copy " *
                "confirmed: $(join(problems, "; ")). The cache is damaged, not the chain: repair!(copy) fetches them again " *
                "(ADR-0046)."; chain_id = copy.head.chain_id
        )
    )
end

# `repair!(copy)`'s pass: an entry whose file hashes right gets its sidecar rewritten;
# any other — one that changed while it was hashed too — is removed and fetched again
# from the chain's store. Returns the count. A hash
# the store no longer holds cannot be repaired: the pass goes on, then, once it has run to
# its end, the markers of all such hashes are removed — the copy's word that the chain holds
# them no longer stands — and one `AttachmentAbsentError` names them, so the next `repair!`
# and `verify` pass instead of failing on them for ever. A pass that raises before its end
# has removed no marker, so the next `repair!` names them again.
function repair_attachments!(copy::LocalCopy, chain::Chain; hasher = hash_file)
    repaired = 0
    gone = String[]
    for h in confirmed_hashes(copy)
        path = attachment_cache_path(chain.cache, h)
        if cache_entry(path) === :ok
            bytes2hex(hash_file(path)) == h && continue
        elseif heal_entry(path, h; hasher) === :ok
            repaired += 1
            continue
        end
        rm(sidecar_path(path); force = true)
        isfile(path) && (chmod(path, 0o644); rm(path))
        key = attachment_key(chain, h)
        if fill_attachment!(chain, copy.head.chain_id, key, h, path)
            repaired += 1
        else
            push!(gone, h)
        end
    end
    isempty(gone) && return repaired
    foreach(h -> rm(confirmed_path(copy, h)), gone)
    throw(gone_from_store(chain, copy.head.chain_id, [attachment_key(chain, h) for h in gone]))
end

function gone_from_store(chain::Chain, chain_id, keys::Vector{String})
    one = length(keys) == 1
    return AttachmentAbsentError(
        "attachment absent: repair!(copy) found that the store of the chain at " *
            "$(location(chain)) no longer holds $(length(keys)) attachment$(one ? "" : "s") this copy had confirmed: " *
            "$(join(keys, ", ")). $(one ? "Its retention ended and it was" : "Their retention ended and they were") " *
            "deleted, or the bucket was written from outside the protocol. $(one ? "Its" : "Their") confirmed " *
            "marker$(one ? " was" : "s were") removed, so a read of one raises this again and verify no longer covers " *
            "$(one ? "it" : "them"); the rest of the repair ran. Only someone holding a file can bring it back, with " *
            "put_attachment(chain, file) (ADR-0046)."; chain_id, key = one ? only(keys) : nothing
    )
end
