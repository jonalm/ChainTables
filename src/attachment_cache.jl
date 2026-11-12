"""
    CachedAttachment

One attachment of one chain and its file in the attachment cache: what a read, a fetch or
a repair of it needs. Build one with `cached_attachment`.
"""
struct CachedAttachment{C <: Chain}
    chain::C
    chain_id::String
    hash::AttachmentHash
    key::String
    path::String # cache_dir/attachments/<hash[1:2]>/<hash>
end

const NO_HEAD =
    "the local copy has no head yet, so it belongs to no chain whose attachment it " *
    "could read; sync!(copy) binds it"

const ABSENT_FOR_READER =
    "the chain's store lacks it, and a cached file does not stand in for the chain's word"

const NOT_CACHED = "nothing was cached"

const CHANGED_WHILE_HASHED =
    "the cached file changed while it was hashed: something other than ChainTables " *
    "writes to this read-only cache; stop it"

# Over 8 lines: the read's network and cache behaviour is the contract, with its errors.
"""
    attachment(copy, hash)

Return the path of the attachment `hash` of `copy`'s chain: a read-only file in the
attachment cache, `cache_dir/attachments/<hash[1:2]>/<hash>`, shared by every chain.

It is fetched on first use, never by `sync!`. The first read of a hash through a copy
fetches it, or on a cache hit HEADs its key in the chain's store, and records it as a
confirmed attachment of the copy. A cached file that differs from its sidecar is hashed;
when it hashes to `hash` the sidecar is rewritten. Requests are retried as
`put_attachment`'s are.

Throws `AttachmentAbsentError` when the chain's store lacks it, `AttachmentDigestError`
when the store's bytes do not hash to it, and `AttachmentCacheError` when the cached file
does not hash to its name.

Examples: test/test_attachment_cache_examples.jl
"""
attachment(copy::LocalCopy, hex::AbstractString) = read_attachment(copy, hex)

# Test-only race injection: `hasher` replaces the hashing of a cached file, so a test can
# change the file while it is hashed.
function read_attachment(copy::LocalCopy, hex::AbstractString; hasher = hash_file)
    check_open(copy)
    copy.head === nothing && throw(ArgumentError("attachment(copy, hash): $NO_HEAD"))
    hash = AttachmentHash(hex)
    chain = chain_of(copy, "attachment(copy, hash)")
    target = cached_attachment(chain, copy.head.chain_id, hash)
    _is_hit = is_cache_hit(target; hasher)
    _is_hit && is_confirmed(copy, hash) && return target.path
    _is_hit ? check_hit_in_store(target) : fetch_or_throw_absent(target)
    write_confirmed_marker(copy, hash)
    return target.path
end

function cached_attachment(chain::Chain, chain_id::String, hash::AttachmentHash)
    key = attachment_key(chain, hash)
    return CachedAttachment(chain, chain_id, hash, key, attachment_cache_path(chain, hash))
end

function attachment_cache_path(chain::Chain, hash::AttachmentHash)
    return joinpath(chain.cache.dir, ATTACHMENT_CACHE_NAME, hash.hex[1:2], hash.hex)
end

# A file that differs from its sidecar is healed when it hashes right: two fetches of one
# hash at once can pair one's sidecar with the other's file.
function is_cache_hit(target::CachedAttachment; hasher)
    (; chain_id, key, path) = target
    entry = cache_entry(path)
    entry === :stale || return entry === :ok
    healed = heal_entry(path, target.hash; hasher)
    healed === :changed &&
        throw(AttachmentCacheError(; chain_id, key, path, detail = CHANGED_WHILE_HASHED))
    healed isa String && throw(
        AttachmentCacheError(; chain_id, key, path, detail = damaged_detail(path, healed))
    )
    return healed === :ok
end

# Symbols, not a type per state: only the attachment cache and its repair read them, and
# each caller tests for one state.
# `:absent` when the file or its sidecar is missing (an interrupted fetch, fetched again),
# `:ok` when the file is what its sidecar records, else `:stale`.
function cache_entry(path::AbstractString)
    meta = sidecar_path(path)
    isfile(path) && isfile(meta) || return :absent
    return sidecar_text(stat(path)) == read(meta, String) ? :ok : :stale
end

sidecar_path(path::AbstractString) = path * ".meta"
sidecar_text(st) = "$(st.size) $(st.mtime)"

