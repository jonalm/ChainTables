"""
    AttachmentChangedError

Thrown when `put_attachment` sends bytes that do not hash to the hash in the
attachment's `key`: the file changed between hashing and upload.

`bucket` is the bucket that refused the bytes. Nothing was stored.
"""
Base.@kwdef struct AttachmentChangedError <: ChainTablesError
    bucket::Union{Nothing, String} = nothing
    key::Union{Nothing, String} = nothing
    detail::String = ""
end

function Base.showerror(io::IO, e::AttachmentChangedError)
    summary = "the file changed between hashing and upload, and S3 refused its bytes."
    print_summary(io, e, summary)
    print_evidence(io, e)
    print(io, "Nothing was stored. Stop whatever writes the file, then put the ")
    print(io, "attachment again.")
    return nothing
end

const URL_EXPIRED_NEXT_MOVES = Dict(
    :expired_before_upload => "Put the attachment again, which mints a new URL.",
    :outlasted => "Put the attachment again over a faster link.",
    :expired_early => "Put the attachment again. If this recurs, report it to the " *
        "bucket's operator: the gateway's clock or S3's is off.",
)

const URL_EXPIRED_NEXT_MOVE = "Put the attachment again, which mints a new URL."

"""
    AttachmentURLExpiredError

Thrown when `put_attachment` on a gateway bucket cannot finish its upload because the
URL that the gateway minted has expired.

`gateway` is the gateway's function URL and `expires` the time it gave, ISO 8601 in
UTC. `reason` is `:expired_before_upload` when this process waited past the URL's life
before it sent a byte, `:outlasted` when the upload was still running at the URL's end,
and `:expired_early` when S3 called the URL expired well before then. Nothing was
stored.
"""
Base.@kwdef struct AttachmentURLExpiredError <: ChainTablesError
    key::Union{Nothing, String} = nothing
    gateway::Union{Nothing, String} = nothing
    expires::Union{Nothing, String} = nothing
    reason::Union{Nothing, Symbol} = nothing
    detail::String = ""
end

function Base.showerror(io::IO, e::AttachmentURLExpiredError)
    summary = "the URL that the gateway minted expired before the upload was done."
    print_summary(io, e, summary)
    print_evidence(io, e)
    print(io, "Nothing was stored. ")
    print(io, get(URL_EXPIRED_NEXT_MOVES, e.reason, URL_EXPIRED_NEXT_MOVE))
    return nothing
end

"""
    AttachmentAbsentError

Thrown when the chain's object store holds no attachment at `key`: it was never put, or
its retention ended and it was deleted.

`touch_attachment` and `attachment` throw it for one key. `repair!(copy)` throws it
once after its pass, for every confirmed attachment that the object store no longer
holds; `key` is then set only when there is one. `chain_id` is `nothing` from
`touch_attachment`, which works on a `Chain`.
"""
Base.@kwdef struct AttachmentAbsentError <: ChainTablesError
    bucket::Union{Nothing, String} = nothing
    prefix::Union{Nothing, String} = nothing
    chain_id::Union{Nothing, String} = nothing
    key::Union{Nothing, String} = nothing
    detail::String = ""
end

function Base.showerror(io::IO, e::AttachmentAbsentError)
    print_summary(io, e, "the chain's object store does not hold the attachment.")
    print_evidence(io, e)
    print(io, "Whoever holds the file can put it again with ")
    print(io, "`put_attachment(chain, file)`.")
    return nothing
end

"""
    AttachmentDigestError

Thrown when the object store's bytes for an attachment do not fit the hash in its
`key`.

From a download, `size` bytes came back and hash to `found`; nothing was cached. On a
hit in the attachment cache, the object store reports `size` bytes, another size than
a cached file that hashes to its name; `found` is then `nothing`. It is not retried: S3
checked the hash when the attachment was stored.
"""
Base.@kwdef struct AttachmentDigestError <: ChainTablesError
    bucket::Union{Nothing, String} = nothing
    prefix::Union{Nothing, String} = nothing
    chain_id::Union{Nothing, String} = nothing
    key::Union{Nothing, String} = nothing
    found::Union{Nothing, String} = nothing
    size::Union{Nothing, Int64} = nothing
    detail::String = ""
end

function Base.showerror(io::IO, e::AttachmentDigestError)
    summary = "the object store's bytes for the attachment do not fit the hash in " *
        "its key."
    print_summary(io, e, summary)
    print_evidence(io, e)
    print(io, "The bucket was written from outside the protocol. Stop and report it.")
    return nothing
end

"""
    AttachmentCacheError

Thrown when `attachment` or `verify(copy; full = true)` finds a file of the attachment
cache that does not hash to its name, or that changed while it was hashed.

`path` is the cached file; `verify` names every such file in `detail`. The attachment
cache is damaged, not the chain.
"""
Base.@kwdef struct AttachmentCacheError <: ChainTablesError
    bucket::Union{Nothing, String} = nothing
    prefix::Union{Nothing, String} = nothing
    chain_id::Union{Nothing, String} = nothing
    key::Union{Nothing, String} = nothing
    path::Union{Nothing, String} = nothing
    detail::String = ""
end

function Base.showerror(io::IO, e::AttachmentCacheError)
    print_summary(io, e, "a file of the attachment cache does not hash to its name.")
    print_evidence(io, e)
    print(io, "Delete the file and its `.meta`, which is always safe; the next read ")
    print(io, "fetches it again. `repair!(copy)` does that for every confirmed ")
    print(io, "attachment.")
    return nothing
end
