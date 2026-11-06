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
    m === nothing && throw(ArgumentError("$(repr(key)) is not an attachment key, [<prefix>/]_attachments/<SHA-256 in 64 " *
                                         "lowercase hex> (ADR-0046)"))
    return String(m.captures[1])
end

# The bytes `io` holds from its start, which must be where it stands: libcurl rewinds an
# upload to offset 0, so a body that began further in would be sent wrong.
function stream_size(io::IO)
    position(io) == 0 || throw(ArgumentError("an attachment's IO must stand at its start, not at byte $(position(io))"))
    size = position(seekend(io))
    seekstart(io)
    size <= ATTACHMENT_MAX_BYTES || throw(ArgumentError("an attachment of $size bytes is over the 5 GiB that one S3 PUT " *
        "takes ($ATTACHMENT_MAX_BYTES bytes; ADR-0046)"))
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
    req = request_headers(store, "PUT", key; payload_hash = h, content_length = size,
                          headers = ["content-type" => "application/octet-stream", "if-none-match" => "*",
                                     "x-amz-checksum-sha256" => checksum_sha256(h)])
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

changed(key, where) = AttachmentChangedError("attachment changed: the upload of $key to $where was refused as BadDigest — " *
    "the bytes sent do not hash to the key's SHA-256, so the file changed between hashing and upload. Nothing was " *
    "stored. Stop whatever writes the file, then put the attachment again (ADR-0046)."; key = String(key))

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
2. `minted`: the URL must be the chain's bucket on its regional host and the key's path —
   else [`GatewayMismatchError`](@ref), before a byte is sent.
3. A streamed PUT to it with exactly the reply's headers, following no redirect. `412`:
   another writer stored it first, and the mint is asked again, which must answer
   `present` and so extends the retention.
4. A HEAD of the key in this chain's bucket, which must hold it at this size — else
   [`GatewayMismatchError`](@ref): the gateway fills another bucket.

