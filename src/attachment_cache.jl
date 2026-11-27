"""
    ChainAttachment(chain, chain_id, hash)

One attachment of a chain: its key in the chain's store, and its file in the attachment
cache, `cache_dir/attachments/<hash[1:2]>/<hash>`. The attachment errors report its
fields.
"""
struct ChainAttachment{C <: Chain}
    chain::C
    chain_id::String
    hash::String
    key::String
    path::String  # the file in the attachment cache
end

function ChainAttachment(chain::Chain, chain_id::AbstractString, h::AbstractString)
    key = attachment_key(chain, h)
    path = attachment_cache_path(chain.cache, h)
    return ChainAttachment(chain, String(chain_id), String(h), key, path)
end

function AttachmentAbsentError(attachment::ChainAttachment; detail)
    chain = attachment.chain
    return AttachmentAbsentError(;
        chain.bucket, chain.prefix, attachment.chain_id, attachment.key, detail
    )
end

function AttachmentDigestError(attachment::ChainAttachment; found = nothing, size, detail)
    chain = attachment.chain
    return AttachmentDigestError(;
        chain.bucket, chain.prefix, attachment.chain_id, attachment.key, found, size,
        detail,
    )
end

function AttachmentCacheError(attachment::ChainAttachment; detail)
    chain = attachment.chain
    return AttachmentCacheError(;
        chain.bucket, chain.prefix, attachment.chain_id, attachment.key,
        attachment.path, detail,
    )
end

function attachment_cache_path(cache::RecordCache, h::AbstractString)
    return joinpath(cache.dir, ATTACHMENT_CACHE_NAME, h[1:2], h)
end

# The sidecar records the size and mtime of the file beside it, which a read checks
# the file against in place of its hash (ADR-0046).
sidecar_path(path::AbstractString) = path * ".meta"
sidecar_text(st) = "$(st.size) $(st.mtime)"

# `nothing` when the file or its sidecar is missing: an interrupted fill, filled again.
function try_read_sidecar(path::AbstractString)
    meta = sidecar_path(path)
    (isfile(path) && isfile(meta)) || return nothing
    return read(meta, String)
end

function is_matching_entry(path::AbstractString)
    recorded = try_read_sidecar(path)
    recorded === nothing && return false
    return sidecar_text(stat(path)) == recorded
end

# The file at `path`, hashed with the stat that it had before and after: `nothing` when
# it is gone. A file renamed onto the path meanwhile leaves the stat of the file that
# was hashed, since all three come from one open file.
function hash_entry(path::AbstractString; hasher)
    try
        return Base.open(io -> hashed_entry(io, hasher), path)
    catch e
        e isa SystemError || rethrow()
        e.errnum == Libc.ENOENT || rethrow()
        return nothing
    end
end

function hashed_entry(io::IO, hasher)
    before = stat(io)
    found = bytes2hex(hasher(io))
    after = stat(io)
    return (; before, found, is_stable = sidecar_text(before) == sidecar_text(after))
end

function write_sidecar(path::AbstractString, st)
    meta = sidecar_path(path)
    temporary = "$meta.$(bytes2hex(rand(UInt8, 8))).tmp"
    _is_renamed = false
    try
        write(temporary, sidecar_text(st))
        Base.Filesystem.rename(temporary, meta)
        _is_renamed = true
    finally
        _is_renamed || rm(temporary; force = true)
    end
    return nothing
end

# Download the attachment into the cache: `false` when the store lacks it. The
# download goes to a `.part` file beside the entry, is hashed, made read-only, and
# renamed into place after its sidecar is written: the rename is the commit, and keeps
# the size and mtime that the sidecar records. An entry that another process completed
# meanwhile is kept. Two fills of one hash at once can still pair one's sidecar with
# the other's file; the next read hashes the file and rewrites the sidecar.
function fill_cache_entry(attachment::ChainAttachment)
    dir = dirname(attachment.path)
    mkpath(dir)
    part = joinpath(dir, "$(attachment.hash).$(bytes2hex(rand(UInt8, 8))).part")
    try
        return fetch_into_cache(attachment, part)
    finally
        remove_cached_file(part)
    end
end

function fetch_into_cache(attachment::ChainAttachment, part::String)
    store = attachment.chain.store
    size = with_retries(() -> fetch_object_to(store, attachment.key, part))
    size === nothing && return false
    found = bytes2hex(hash_file(part))
    found == attachment.hash || throw(
        AttachmentDigestError(
            attachment; found, size,
            detail = "the download does not hash to the key's hash; nothing was cached",
        )
    )
    is_matching_entry(attachment.path) && return true
    chmod(part, 0o444)
    write_sidecar(attachment.path, stat(part))
    replace_file(part, attachment.path)
    return true
end

# Windows refuses to rename onto a read-only file, so there the old one goes first.
function replace_file(from::AbstractString, to::AbstractString)
    Sys.iswindows() && remove_cached_file(to)
    Base.Filesystem.rename(from, to)
    return nothing
end

# A cached file is read-only.
function remove_cached_file(path::AbstractString)
    isfile(path) || return nothing
    chmod(path, 0o644)
    rm(path)
    return nothing
end

function confirmed_path(local_copy::LocalCopy, h::AbstractString)
    return joinpath(local_copy.path, "confirmed", h)
end

function write_confirmed_marker(local_copy::LocalCopy, h::AbstractString)
    mkpath(joinpath(local_copy.path, "confirmed"))
    touch(confirmed_path(local_copy, h))
    return nothing
end
