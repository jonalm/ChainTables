"""
    AttachmentChangedError

S3 refused an attachment upload because the bytes sent do not hash to the key's
hash: the file changed between hashing and upload. Nothing was stored. Stop whatever
writes the file, and put it again.
"""
struct AttachmentChangedError <: ChainTablesError
    chain_id::MaybeString
    key::MaybeString
    detail::String
end

function AttachmentChangedError(; chain_id = nothing, key = nothing, detail = "")
    return AttachmentChangedError(chain_id, key, detail)
end

function Base.showerror(io::IO, e::AttachmentChangedError)
    print_summary(io, e, "the file changed between hashing and upload")
    print_evidence(io, e)
    print(io, "\nNothing was stored. Stop whatever writes the file, and put it again.")
    return nothing
end

"""
    AttachmentURLExpiredError

S3 refused an attachment upload because the URL the gateway minted had expired
(`expires`, ISO 8601 in UTC). Nothing was stored. Put the attachment again, which
mints a new URL; over a faster link if the upload outlasted the URL.
"""
struct AttachmentURLExpiredError <: ChainTablesError
    chain_id::MaybeString
    key::MaybeString
    expires::MaybeString
    detail::String
end

function AttachmentURLExpiredError(;
        chain_id = nothing, key = nothing, expires = nothing, detail = ""
    )
    return AttachmentURLExpiredError(chain_id, key, expires, detail)
end

function Base.showerror(io::IO, e::AttachmentURLExpiredError)
    print_summary(io, e, "the minted upload URL expired")
    print_evidence(io, e)
    print(
        io, "\nNothing was stored. Put the attachment again, which mints a new URL; ",
        "over a faster link if the upload outlasted the URL."
    )
    return nothing
end

"""
    GatewaySessionEndingError

The gateway answered the mint with `503 session_ending`: the environment that answered
is too old to sign a URL. Not retried, since the next request most likely meets the
same environment. Nothing was stored. Put the attachment again later.
"""
struct GatewaySessionEndingError <: ChainTablesError
    chain_id::MaybeString
    key::MaybeString
    gateway::MaybeString # the function URL
    detail::String
end

function GatewaySessionEndingError(;
        chain_id = nothing, key = nothing, gateway = nothing, detail = ""
    )
    return GatewaySessionEndingError(chain_id, key, gateway, detail)
end

function Base.showerror(io::IO, e::GatewaySessionEndingError)
    print_summary(io, e, "the gateway's session is ending, so it signs no URL")
    print_evidence(io, e)
    print(
        io, "\nNothing was stored. Put the attachment again later, once Lambda has ",
        "replaced the environment."
    )
    return nothing
end

"""
    AttachmentAbsentError

The chain's store holds no attachment at `key`: it was never put, or its retention
ended. Whoever holds the file puts it again with `put_attachment(chain, file)`.
"""
struct AttachmentAbsentError <: ChainTablesError
    chain_id::MaybeString
    key::MaybeString
    detail::String
end

function AttachmentAbsentError(; chain_id = nothing, key = nothing, detail = "")
    return AttachmentAbsentError(chain_id, key, detail)
end

function Base.showerror(io::IO, e::AttachmentAbsentError)
    print_summary(io, e, "the store holds no such attachment")
    print_evidence(io, e)
    print(io, "\nWhoever holds the file puts it again with `put_attachment(chain, file)`.")
    return nothing
end

"""
    AttachmentDigestError

The store returned `size` bytes for an attachment that do not hash to the key's hash
(`found`, `nothing` when nothing was downloaded). Nothing was cached. The bucket was
written outside the protocol: stop and report it.
"""
struct AttachmentDigestError <: ChainTablesError
    chain_id::MaybeString
    key::MaybeString
    found::MaybeString # hex SHA-256 of what was downloaded
    size::MaybeInt
    detail::String
end

function AttachmentDigestError(;
        chain_id = nothing, key = nothing, found = nothing, size = nothing, detail = ""
    )
    return AttachmentDigestError(chain_id, key, found, size, detail)
end

function Base.showerror(io::IO, e::AttachmentDigestError)
    print_summary(io, e, "the stored attachment does not hash to its key")
    print_evidence(io, e)
    print(io, "\nThe bucket was written outside the protocol; stop and report it.")
    return nothing
end

"""
    AttachmentCacheError

The attachment cache's file at `path` does not hash to its name. The cache is
damaged, not the chain. Delete the file and its `.meta`, which is always safe, or run
`repair!(copy)`.
"""
struct AttachmentCacheError <: ChainTablesError
    chain_id::MaybeString
    key::MaybeString
    path::MaybeString
    detail::String
end

function AttachmentCacheError(;
        chain_id = nothing, key = nothing, path = nothing, detail = ""
    )
    return AttachmentCacheError(chain_id, key, path, detail)
end

function Base.showerror(io::IO, e::AttachmentCacheError)
    print_summary(io, e, "the attachment cache's file does not hash to its name")
    print_evidence(io, e)
    print(
        io, "\nDelete the file and its `.meta` (always safe; the next read fetches it ",
        "again), or run `repair!(copy)`."
    )
    return nothing
end
