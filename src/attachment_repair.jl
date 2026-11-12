"""
    verify_attachments(copy, chain)

`verify(copy; full = true)`'s pass over the confirmed attachments of `copy`: local, every
cached file hashed. An entry that is gone is not damage: deleting one is always safe, and
the next read fetches it. Throws `AttachmentCacheError` naming each damaged file.
"""
function verify_attachments(copy::LocalCopy, chain::Chain)
    damaged = filter(hash -> is_damaged_entry(chain, hash), confirmed_hashes(copy))
    isempty(damaged) && return nothing
    paths = join(map(hash -> attachment_cache_path(chain, hash), damaged), ", ")
    detail = "$paths do not hash to their names"
    throw(AttachmentCacheError(; copy.head.chain_id, detail))
end

# Over 8 lines: what a pass that cannot finish leaves behind is the contract.
"""
    repair_attachments!(copy, chain; hasher = hash_file)

`repair!(copy)`'s pass over the confirmed attachments of `copy`: an entry whose file
hashes right gets its sidecar rewritten; any other is removed and fetched again from the
chain's store. Returns how many it repaired.

A hash the store no longer holds cannot be repaired. The pass goes on to its end; then the
confirmed markers of all such hashes are removed, so the next `repair!` and `verify` pass,
and one `AttachmentAbsentError` names them. A pass that throws before its end removes no
marker, so the next `repair!` names them again.
"""
# Test-only race injection: `hasher` replaces the hashing of a cached file, so a test can
# change the file while it is hashed.
function repair_attachments!(copy::LocalCopy, chain::Chain; hasher = hash_file)
    chain_id = copy.head.chain_id
    targets = map(hash -> cached_attachment(chain, chain_id, hash), confirmed_hashes(copy))
    # Outcomes are counted and filtered right here, so they stay Symbols.
    outcomes = map(target -> repair_entry(target; hasher), targets)
    gone = [target for (target, outcome) in zip(targets, outcomes) if outcome === :gone]
    isempty(gone) && return count(==(:repaired), outcomes)
    foreach(target -> rm(confirmed_path(copy, target.hash)), gone)
    key = length(gone) == 1 ? only(gone).key : nothing
    throw(AttachmentAbsentError(; chain_id, key, detail = gone_detail(gone)))
end

function confirmed_hashes(copy::LocalCopy)
    dir = joinpath(copy.path, "confirmed")
    isdir(dir) || return AttachmentHash[]
    names = filter(name -> occursin(ATTACHMENT_HASH, name), readdir(dir))
    return map(AttachmentHash, sort!(names))
end

function is_damaged_entry(chain::Chain, hash::AttachmentHash)
    path = attachment_cache_path(chain, hash)
    cache_entry(path) === :absent && return false
    return bytes2hex(hash_file(path)) != hash.hex
end

# `:sound`, `:repaired`, or `:gone` when the store no longer holds it.
function repair_entry(target::CachedAttachment; hasher)
    is_sound_entry(target) && return :sound
    is_healed_entry(target; hasher) && return :repaired
    remove_entry(target.path)
    return fetch_into_cache(target) ? :repaired : :gone
end

function is_sound_entry(target::CachedAttachment)
    cache_entry(target.path) === :ok || return false
    return bytes2hex(hash_file(target.path)) == target.hash.hex
end

function is_healed_entry(target::CachedAttachment; hasher)
    cache_entry(target.path) === :ok && return false
    return heal_entry(target.path, target.hash; hasher) === :ok
end

function remove_entry(path::AbstractString)
    rm(sidecar_path(path); force = true)
    isfile(path) && remove_read_only(path)
    return nothing
end

function gone_detail(gone)
    keys = join(map(target -> target.key, gone), ", ")
    return "the store no longer holds $(length(gone)) confirmed attachment(s), whose " *
        "markers were removed: $keys"
end
