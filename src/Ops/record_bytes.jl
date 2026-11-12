# Format bytes, frozen for the life of format_version 1 (ADR-0026).
const TXN_SEPARATOR = "chaintables/v1/txn"
const ENVELOPE_FIELDS = (
    "format_version", "chain_id", "slot", "prev_hash", "state_fingerprint", "client",
    "comment", "ops",
)
const CLIENT_FIELDS = ("host", "user", "lib", "julia", "time_ms")
const RECORD_CAP = "the cap is $MAX_RECORD_BYTES bytes (64 MiB)"
const SPLIT_THE_WRITE = "split the write into more than one commit"
const ABOVE_MAXIMUM = "is above this client's maximum, $FORMAT_VERSION; " *
    "a newer client wrote it: upgrade ChainTables"
const NOT_A_MAP = "record is not a map, got a value of type"

"""
    encode_record(record) -> Vector{UInt8}

Return the record's stored bytes: one deterministic CBOR map. Throws `WriteBuilderError`
when the record is over the 64 MiB cap.

Examples: test/test_ops_record_bytes_examples.jl
"""
function encode_record(r::Record)
    bytes = CBOR.encode(wire(r))
    n = length(bytes)
    n <= MAX_RECORD_BYTES || throw(
        WriteBuilderError(; detail = "record is $n bytes; $RECORD_CAP: $SPLIT_THE_WRITE")
    )
    return bytes
end

"""
    transaction_hash(bytes) -> Vector{UInt8}

Return `SHA-256("chaintables/v1/txn" ‖ bytes)` over a record's stored bytes, exactly as
fetched, never over a re-encoding.
"""
function transaction_hash(bytes::AbstractVector{UInt8})
    ctx = SHA.SHA256_CTX()
    SHA.update!(ctx, codeunits(TXN_SEPARATOR))
    SHA.update!(ctx, bytes)
    return SHA.digest!(ctx)
end

"""
    decode_record(bytes; slot = nothing) -> Record

Read a record from its stored bytes. Pass `slot`, the slot the bytes were fetched from,
and the record must name it. Throws `MalformedRecordError` when the bytes are not the
format: over the cap, not deterministic CBOR, an unknown field, a newer `format_version`,
a missing or mis-shaped field, or an op that is not one of the seven.

Examples: test/test_ops_record_bytes_examples.jl
"""
function decode_record(bytes::AbstractVector{UInt8}; slot = nothing)
    n = length(bytes)
    n <= MAX_RECORD_BYTES ||
        throw(MalformedRecordError(; slot, detail = "record is $n bytes; $RECORD_CAP"))
    w = decode_envelope(bytes, slot)
    known_slot = slot === nothing ? readable_slot(w) : slot
    try
        return record_from_wire(w, known_slot)
    catch e
        e isa ModelError || rethrow()
        chain_id = readable_chain_id(w)
        throw(MalformedRecordError(; chain_id, slot = known_slot, detail = e.detail))
    end
end

function decode_envelope(bytes::AbstractVector{UInt8}, slot)
    w = try
        CBOR.decode(bytes)
    catch e
        e isa CBOR.DecodeError || rethrow()
        detail = "not deterministic CBOR (byte $(e.offset): $(e.detail))"
        throw(MalformedRecordError(; slot, detail))
    end
    w isa AbstractDict || throw(
        MalformedRecordError(; slot, detail = "$NOT_A_MAP $(typeof(w))")
    )
    return w
end

# The Evidence a malformed record still offers, when it is readable.
readable_slot(w) = get(w, "slot", nothing) isa Int64 ? w["slot"] : nothing

function readable_chain_id(w)
    chain_id = get(w, "chain_id", nothing)
    is_chain_id = chain_id isa AbstractVector{UInt8} && length(chain_id) == 16
    return is_chain_id ? ChainTables.chain_id_string(chain_id) : nothing
end

function record_from_wire(w, slot)
    unknown = filter(∉(ENVELOPE_FIELDS), collect(keys(w)))
    isempty(unknown) || throw(
        ModelError(; detail = unknown_envelope_text(first(unknown)))
    )
    check_format_version(envelope_field(w, "format_version"))
    s = envelope_field(w, "slot")
    s isa Int64 || throw(ModelError(; detail = "slot is not an integer"))
    slot === nothing || s == slot ||
        throw(ModelError(; detail = "the record names slot $s"))
    chain_id = envelope_bytes(w, "chain_id", 16, "a chain id")
    prev = prev_hash_from_wire(w)
    fingerprint = envelope_bytes(w, "state_fingerprint", 32, "a SHA-256")
    client = client_from_wire(envelope_field(w, "client"))
    comment = get(w, "comment", nothing)
    comment === nothing || comment isa String ||
        throw(ModelError(; detail = "comment is not text"))
    ops = ops_from_wire(envelope_field(w, "ops"))
    return Record(chain_id, s, prev, fingerprint, client, comment, ops)
end

# A genesis record has no parent, so no prev_hash.
function prev_hash_from_wire(w)
    haskey(w, "prev_hash") || return nothing
    return envelope_bytes(w, "prev_hash", 32, "a SHA-256")
end

function check_format_version(v)
    v isa Int64 || throw(ModelError(; detail = "format_version is not an integer"))
    v > FORMAT_VERSION && throw(
        ModelError(; detail = "format_version $v $ABOVE_MAXIMUM")
    )
    v == FORMAT_VERSION ||
        throw(ModelError(; detail = "format_version $v is not a version this client reads"))
    return nothing
end

function envelope_field(w, name)
    haskey(w, name) || throw(ModelError(; detail = "record has no $(repr(name))"))
    return w[name]
end

function envelope_bytes(w, name, n, what)
    x = envelope_field(w, name)
    x isa AbstractVector{UInt8} || throw(ModelError(; detail = "$name is not bytes"))
    length(x) == n ||
        throw(ModelError(; detail = "$name is $(length(x)) bytes; $what is $n"))
    return x
end

function client_from_wire(c::AbstractDict)
    unknown = filter(∉(CLIENT_FIELDS), collect(keys(c)))
    isempty(unknown) ||
        throw(ModelError(; detail = "unknown client field $(repr(first(unknown)))"))
    haskey(c, "time_ms") || throw(ModelError(; detail = "client has no \"time_ms\""))
    c["time_ms"] isa Int64 ||
        throw(ModelError(; detail = "client.time_ms is not an integer"))
    host = haskey(c, "host") ? client_text(c, "host") : nothing
    user = haskey(c, "user") ? client_text(c, "user") : nothing
    lib = client_text(c, "lib")
    return Client(host, user, lib, client_text(c, "julia"), c["time_ms"])
end

client_from_wire(c) = throw(ModelError(; detail = "client is not a map"))

function client_text(c::AbstractDict, name)
    haskey(c, name) || throw(ModelError(; detail = "client has no $(repr(name))"))
    x = c[name]
    x isa String || throw(ModelError(; detail = "client.$name is not text"))
    return x
end

function ops_from_wire(x)
    x isa AbstractVector || throw(ModelError(; detail = "ops is not an array"))
    return Op[op_from_wire_at(i, w) for (i, w) in enumerate(x)]
end

# The op's index is not Evidence here: the caller adds the slot and the chain id, so
# the index goes into the detail.
function op_from_wire_at(i, w)
    try
        return op_from_wire(w)
    catch e
        e isa ModelError || rethrow()
        throw(ModelError(; detail = "op $i: $(e.detail)"))
    end
end

function unknown_envelope_text(name)
    return "unknown envelope field $(repr(name)); every format addition is a " *
        "format_version bump"
end
