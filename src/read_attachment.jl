const NOT_IN_STORE_FOR_READER = "it was never put to this chain, or its retention " *
    "ended and it was deleted, so there is nothing to serve, whatever this machine " *
    "has cached"

const CHANGED_WHILE_HASHED = "the cached file changed while it was hashed, so something " *
    "other than ChainTables writes to the attachment cache, which ChainTables keeps " *
    "read-only: stop it"

# The docstring is over 8 lines: when the store is asked, and what the cache vouches
# for, is the contract.
"""
    attachment(local_copy, hash)

Return the path of the attachment `hash` of the local copy's chain: a read-only file in
the attachment cache, shared by every chain and bucket.

The first read fetches it; `sync!` never does. Nothing checks that a row of the copy
refers to `hash`. The cache serves a file while it matches the size and mtime that its
sidecar records; `verify(local_copy; full = true)` hashes it. A cached file never stands
in for the chain's word: the first read of a hash through a local copy asks the chain's
store for it, even when the cache holds it, and the copy records it as confirmed.
Requests are retried as `put_attachment` retries them.

Throws `AttachmentAbsentError` when the chain's store lacks it, `AttachmentDigestError`
when the store's bytes do not fit the hash, and `AttachmentCacheError` when the cached
file does not hash to its name.

Examples: test/test_read_attachment_examples.jl
"""
attachment(local_copy::LocalCopy, h::AbstractString) = read_attachment(local_copy, h)

# `hasher`: only a test sets it, to change the file while it is hashed.
function read_attachment(local_copy::LocalCopy, h::AbstractString; hasher = hash_file)
    check_open(local_copy)
    local_copy.head === nothing && throw(
        ArgumentError(
            "attachment(copy, hash): the local copy at $(local_copy.path) has no head " *
                "yet, so it belongs to no chain whose attachment it could read; " *
                "sync!(copy) binds it"
        )
    )
    check_attachment_hash(h)
    chain = chain_of(local_copy, "attachment(copy, hash)")
    attachment = ChainAttachment(chain, local_copy.head.chain_id, h)
    if has_usable_entry(attachment; hasher)
        confirm_cached(local_copy, attachment)
    else
        fill_cache_entry(attachment) || throw(
            AttachmentAbsentError(attachment; detail = NOT_IN_STORE_FOR_READER)
        )
    end
    write_confirmed_marker(local_copy, attachment.hash)
    return attachment.path
end

# `true` when the cache holds a file that matches its sidecar, after a sidecar that
# disagrees with a file that hashes right is written again: two fills of one hash at
# once can pair one's sidecar with the other's file. `false` when the file or its
# sidecar is missing.
function has_usable_entry(attachment::ChainAttachment; hasher)
    path = attachment.path
    recorded = try_read_sidecar(path)
    recorded === nothing && return false
    sidecar_text(stat(path)) == recorded && return true
    hashed = hash_entry(path; hasher)
    hashed === nothing && return false
    hashed.is_stable ||
        throw(AttachmentCacheError(attachment; detail = CHANGED_WHILE_HASHED))
    hashed.found == attachment.hash || throw(
        AttachmentCacheError(
            attachment;
            detail = "the cached file is $(hashed.before.size) bytes modified at " *
                "$(hashed.before.mtime) and hashes to $(hashed.found), not to its name; " *
                "its sidecar records $(repr(recorded)), so it was changed after it was " *
                "cached",
        )
    )
    write_sidecar(path, hashed.before)
    return true
end

# The first read of a cached hash through a local copy asks the chain's store, which
# must hold the key at the cached file's size. When the sizes differ, hashing the
# cached file says which side is wrong.
function confirm_cached(local_copy::LocalCopy, attachment::ChainAttachment)
    isfile(confirmed_path(local_copy, attachment.hash)) && return nothing
    store = attachment.chain.store
    meta = with_retries(() -> stat_object(store, attachment.key))
    meta === nothing &&
        throw(AttachmentAbsentError(attachment; detail = NOT_IN_STORE_FOR_READER))
    cached = filesize(attachment.path)
    meta.size == cached && return nothing
    found = bytes2hex(hash_file(attachment.path))
    found == attachment.hash && throw(
        AttachmentDigestError(
            attachment; size = meta.size,
            detail = "the cached file hashes to the key's hash and is $cached bytes, so " *
                "the store's bytes cannot hash to it; the cached file was kept",
        )
    )
    throw(
        AttachmentCacheError(
            attachment;
            detail = "the cached file is $cached bytes and hashes to $found, not to its " *
                "name, while the store holds $(meta.size) bytes",
        )
    )
end
