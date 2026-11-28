# The docstring is over 8 lines: what is hashed, sent and retried is the contract.
"""
    put_attachment(chain, path)
    put_attachment(chain, io)

Store the bytes of the file at `path`, or of `io`, as an attachment of `chain`, and
return their SHA-256 in 64 lowercase hex: the hash that a row refers to it by.

`io` must be seekable and stand at its start. An attachment is at most 5 GiB. The
bytes are hashed first, then put at `[<prefix>/]_attachments/<hash>`: on a plain bucket
by one streamed PUT, on a gateway bucket through the mint route. An attachment that the
bucket holds already is not sent again; on a gateway bucket its retention is extended.
A failure that may pass runs the whole put again, up to 4 attempts in all, so a
failure partway through sends the bytes again.

Throws `AttachmentChangedError` when the file changes between hashing and upload. On a
gateway bucket it also throws `AttachmentURLExpiredError`, `GatewaySessionEndingError`,
`WriteRefusedError` and `GatewayMismatchError`.

Examples: test/test_put_attachment_examples.jl
"""
function put_attachment(chain::Chain, path::AbstractString)
    isdir(path) && throw(ArgumentError("put_attachment: $path is a directory, not a file"))
    isfile(path) || throw(ArgumentError("put_attachment: no file at $path"))
    return Base.open(io -> put_attachment(chain, io), path)
end

function put_attachment(chain::Chain, io::IO)
    is_seekable(io) || throw(
        ArgumentError(
            "put_attachment takes a path or a seekable IO; a $(typeof(io)) cannot " *
                "seek, so it cannot be hashed before the upload"
        )
    )
    stream_size(io)  # before the bytes are read: at its start, and at most 5 GiB
    h = bytes2hex(sha256(io))
    key = attachment_key(chain, h)
    with_retries(() -> upload_attachment(chain.store, key, seekstart(io)))
    return h
end

is_seekable(io::IO) = applicable(position, io) && applicable(seekend, io)

# The bounded retry of a whole call to the store, with the commit's constants
# (ADR-0010). Safe because each call is idempotent: a put whose upload landed finds the
# key present.
function with_retries(f)
    for attempt in 1:(PUT_ATTEMPTS - 1)
        try
            return f()
        catch e
            e isa TransportError || rethrow()
            is_retryable(e) || rethrow()
        end
        sleep(PUT_BACKOFF_SECONDS[attempt])
    end
    return f()
end

"""
    upload_attachment(store, key, io)

Stream the bytes of `io`, a seekable IO at its start, to the attachment at `key`. Return
`true` when this call stored them and `false` when the store held the key already.

The store checks the bytes against the hash in the key, and throws
`AttachmentChangedError` with nothing stored when they do not match. A store of the
user's own needs a method only if it holds attachments.
"""
function upload_attachment end

# One streamed PUT with the checksum and `If-None-Match: *` (ADR-0046). The signed
# payload hash is the key's own.
function upload_attachment(store::S3ObjectStore, key::AbstractString, io::IO)
    upload = AttachmentUpload(key, io)
    headers = [
        "content-type" => "application/octet-stream", "if-none-match" => "*",
        "x-amz-checksum-sha256" => checksum_sha256(upload.hash),
    ]
    request = request_headers(
        store, "PUT", upload.key; payload_hash = upload.hash,
        content_length = upload.size, headers,
    )
    output = IOBuffer()
    response = http_stream(
        "PUT", request.url; request.headers, input = io, output, stall = store.timeout
    )
    status, body = response.status, take!(output)
    status == 200 && return true
    status == 412 && return false
    is_bad_digest(status, body) &&
        throw(AttachmentChangedError(; store.bucket, upload.key))
    throw(TransportError("PUT", object_url(store, upload.key), (; status, body)))
end