# The hash and the sidecar's size and mtime come from one open file, so a file renamed
# onto the path meanwhile only leaves another mismatch, healed by the next read. A file
# whose size or mtime changed while it was hashed is `:changed`, whatever it hashed to.
# Returns `:ok` (the sidecar rewritten), `:absent`, `:changed`, or the hash the file has.
function heal_entry(path::AbstractString, hash::AttachmentHash; hasher = hash_file)
    io = open_if_present(path)
    io === nothing && return :absent
    st, found, after = try
        (stat(io), bytes2hex(hasher(io)), stat(io))
    finally
        close(io)
    end
    sidecar_text(st) == sidecar_text(after) || return :changed
    found == hash.hex || return found
    write_sidecar(path, st)
    return :ok
end

# The file may be removed between any check and the open, so the open's own failure says
# whether it is gone.
function open_if_present(path::AbstractString)
    return try
        Base.open(path)
    catch e
        e isa SystemError || rethrow()
        ispath(path) && rethrow()
        nothing
    end
end

# To a `.tmp`, renamed, so a sidecar is never half written.
function write_sidecar(path::AbstractString, st)
    meta = sidecar_path(path)
    tmp = "$meta.$(bytes2hex(rand(UInt8, 8))).tmp"
    try
        write(tmp, sidecar_text(st))
        Base.Filesystem.rename(tmp, meta)
    finally
        rm(tmp; force = true)
    end
    return nothing
end

function damaged_detail(path, found)
    st = stat(path)
    recorded = read(sidecar_path(path), String)
    return "the cached file is $(st.size) bytes modified at $(st.mtime) and hashes to " *
        "$found; its sidecar records $(repr(recorded))"
end

is_confirmed(copy::LocalCopy, hash::AttachmentHash) = isfile(confirmed_path(copy, hash))
function confirmed_path(copy::LocalCopy, hash::AttachmentHash)
    return joinpath(copy.path, "confirmed", hash.hex)
end

# A hit whose HEAD gives another size than the cached file's: one side is wrong, and
# hashing the cached file says which.
function check_hit_in_store(target::CachedAttachment)
    (; chain_id, key, path) = target
    meta = with_retries(() -> stat_object(target.chain.store, key))
    meta === nothing &&
        throw(AttachmentAbsentError(; chain_id, key, detail = ABSENT_FOR_READER))
    cached = filesize(path)
    meta.size == cached && return nothing
    found = bytes2hex(hash_file(path))
    sound = "the cached file, which hashes to the key's hash, is $cached bytes"
    found == target.hash.hex &&
        throw(AttachmentDigestError(; chain_id, key, size = meta.size, detail = sound))
    damaged = "the cached file is $cached bytes and hashes to $found, where the store " *
        "holds $(meta.size)"
    throw(AttachmentCacheError(; chain_id, key, path, detail = damaged))
end

function fetch_or_throw_absent(target::CachedAttachment)
    fetch_into_cache(target) && return nothing
    throw(AttachmentAbsentError(; target.chain_id, target.key, detail = ABSENT_FOR_READER))
end

# The download goes to a `.part` beside the entry, is hashed and made read-only; then the
# sidecar is written, and last the file is renamed into place, which is the commit: a
# rename keeps the size and mtime the sidecar records. An entry another process completed
# meanwhile is kept. `false` when the store lacks the key.
function fetch_into_cache(target::CachedAttachment)
    dir = dirname(target.path)
    mkpath(dir)
    part = joinpath(dir, "$(target.hash.hex).$(bytes2hex(rand(UInt8, 8))).part")
    fetched = try
        fetch_part_into_cache(target, part)
    finally
        isfile(part) && remove_read_only(part)
    end
    return fetched
end

function fetch_part_into_cache(target::CachedAttachment, part::String)
    size = with_retries(() -> fetch_object_to(target.chain.store, target.key, part))
    size === nothing && return false
    found = bytes2hex(hash_file(part))
    (; chain_id, key) = target
    found == target.hash.hex ||
        throw(AttachmentDigestError(; chain_id, key, found, size, detail = NOT_CACHED))
    cache_entry(target.path) === :ok && return true
    chmod(part, 0o444)
    write_sidecar(target.path, stat(part))
    replace_file(part, target.path)
    return true
end

function remove_read_only(path::AbstractString)
    chmod(path, 0o644)
    rm(path)
    return nothing
end

# Windows refuses to rename over a read-only file, so there the old one is removed first.
function replace_file(from::AbstractString, to::AbstractString)
    Sys.iswindows() && isfile(to) && remove_read_only(to)
    Base.Filesystem.rename(from, to)
    return nothing
end

function write_confirmed_marker(copy::LocalCopy, hash::AttachmentHash)
    mkpath(joinpath(copy.path, "confirmed"))
    touch(confirmed_path(copy, hash))
    return nothing
end
