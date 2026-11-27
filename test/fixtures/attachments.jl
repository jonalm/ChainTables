using SHA: sha256
using StableRNGs: StableRNG
using ChainTables: ChainTables, TransportError

const NEVER_PUT = bytes2hex(sha256(b"never put"))

# `n` bytes of an attachment, the same for one seed.
attachment_bytes(n; seed = 1) = rand(StableRNG(seed), UInt8, n)

sha256_hex(bytes) = bytes2hex(sha256(bytes))

# A failure of the transport, retryable or not by its status.
transport_failure(status) = TransportError(; method = "PUT", url = "mem:", status)

# A fault hook of `InMemoryObjectStore`: the first `remaining` requests of `verb` fail
# at `phase` with `failure`.
mutable struct FailingRequests{E}
    const verb::Symbol
    const phase::Symbol
    remaining::Int
    const failure::E
end

function (fault::FailingRequests)(verb, key, phase)
    (verb === fault.verb && phase === fault.phase) || return nothing
    fault.remaining > 0 || return nothing
    fault.remaining -= 1
    throw(fault.failure)
end

n_calls(store, verb) = count(call -> first(call) === verb, store.calls)

# The file of hash `h` in the attachment cache of a local copy of `with_chain_copy`,
# whose record cache is beside it.
function cached_file(local_copy, h)
    return joinpath(dirname(local_copy.path), "cache", "attachments", h[1:2], h)
end

is_confirmed(local_copy, h) = isfile(joinpath(local_copy.path, "confirmed", h))

# A cached file is read-only: these change it as a process outside ChainTables would.
function overwrite_cached!(path, bytes)
    chmod(path, 0o644)
    write(path, bytes)
    chmod(path, 0o444)
    return nothing
end

function remove_cached!(path)
    chmod(path, 0o644)
    rm(path)
    return nothing
end

# A sidecar that records another mtime, as two fills of one hash at once can leave.
function write_stale_sidecar!(path)
    write(path * ".meta", "$(filesize(path)) 0.0")
    return nothing
end

sidecar_of(path) = read(path * ".meta", String)

stat_text(path) = "$(stat(path).size) $(stat(path).mtime)"

# A hasher that hashes the file, then appends a byte to it before the stat after.
function growing_hasher(path)
    return function (io)
        found = ChainTables.hash_file(io)
        chmod(path, 0o644)
        Base.open(file -> write(file, 0x00), path, "a")
        return found
    end
end
