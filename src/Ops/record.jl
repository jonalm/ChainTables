# The one `format_version` this client reads and writes. A record above it is a hard
# error: a newer client wrote it (ADR-0006).
const FORMAT_VERSION = 1

# The domain separator of the transaction hash (ADR-0026). Format bytes: frozen for the
# life of `format_version` 1.
const TXN_SEPARATOR = "chaintables/v1/txn"

# The record cap, 64 MiB (ADR-0006), enforced when a record is built and again when one
# is read.
const MAX_RECORD_BYTES = 64 * 1024 * 1024

const ENVELOPE_FIELDS = (
    "format_version", "chain_id", "slot", "prev_hash", "state_fingerprint", "client",
    "comment", "ops",
)
const CLIENT_FIELDS = ("host", "user", "lib", "julia", "time_ms")
const GENESIS_HAS_NO_PARENT = "genesis has no parent"
const GENESIS_HAS_NO_OPS = "genesis carries none, so no row is ever stamped 0"
const NAMES_ITS_PARENT = "every slot after genesis names its parent"
const CARRIES_AN_OP = "a record after genesis carries at least one"

# The fields mirror the record's `client` map, and chain.jl calls this positionally.
"""
    Client(host, user, lib, julia, time_ms)

The `client` map of a transaction record: who wrote it, with what, and when.

`host` and `user` are `nothing` when left out. `lib` names the package and its version
and `julia` the Julia version; both are advisory. `time_ms` is milliseconds since the
Unix epoch, UTC. Throws the internal `ModelError` for text that is not well-formed UTF-8
or holds U+0000.

Examples: test/test_ops_record_examples.jl
"""
struct Client
    host::Union{Nothing, String}
    user::Union{Nothing, String}
    lib::String
    julia::String
    time_ms::Int64
    function Client(host, user, lib, julia, time_ms)
        check_text("client.host", host)
        check_text("client.user", user)
        check_text("client.lib", lib)
        check_text("client.julia", julia)
        return new(host, user, lib, julia, time_ms)
    end
end

# The seven arguments mirror the envelope field for field, and chain.jl calls this
# positionally.
# The hashes and the chain id stay bytes, as the wire carries them: localcopy.jl and
# chain.jl read these fields as bytes.
"""
    Record(chain_id, slot, prev_hash, state_fingerprint, client, comment, ops)

One transaction record: the fields of its envelope as Julia values.

`prev_hash` is `nothing` at slot 0 and nowhere else. `comment` is `nothing` when absent.
`ops` is empty at slot 0, the genesis record, and holds at least one `Op` at every other
slot. The chain id is 16 bytes and each hash 32. A record never holds its own
transaction hash: that is a function of its stored bytes. Throws the internal
`ModelError` when a rule of the envelope is broken.

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
    function Record(chain_id, slot, prev_hash, state_fingerprint, client, comment, ops)
        check_size("chain_id", chain_id, 16, "a chain id")
        check_size("state_fingerprint", state_fingerprint, 32, "a SHA-256")
        slot < 0 && throw(ModelError("slot $slot is negative"))
        slot == 0 && check_genesis(prev_hash, ops)
        slot > 0 && check_successor(slot, prev_hash, ops)
        check_text("comment", comment)
        parent = prev_hash === nothing ? nothing : Vector{UInt8}(prev_hash)
        fingerprint = Vector{UInt8}(state_fingerprint)
        ops = collect(Op, ops)
        return new(Vector{UInt8}(chain_id), slot, parent, fingerprint, client, comment, ops)
    end
end

# Fields compare with `isequal`, so a record whose ops hold NaN or `missing` equals
# itself.
function Base.:(==)(a::Record, b::Record)
    return all(f -> isequal(getfield(a, f), getfield(b, f)), fieldnames(Record))
end

function Base.hash(r::Record, h::UInt)
    init = hash(:Record, h)
    return foldl((acc, f) -> hash(getfield(r, f), acc), fieldnames(Record); init)
end

"""
    local_client(; record_host = true, user = nothing)

Return this machine's `Client`, at this moment.

`lib` is `"ChainTables <version>"` and `julia` is `string(VERSION)`. `user` is the
author the caller resolved; `nothing` or `""` leaves it out. `record_host = false`
leaves the host out.

Examples: test/test_ops_record_examples.jl
"""
function local_client(;
        record_host = true, user = nothing,
        # Only tests set these two: a fixed host name and a fixed clock.
        host = gethostname(), at = time(),
    )
    author = user == "" ? nothing : user
    lib = "ChainTables $(pkgversion(@__MODULE__))"
    time_ms = round(Int64, at * 1000)
    return Client(record_host ? host : nothing, author, lib, string(VERSION), time_ms)
end

function check_text(what, s)
    isvalid(s) || throw(ModelError("$what is not well-formed UTF-8"))
    '\0' in s && throw(ModelError("$what contains U+0000"))
    return nothing
end

check_text(what, ::Nothing) = nothing

function check_size(name, bytes, n, what)
    length(bytes) == n ||
        throw(ModelError("$name is $(length(bytes)) bytes; $what is $n"))
    return nothing
end

function check_genesis(prev_hash, ops)
    prev_hash === nothing ||
        throw(ModelError("slot 0 carries a prev_hash; $GENESIS_HAS_NO_PARENT"))
    n = length(ops)
    plural = n == 1 ? "" : "s"
    n == 0 || throw(ModelError("slot 0 carries $n op$plural; $GENESIS_HAS_NO_OPS"))
    return nothing
end

function check_successor(slot, prev_hash, ops)
    prev_hash === nothing &&
        throw(ModelError("slot $slot has no prev_hash; $NAMES_ITS_PARENT"))
    check_size("prev_hash", prev_hash, 32, "a SHA-256")
    isempty(ops) && throw(ModelError("record has no ops; $CARRIES_AN_OP"))
    return nothing
end

# The wire form of a record, ready for `CBOR.encode`. What is absent is left out, never
# spelt as null.
function wire(r::Record)
    w = Dict{String, Any}(
        "format_version" => FORMAT_VERSION, "chain_id" => r.chain_id, "slot" => r.slot,
        "state_fingerprint" => r.state_fingerprint, "client" => wire(r.client),
        "ops" => Any[wire(op) for op in r.ops],
    )
    r.prev_hash === nothing || setindex!(w, r.prev_hash, "prev_hash")
    r.comment === nothing || setindex!(w, r.comment, "comment")
    return w
end

function wire(c::Client)
    w = Dict{String, Any}("lib" => c.lib, "julia" => c.julia, "time_ms" => c.time_ms)
    c.host === nothing || setindex!(w, c.host, "host")
    c.user === nothing || setindex!(w, c.user, "user")
    return w
end