| reply | raised |
|---|---|
| mint `403`, or `502 s3_refused` | [`WriteRefusedError`](@ref), as for a slot |
| mint `400 bad_request` from a gateway that predates the route | [`WriteRefusedError`](@ref), `reason = "no_mint_route"`: redeploy it |
| mint `400`, `413` | `TransportError`, not retried |
| mint `409`, `429`, `5xx` (`503 session_ending` among them) | `TransportError`, retryable |
| upload `400 BadDigest` | [`AttachmentChangedError`](@ref) |
| upload `403` "Request has expired" | [`AttachmentURLExpiredError`](@ref) |
| any other upload status | `TransportError` carrying S3's code, the URL's signature left out |
"""
function put_attachment(store::GatewayObjectStore, key::AbstractString, io::IO)
    key = String(key)
    attachment_hash(key)
    size = stream_size(io)
    reply = mint(store, key, size)
    if reply.code == "minted"
        uploaded = upload_minted(store, key, io, reply)
        if !uploaded
            again = mint(store, key, size)
            again.code == "present" || throw(TransportError("POST $(store.function_url)/mint: S3 refused the upload of " *
                "$key as present (412), and the gateway's mint then found it absent and answered $(again.code); the " *
                "gateway and S3 disagree about its own bucket, which a retry cannot settle"; status = 200))
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
    query = Pair{String,String}["key" => key, "size" => string(size)]
    headers = signed_headers(current_credentials(store.s3), store.s3.region, "lambda", store.host, "POST", "/mint"; query)
    url = store.function_url * "/mint" * query_string(query)
    response = http_request(url, "POST", headers, UInt8[], store.timeout)
    status = response.status
    code, message = gateway_reply(response.body)
    if status == 200
        code == "present" && return (; code, url = nothing, expires = nothing, headers = nothing)
        code == "minted" && return minted_reply(url, response.body)
        throw(TransportError("POST $url: HTTP 200 with code $(repr(code)), neither present nor minted; this gateway " *
                             "speaks a mint route this client does not know"; status))
    end
    if status == 403 || code == "s3_refused"
        reason = something(code, "forbidden")
        throw(WriteRefusedError(refusal_message(store, key, reason, message); key, caller = store.author, reason))
    end
    if status == 400 && code == "bad_request" && message !== nothing && occursin("is not the gateway's one route", message)
        throw(WriteRefusedError("write refused: the gateway at $(store.function_url) has no mint route, so it cannot " *
            "store the attachment $key — it answered POST /mint with bad_request: $message. It was deployed before " *
            "attachments (ADR-0046): ask the bucket's operator to redeploy it (gateway/deploy.sh)."; key,
            reason = "no_mint_route"))
    end
    detail = code === nothing ? "" : " " * code * (message === nothing ? "" : ": " * message)
    throw(TransportError("POST $url: HTTP $status$detail"; status))    # 409, 429 and 5xx — session_ending among them — are retryable
end

# One `"name": "value"` of a minted reply's `headers`: a lowercase name, and a value of
# printable ASCII with no quote or backslash, so it needs no unescaping (ADR-0046).
const MINTED_HEADER = r"\"([a-z0-9-]+)\"\s*:\s*\"([\x20\x21\x23-\x5b\x5d-\x7e]*)\""
const MINTED_HEADERS = Regex("\\A\\s*(?:" * MINTED_HEADER.pattern * "\\s*(?:,\\s*(?=\")|\\z))*\\z")

# `url`, `expires` and the flat `headers` object of a `minted` reply, read without a JSON
# parser (ADR-0027) and strictly: a reply this cannot read is refused, never guessed at.
function minted_reply(url, body::Vector{UInt8})
    text = String(copy(body))
    unreadable(what) = TransportError("POST $url: the gateway's minted reply has $what: $(first(text, 500))"; status = 200)
    field(name) = (m = match(Regex("\"$name\"\\s*:\\s*\"((?:[^\"\\\\]|\\\\.)*)\""), text);
                   m === nothing ? throw(unreadable("no \"$name\"")) : json_unescape(m.captures[1]))
    minted_url, expires = field("url"), field("expires")
    object = match(r"\"headers\"\s*:\s*\{([^{}]*)\}", text)
    object === nothing && throw(unreadable("no \"headers\" object"))
    inner = object.captures[1]
    occursin(MINTED_HEADERS, inner) ||
        throw(unreadable("a \"headers\" object that is not a flat map of lowercase names to plain ASCII strings"))
    headers = Pair{String,String}[String(m.captures[1]) => String(m.captures[2]) for m in eachmatch(MINTED_HEADER, inner)]
    isempty(headers) && throw(unreadable("an empty \"headers\" object"))
    return (; code = "minted", url = minted_url, expires, headers)
end

# Where a minted URL must point (ADR-0046, ADR-0029): the chain's bucket on its regional
# host, virtual-hosted — what the gateway presigns — whatever addressing the reads use;
# a configured endpoint (a test's loopback) is the S3 half's own object URL.
function expected_attachment_url(store::GatewayObjectStore, key::AbstractString)
    s3 = store.s3
    s3.endpoint === nothing || return s3.base * object_path(s3, key)
    return "https://$(s3.bucket).s3.$(s3.region).amazonaws.com/" * uri_encode(key; keep_slash = true)
end

# The URL with its query — the signature, a bearer credential until it expires — left out.
bare_url(url::AbstractString) = first(split(url, '?'; limit = 2))

# The streamed PUT to a minted URL: `true` when stored, `false` on `412`.
function upload_minted(store::GatewayObjectStore, key::String, io::IO, reply)
    expected = expected_attachment_url(store, key)
    where = bare_url(reply.url)
    (where == expected && length(reply.url) > length(where)) || throw(GatewayMismatchError("gateway mismatch: the gateway " *
        "at $(store.function_url) minted a URL for $key at $where, not at $expected, the attachment's place in bucket " *
        "$(store.s3.bucket) on its regional host. Nothing was sent. This gateway fronts another bucket or region than " *
        "the one this chain reads: pair the bucket with its own gateway, as one ChainTables.Bucket value (ADR-0029, " *
        "ADR-0046)."; key, bucket = store.s3.bucket, gateway = store.function_url))
    output = IOBuffer()
    response = http_stream(reply.url, "PUT", reply.headers; input = io, output, stall = store.timeout)
    response.status == 200 && return true
    response.status == 412 && return false
    body = take!(output)
    bad_digest(response.status, body) && throw(changed(key, where))
    if response.status == 403 && occursin("Request has expired", String(copy(body)))
        throw(AttachmentURLExpiredError("attachment URL expired: S3 refused the upload of $key to $where because the " *
            "URL the gateway minted had expired (it gave $(reply.expires)) before the upload began. Nothing was stored. " *
            "Put the attachment again, which mints a new URL; if this recurs, check this machine's clock (ADR-0046).";
            key, expires = reply.expires))
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
    throw(GatewayMismatchError("gateway mismatch: the gateway at $(store.function_url) has stored the attachment $key, " *
        "and bucket $bucket $(meta === nothing ? "does not hold it" : "holds $(meta.size) bytes there, not $size"): this " *
        "gateway fronts another bucket than the one this chain reads. Pair the bucket with its own gateway — one " *
        "ChainTables.Bucket value holds both (ADR-0029) — and put the attachment again."; key, bucket,
        gateway = store.function_url))
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
        attempt == 1 || sleep(PUT_BACKOFF_S[attempt-1])
        try
            return f()
        catch e
            (retryable(e) && attempt < PUT_ATTEMPTS) || rethrow()
        end
    end
end

"""
    put_attachment(chain, path_or_io) -> String

