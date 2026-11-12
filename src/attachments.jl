# S3's limit for one PUT, which is what carries an attachment: a multipart upload has no
# SHA-256 of the whole object (ADR-0046).
const ATTACHMENT_MAX_BYTES = 5 * 1024^3

const ATTACHMENT_HASH = r"\A[0-9a-f]{64}\z"
const ATTACHMENT_KEY = r"(?:\A|/)_attachments/([0-9a-f]{64})\z"

# S3's two words for bytes that do not hash as signed: `BadDigest` for the checksum header,
# `XAmzContentSHA256Mismatch` for a signed payload hash, which a direct PUT also sends.
const BAD_DIGEST_CODE = r"<Code>(?:BadDigest|XAmzContentSHA256Mismatch)</Code>"

"""
    AttachmentHash(hex)

The SHA-256 of an attachment's bytes, in 64 lowercase hex: what names it in its key, in
the attachment cache and in a row. Throws `ArgumentError` for any other text.
"""
struct AttachmentHash
    hex::String
    function AttachmentHash(hex)
        occursin(ATTACHMENT_HASH, hex) || throw(
            ArgumentError(
                "$(repr(hex)) is not an attachment hash, the SHA-256 of its bytes in 64 " *
                    "lowercase hex"
            )
        )
        return new(String(hex))
    end
end

Base.:(==)(a::AttachmentHash, b::AttachmentHash) = a.hex == b.hex
Base.hash(h::AttachmentHash, seed::UInt) = hash(h.hex, hash(:AttachmentHash, seed))

# Over 8 lines: one docstring covers the chain form, the store form implementers provide,
# and the errors a caller must handle.
"""
    put_attachment(chain, path)
    put_attachment(chain, io)
    put_attachment(store, key, io)

Store the bytes of a file, or of a seekable IO at its start, as an attachment of `chain`,
and return their SHA-256 in 64 lowercase hex: the hash a row refers to it by.

The bytes are hashed, then put at `[<prefix>/]_attachments/<hash>`: on a plain bucket by
one streamed PUT, on a gateway bucket through the mint route. An attachment already
present is not uploaded again; on a gateway bucket its retention is extended. At most
5 GiB. A retryable `TransportError` runs the whole put again, up to 4 attempts.

Throws `AttachmentChangedError` when the file changes between hashing and upload, and on
a gateway bucket `AttachmentURLExpiredError`, `GatewaySessionEndingError`,
`WriteRefusedError` and `GatewayMismatchError`.

The store form is what an `AbstractObjectStore` that holds attachments implements: store
the bytes of `io` at `key` unless present, refuse bytes that do not hash to the key's
hash, and return `true` when this call stored them.

Examples: test/test_attachments_examples.jl
"""
function put_attachment end

# Over 8 lines: one docstring covers the chain form, the store form and the errors.
"""
    touch_attachment(chain, hash)
    touch_attachment(store, key)

Extend the retention of the attachment `hash` of `chain` before a row reuses it, so the
row never outlives it.

A HEAD of its key in the chain's bucket; then, on a gateway bucket, the mint route, which
finds it present and moves a locked bucket's retain-until later. A plain bucket keeps no
retention, so the HEAD is all. Retried as `put_attachment` is. Throws
`AttachmentAbsentError` when the store lacks it, and on a gateway bucket
`WriteRefusedError` and `GatewayMismatchError`.

The store form returns `false` when `store` lacks `key`, else `true`.

Examples: test/test_attachments_examples.jl
"""
function touch_attachment end

function put_attachment(chain::Chain, path::AbstractString)
    isdir(path) && throw(ArgumentError("put_attachment: $path is a directory, not a file"))
    isfile(path) || throw(ArgumentError("put_attachment: no file at $path"))
    return Base.open(io -> put_attachment(chain, io), path)
end

