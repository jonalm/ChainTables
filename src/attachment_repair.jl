function confirmed_hashes(local_copy::LocalCopy)
    dir = joinpath(local_copy.path, "confirmed")
    isdir(dir) || return String[]
    return sort!(filter(name -> occursin(ATTACHMENT_HASH, name), readdir(dir)))
end

# `verify(local_copy; full = true)`'s pass over the confirmed attachments: local, every
# cached file hashed. A file that hashes right is sound whatever its sidecar says, and
# an entry that is gone is not damage: the next read fetches it.
function verify_attachments(local_copy::LocalCopy, chain::Chain)
    hashes = confirmed_hashes(local_copy)
    damaged = filter(h -> is_damaged_entry(attachment_cache_path(chain.cache, h)), hashes)
    isempty(damaged) && return nothing
    paths = [attachment_cache_path(chain.cache, h) for h in damaged]
    throw(
        AttachmentCacheError(;
            chain.bucket, chain.prefix, local_copy.head.chain_id,
            detail = "verify(copy; full = true) found cached files that do not hash to " *
                "their names: $(join(paths, ", "))",
        )
    )
end

function is_damaged_entry(path::String)
    try_read_sidecar(path) === nothing && return false
    return bytes2hex(hash_file(path)) != basename(path)
end

# `repair!(local_copy)`'s pass. A file that hashes right gets its sidecar written again;
# any other entry is removed and fetched again from the chain's store. Returns the
# count. A hash that the store no longer holds cannot be repaired: the pass goes on,
# and once it has run to its end, the markers of all such hashes are removed (the
# copy's word that the chain holds them no longer stands) and one error names them. A
# pass that throws before its end removes no marker, so the next one names them again.
# `hasher`: only a test sets it, to change a file while it is hashed.
function repair_attachments!(local_copy::LocalCopy, chain::Chain; hasher = hash_file)
    pass = repair_entries(local_copy, chain; hasher)
    gone = pass.gone
    isempty(gone) && return pass.repaired
    foreach(h -> rm(confirmed_path(local_copy, h)), gone)
    gone_keys = [attachment_key(chain, h) for h in gone]
    listed = join(gone_keys, ", ")
    throw(
        AttachmentAbsentError(;
            chain.bucket, chain.prefix, local_copy.head.chain_id,
            key = length(gone_keys) == 1 ? only(gone_keys) : nothing,
            detail = "repair!(copy) found that the store no longer holds these " *
                "attachments that the copy had confirmed: $listed. Their " *
                "confirmed markers were removed, and the rest of the repair ran",
        )
    )
end

# The count of entries repaired, and the hashes that the store no longer holds.
function repair_entries(local_copy::LocalCopy, chain::Chain; hasher)
    repaired = 0
    gone = String[]
    for h in confirmed_hashes(local_copy)
        attachment = ChainAttachment(chain, local_copy.head.chain_id, h)
        is_sound_entry(attachment) && continue
        if heal_sidecar(attachment; hasher) || fetch_attachment_again(attachment)
            repaired += 1
        else
            push!(gone, h)
        end
    end
    return (; repaired, gone)
end

function is_sound_entry(attachment::ChainAttachment)
    is_matching_entry(attachment.path) || return false
    return bytes2hex(hash_file(attachment.path)) == attachment.hash
end

# `true` when the cached file hashes right, and its sidecar was written again.
function heal_sidecar(attachment::ChainAttachment; hasher)
    hashed = hash_entry(attachment.path; hasher)
    hashed === nothing && return false
    (hashed.is_stable && hashed.found == attachment.hash) || return false
    write_sidecar(attachment.path, hashed.before)
    return true
end

# `false` when the store no longer holds the attachment.
function fetch_attachment_again(attachment::ChainAttachment)
    rm(sidecar_path(attachment.path); force = true)
    remove_cached_file(attachment.path)
    return fill_cache_entry(attachment)
end