Store the bytes of a file, or of a seekable IO standing at its start, as an attachment of
`chain` (ADR-0046), and return their SHA-256 in 64 lowercase hex — the `<h>` a row refers
to it by. The bytes are hashed first, then put at `[<prefix>/]_attachments/<h>`: on a
plain bucket by one streamed PUT, on a gateway bucket through the mint route. Already
present: nothing is uploaded, and on a gateway bucket its retention is extended. At most
5 GiB.

A retryable `TransportError` (a timeout, a `5xx` — the gateway's `503 session_ending`
among them — a `409`, a `429`) runs the whole put again, up to
[`PUT_ATTEMPTS`](@ref) times; a put whose upload landed then finds it present. A failure
partway through an upload therefore sends the file again.

Raises [`AttachmentChangedError`](@ref) if the file changes between hashing and upload,
[`AttachmentURLExpiredError`](@ref), [`WriteRefusedError`](@ref) and
[`GatewayMismatchError`](@ref) on a gateway bucket; an `ArgumentError` for a non-seekable
IO, an IO not at its start, a path that is not a file, or over 5 GiB.
"""
function put_attachment(chain::Chain, path::AbstractString)
    isdir(path) && throw(ArgumentError("put_attachment: $path is a directory, not a file"))
    isfile(path) || throw(ArgumentError("put_attachment: no file at $path"))
    return Base.open(io -> put_attachment(chain, io), path)
end

function put_attachment(chain::Chain, io::IO)
    (applicable(position, io) && applicable(seekend, io)) || throw(ArgumentError("put_attachment takes a path or a " *
        "seekable IO; a $(typeof(io)) cannot seek, so it cannot be hashed before the upload (ADR-0046)"))
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
    occursin(ATTACHMENT_HASH, h) || throw(ArgumentError("$(repr(h)) is not an attachment hash, the SHA-256 of its " *
                                                        "bytes in 64 lowercase hex (ADR-0046)"))
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
    throw(GatewayMismatchError("gateway mismatch: bucket $bucket holds the attachment $key, but the gateway at " *
        "$(store.function_url) found it absent and minted a URL to upload it, so it extended no retention. This " *
        "gateway fronts another bucket than the one this chain reads: pair the bucket with its own gateway, as one " *
        "ChainTables.Bucket value (ADR-0029, ADR-0046)."; key, bucket, gateway = store.function_url))
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
    throw(AttachmentAbsentError("attachment absent: the store of the chain at $(location(chain)) holds no attachment " *
        "$key — it was never put, or its retention ended and it was deleted. A row cannot refer to it until it is put " *
        "again: put_attachment(chain, file) (ADR-0046)."; key))
end