function put_attachment(chain::Chain, io::IO)
    applicable(position, io) && applicable(seekend, io) || throw(
        ArgumentError(
            "put_attachment takes a path or a seekable IO; a $(typeof(io)) cannot seek, " *
                "so it cannot be hashed before the upload"
        )
    )
    # At its start and at most 5 GiB, checked before the bytes are read.
    stream_size(io)
    hash = AttachmentHash(bytes2hex(sha256(io)))
    key = attachment_key(chain, hash)
    # Safe to repeat: a put whose upload landed finds the key present.
    with_retries() do
        seekstart(io)
        put_attachment(chain.store, key, io)
    end
    return hash.hex
end

function touch_attachment(chain::Chain, hex::AbstractString)
    key = attachment_key(chain, AttachmentHash(hex))
    with_retries(() -> touch_attachment(chain.store, key)) && return nothing
    throw(AttachmentAbsentError(; key, detail = "the store of $(location(chain)) lacks it"))
end

function put_attachment(store::S3ObjectStore, key::AbstractString, io::IO)
    hash = attachment_hash(key)
    size = stream_size(io)
    headers = [
        "content-type" => "application/octet-stream", "if-none-match" => "*",
        "x-amz-checksum-sha256" => checksum_sha256(hash.hex),
    ]
    req = request_headers(
        store, "PUT", key; payload_hash = hash.hex, content_length = size, headers
    )
    output = IOBuffer()
    stall = store.timeout
    response = http_stream(req.url, "PUT", req.headers; input = io, output, stall)
    response.status == 200 && return true
    response.status == 412 && return false
    body = take!(output)
    url = store.base * object_path(store, key)
    detail = "S3 at $url answered BadDigest"
    is_bad_digest(response.status, body) &&
        throw(AttachmentChangedError(; key = String(key), detail))
    throw(failure("PUT", url, (; response.status, body)))
end

function touch_attachment(store::AbstractObjectStore, key::AbstractString)
    attachment_hash(key)
    return stat_object(store, key) !== nothing
end

"""
    attachment_key(chain, hash)

The key of the attachment `hash` (an `AttachmentHash` or its hex) under `chain`'s prefix,
`[<prefix>/]_attachments/<hash>`.
"""
function attachment_key(chain::Chain, hash::AttachmentHash)
    return isempty(chain.prefix) ? "_attachments/" * hash.hex :
        chain.prefix * "/_attachments/" * hash.hex
end

# test/live passes the hex.
function attachment_key(chain::Chain, hex::AbstractString)
    return attachment_key(chain, AttachmentHash(hex))
end

# Anything but an attachment key, `[<prefix>/]_attachments/<hash>`, is a caller's bug.
function attachment_hash(key::AbstractString)
    m = match(ATTACHMENT_KEY, key)
    m === nothing && throw(
        ArgumentError(
            "$(repr(key)) is not an attachment key, [<prefix>/]_attachments/<SHA-256 in " *
                "64 lowercase hex>"
        )
    )
    return AttachmentHash(m.captures[1])
end

# libcurl rewinds an upload to offset 0, so a body that began further in would be sent
# wrong: `io` must stand at its start.
function stream_size(io::IO)
    at = position(io)
    at == 0 ||
        throw(ArgumentError("an attachment's IO must stand at its start, not at byte $at"))
    size = position(seekend(io))
    seekstart(io)
    size <= ATTACHMENT_MAX_BYTES || throw(
        ArgumentError(
            "an attachment of $size bytes is over the 5 GiB " *
                "($ATTACHMENT_MAX_BYTES bytes) that one S3 PUT takes"
        )
    )
    return Int64(size)
end

checksum_sha256(hex::AbstractString) = Base64.base64encode(hex2bytes(hex))

is_bad_digest(status, body) = status == 400 && occursin(BAD_DIGEST_CODE, String(copy(body)))

# The bounded retry of a whole store call, the commit's: re-issued on a retryable
# `TransportError`, the last failure rethrown (ADR-0010). One sleep between attempts, so
# PUT_ATTEMPTS attempts in all.
function with_retries(f)
    for backoff in PUT_BACKOFF_S[1:(PUT_ATTEMPTS - 1)]
        try
            return f()
        catch e
            e isa TransportError || rethrow()
            retryable(e) || rethrow()
        end
        sleep(backoff)
    end
    return f()
end
