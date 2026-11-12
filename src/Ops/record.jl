"""
    FORMAT_VERSION

The one `format_version` this client reads and writes. A record above it was written by
a newer client and is refused.
"""
const FORMAT_VERSION = 1

"""
    MAX_RECORD_BYTES

The record cap, 64 MiB, enforced when a record is encoded and again when one is read.
"""
const MAX_RECORD_BYTES = 64 * 1024 * 1024

const GENESIS_HAS_NO_OPS = "genesis carries none, so no row is ever stamped 0 (ADR-0032)"
const NO_OPS = "record has no ops; a record after genesis carries at least one (ADR-0019)"
const GENESIS_HAS_PARENT = "slot 0 carries a prev_hash; genesis has no parent (ADR-0002)"
const PARENT_REQUIRED = "every slot after genesis names its parent"

"""
    check_text(what, s) -> s

Return `s`, or throw `ModelError` naming `what` when `s` is not well-formed UTF-8 or holds
U+0000. `nothing` passes.
"""
function check_text(what, s)
    isvalid(s) || throw(ModelError(; detail = "$what is not well-formed UTF-8"))
    '\0' in s && throw(ModelError(; detail = "$what contains U+0000"))
    return s
end

check_text(what, ::Nothing) = nothing

"""
    Client(host, user, lib, julia, time_ms)

The `client` map of a transaction record: the host and the author (`user`), each
`nothing` when left out; the package and Julia versions that wrote it, both advisory; and
`time_ms`, milliseconds since the Unix epoch in UTC. Throws `ModelError` for text that is
not well-formed UTF-8 or holds U+0000.

Examples: test/test_ops_record_examples.jl
"""
struct Client
    host::Union{Nothing, String}
    user::Union{Nothing, String}
    lib::String
    julia::String
    time_ms::Int64
    # The envelope's client map field for field; `local_client` fills it for this machine.
    function Client(host, user, lib, julia, time_ms)
        check_text("client.host", host)
        check_text("client.user", user)
        check_text("client.lib", lib)
        check_text("client.julia", julia)
        return new(host, user, lib, julia, time_ms)
    end
end

"""
    local_client(; record_host = true, user = nothing, at = time()) -> Client

Return this machine's `client` map: `lib` is `"ChainTables <version>"`, `julia` is this
Julia's version, and `time_ms` is `at` (seconds since the epoch) in milliseconds. `user`
is the author the caller resolved; `nothing` or `""` leaves it out, as `record_host =
false` leaves out the host.
"""
function local_client(; record_host = true, user = nothing, at = time())
    host = record_host ? gethostname() : nothing
    author = user == "" ? nothing : user
    lib = "ChainTables $(pkgversion(@__MODULE__))"
    return Client(host, author, lib, string(VERSION), round(Int64, at * 1000))
end

"""
    Record(chain_id, slot, prev_hash, state_fingerprint, client, comment, ops)

One transaction record. `prev_hash` is `nothing` exactly at slot 0, `comment` is
`nothing` when absent, and `ops` are empty exactly at slot 0, the genesis. The record
format version is always `FORMAT_VERSION`, and a record never holds its own transaction
hash. Throws `ModelError` for a chain id that is not 16 bytes, a hash that is not 32, a
negative slot, or a comment that is not well-formed UTF-8 or holds U+0000.

Examples: test/test_ops_record_examples.jl
"""
struct Record
    chain_id::Vector{UInt8}
    slot::Int64
    prev_hash::Union{Nothing, Vector{UInt8}}
    state_fingerprint::Vector{UInt8}
    client::Client
    comment::Union{Nothing, String}
    ops::Vector{Op}
    # The envelope field for field, so the builder and `decode_record` share one check.
    function Record(chain_id, slot, prev_hash, state_fingerprint, client, comment, ops)
        check_envelope(chain_id, slot, prev_hash, state_fingerprint, length(ops))
        check_text("comment", comment)
        prev = prev_hash === nothing ? nothing : Vector{UInt8}(prev_hash)
        return new(
            Vector{UInt8}(chain_id), slot, prev, Vector{UInt8}(state_fingerprint), client,
            comment, collect(Op, ops)
        )
    end
end

function Base.:(==)(a::Record, b::Record)
    return all(f -> isequal(getfield(a, f), getfield(b, f)), fieldnames(Record))
end

function Base.hash(r::Record, h::UInt)
    return hash(map(f -> getfield(r, f), fieldnames(Record)), hash(:Record, h))
end

# `prev_hash`, `comment`, `client.host` and `client.user` are left out when absent,
# never written as null.
function wire(r::Record)
    w = Dict{String, Any}(
        "format_version" => FORMAT_VERSION, "chain_id" => r.chain_id, "slot" => r.slot,
        "state_fingerprint" => r.state_fingerprint, "client" => wire(r.client),
        "ops" => Any[wire(op) for op in r.ops],
    )
    r.prev_hash === nothing || (w["prev_hash"] = r.prev_hash)
    r.comment === nothing || (w["comment"] = r.comment)
    return w
end

function wire(c::Client)
    w = Dict{String, Any}("lib" => c.lib, "julia" => c.julia, "time_ms" => c.time_ms)
    c.host === nothing || (w["host"] = c.host)
    c.user === nothing || (w["user"] = c.user)
    return w
end

function check_envelope(chain_id, slot, prev_hash, state_fingerprint, n_ops)
    n = length(chain_id)
    n == 16 || throw(ModelError(; detail = "chain_id is $n bytes; a chain id is 16"))
    n = length(state_fingerprint)
    n == 32 ||
        throw(ModelError(; detail = "state_fingerprint is $n bytes; a SHA-256 is 32"))
    slot < 0 && throw(ModelError(; detail = "slot $slot is negative"))
    slot == 0 && return check_genesis(prev_hash, n_ops)
    prev_hash === nothing &&
        throw(ModelError(; detail = "slot $slot has no prev_hash; $PARENT_REQUIRED"))
    n = length(prev_hash)
    n == 32 || throw(ModelError(; detail = "prev_hash is $n bytes; a SHA-256 is 32"))
    n_ops == 0 && throw(
        ModelError(; detail = NO_OPS)
    )
    return nothing
end

function check_genesis(prev_hash, n_ops)
    prev_hash === nothing || throw(
        ModelError(; detail = GENESIS_HAS_PARENT)
    )
    plural = n_ops == 1 ? "" : "s"
    n_ops == 0 ||
        throw(ModelError(; detail = "slot 0 carries $n_ops op$plural; $GENESIS_HAS_NO_OPS"))
    return nothing
end
