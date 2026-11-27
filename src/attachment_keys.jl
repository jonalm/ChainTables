# S3's limit for one PUT, which is what carries an attachment: a multipart upload has no
# SHA-256 of the whole object (ADR-0046).
const ATTACHMENT_MAX_BYTES = 5 * 1024^3

const ATTACHMENT_HASH = r"\A[0-9a-f]{64}\z"

const ATTACHMENT_KEY = Regex("(?:\\A|/)" * ATTACHMENTS_SEGMENT * "/([0-9a-f]{64})\\z")

# S3's two words for bytes that do not hash as signed: `BadDigest` for the checksum
# header, `XAmzContentSHA256Mismatch` for a signed payload hash.
const BAD_DIGEST_CODE = r"<Code>(?:BadDigest|XAmzContentSHA256Mismatch)</Code>"

"""
    AttachmentUpload(key, io)

The bytes of `io` on their way to the attachment at `key`. `hash` is the SHA-256 that
the key names, and `size` the number of bytes that `io` holds.

Throws `ArgumentError` for a key that is not an attachment key, an `io` that does not
stand at its start, or more bytes than one S3 PUT takes.
"""
struct AttachmentUpload{I <: IO}
    key::String
    hash::String
    io::I
    size::Int64
end

function AttachmentUpload(key::AbstractString, io::IO)
    return AttachmentUpload(String(key), attachment_hash(key), io, stream_size(io))
end

# `[<prefix>/]_attachments/<hash>`, beside the chain's slots (ADR-0046).
function attachment_key(chain::Chain, h::AbstractString)
    name = ATTACHMENTS_SEGMENT * "/" * h
    return isempty(chain.prefix) ? name : chain.prefix * "/" * name
end

function attachment_hash(key::AbstractString)
    m = match(ATTACHMENT_KEY, key)
    m === nothing && throw(
        ArgumentError(
            "$(repr(key)) is not an attachment key, [<prefix>/]_attachments/<SHA-256 " *
                "in 64 lowercase hex>"
        )
    )
    return String(m[1])
end

function check_attachment_hash(h::AbstractString)
    occursin(ATTACHMENT_HASH, h) || throw(
        ArgumentError(
            "$(repr(h)) is not an attachment hash, the SHA-256 of its bytes in 64 " *
                "lowercase hex"
        )
    )
    return nothing
end

# libcurl rewinds an upload to offset 0, so a body that began further in would be sent
# wrong: `io` must stand at its start.
function stream_size(io::IO)
    start = position(io)
    start == 0 || throw(
        ArgumentError("an attachment's IO must stand at its start, not at byte $start")
    )
    size = position(seekend(io))
    seekstart(io)
    size <= ATTACHMENT_MAX_BYTES || throw(
        ArgumentError(
            "an attachment of $size bytes is over the $ATTACHMENT_MAX_BYTES bytes " *
                "(5 GiB) that one S3 PUT takes"
        )
    )
    return Int64(size)
end

checksum_sha256(h::AbstractString) = base64encode(hex2bytes(h))

function is_bad_digest(status::Integer, body::Vector{UInt8})
    status == 400 || return false
    return occursin(BAD_DIGEST_CODE, String(copy(body)))
end
