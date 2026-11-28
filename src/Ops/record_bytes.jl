const CAP_TEXT = "the cap is $MAX_RECORD_BYTES bytes (64 MiB)"
const NO_UNKNOWN_FIELD = "every format addition is a format_version bump"

"""
    encode_record(record)

Return the stored bytes of a record: one map of deterministic CBOR.

Throws `WriteBuilderError` when the bytes are over the 64 MiB record cap.

Examples: test/test_ops_record_bytes_examples.jl
"""
function encode_record(r::Record)
    bytes = CBOR.encode(wire(r))
    length(bytes) <= MAX_RECORD_BYTES || throw(
        WriteBuilderError(;
            detail = "record is $(length(bytes)) bytes; $CAP_TEXT: " *
                "split the write into more than one commit"
        )
    )
    return bytes
end

"""
    transaction_hash(bytes)

Return the 32-byte transaction hash of a record's stored bytes: the SHA-256 of
`"chaintables/v1/txn"` followed by `bytes`.

The hash is over the bytes exactly as fetched, never over an encoding made again.

Examples: test/test_ops_record_bytes_examples.jl
"""
function transaction_hash(bytes::AbstractVector{UInt8})
    ctx = SHA.SHA256_CTX()
    SHA.update!(ctx, codeunits(TXN_SEPARATOR))
    SHA.update!(ctx, bytes)
    return SHA.digest!(ctx)
end

"""
    decode_record(bytes; slot = nothing)

Read a record's stored bytes and return the `Record`.

Refuses bytes that are not deterministic CBOR, an unknown field of the envelope or of
`client`, a `format_version` this client does not read, a missing or mis-shaped field,
a record over the cap, and an op that is not one of the seven. The cells of an op are
checked at `apply!`, where the shape is known. Throws `MalformedRecordError`.

- `slot`: the slot the bytes were fetched from. The record must name it.

Examples: test/test_ops_record_bytes_examples.jl
"""
function decode_record(bytes::AbstractVector{UInt8}; slot = nothing)
    length(bytes) <= MAX_RECORD_BYTES || throw(
        MalformedRecordError(; slot, detail = "record is $(length(bytes)) bytes; $CAP_TEXT")
    )
    wire = decoded_item(bytes, slot)
    wire isa AbstractDict || throw(
        MalformedRecordError(;
            slot, detail = "record is not a map, got a value of type $(typeof(wire))"
        )
    )
    named = slot === nothing ? readable_slot(wire) : slot
    record = try
        record_from_wire(wire, named)
    catch e
        e isa ModelError || rethrow()
        chain_id = readable_chain_id(wire)
        throw(MalformedRecordError(; chain_id, slot = named, e.detail))
    end
    return record
end

function decoded_item(bytes, slot)
    item = try
        CBOR.decode(bytes)
    catch e
        e isa CBOR.DecodeError || rethrow()
        detail = "not deterministic CBOR (byte $(e.offset): $(e.detail))"
        throw(MalformedRecordError(; slot, detail))
    end
    return item
end

# The slot and the chain id as evidence, when the envelope carries them in readable
# form.
function readable_slot(wire)
    slot = get(wire, "slot", nothing)
    return slot isa Int64 ? slot : nothing
end

function readable_chain_id(wire)
    chain_id = get(wire, "chain_id", nothing)
    chain_id isa AbstractVector{UInt8} && length(chain_id) == 16 || return nothing
    return ChainTables.chain_id_string(chain_id)
end

function record_from_wire(wire, slot)
    stray = filter(!in(ENVELOPE_FIELDS), collect(keys(wire)))
    isempty(stray) ||
        throw(ModelError("unknown envelope field $(repr(first(stray))); $NO_UNKNOWN_FIELD"))
    check_format_version(envelope_field(wire, "format_version"))
    named = envelope_field(wire, "slot")
    named isa Int64 || throw(ModelError("slot is not an integer"))
    slot === nothing || named == slot || throw(ModelError("the record names slot $named"))
    chain_id = envelope_bytes(wire, "chain_id", 16, "a chain id")
    parent = haskey(wire, "prev_hash") ? parent_hash(wire) : nothing
    fingerprint = envelope_bytes(wire, "state_fingerprint", 32, "a SHA-256")
    client = client_from_wire(envelope_field(wire, "client"))
    comment = get(wire, "comment", nothing)
    comment === nothing || comment isa String || throw(ModelError("comment is not text"))
    entries = envelope_field(wire, "ops")
    entries isa AbstractVector || throw(ModelError("ops is not an array"))
    ops = [op_at(i, entry) for (i, entry) in enumerate(entries)]
    return Record(chain_id, named, parent, fingerprint, client, comment, ops)
end

function check_format_version(v)
    v isa Int64 || throw(ModelError("format_version is not an integer"))
    v > FORMAT_VERSION && throw(
        ModelError(
            "format_version $v is above this client's maximum, $FORMAT_VERSION; " *
                "a newer client wrote it: upgrade ChainTables"
        )
    )
    v == FORMAT_VERSION ||
        throw(ModelError("format_version $v is not a version this client reads"))
    return nothing
end

function envelope_field(wire, name)
    haskey(wire, name) || throw(ModelError("record has no $(repr(name))"))
    return wire[name]
end

function envelope_bytes(wire, name, n, what)
    bytes = envelope_field(wire, name)
    bytes isa AbstractVector{UInt8} || throw(ModelError("$name is not bytes"))
    check_size(name, bytes, n, what)
    return bytes
end

parent_hash(wire) = envelope_bytes(wire, "prev_hash", 32, "a SHA-256")

function client_from_wire(wire)
    wire isa AbstractDict || throw(ModelError("client is not a map"))
    stray = filter(!in(CLIENT_FIELDS), collect(keys(wire)))
    isempty(stray) || throw(ModelError("unknown client field $(repr(first(stray)))"))
    haskey(wire, "time_ms") || throw(ModelError("client has no \"time_ms\""))
    time_ms = wire["time_ms"]
    time_ms isa Int64 || throw(ModelError("client.time_ms is not an integer"))
    host = optional_client_text(wire, "host")
    user = optional_client_text(wire, "user")
    return Client(host, user, client_text(wire, "lib"), client_text(wire, "julia"), time_ms)
end

function client_text(wire, name)
    haskey(wire, name) || throw(ModelError("client has no $(repr(name))"))
    wire[name] isa String || throw(ModelError("client.$name is not text"))
    return wire[name]
end

function optional_client_text(wire, name)
    return haskey(wire, name) ? client_text(wire, name) : nothing
end

function op_at(i, entry)
    op = try
        op_from_wire(entry)
    catch e
        e isa ModelError || rethrow()
        throw(ModelError("op $i: $(e.detail)"))
    end
    return op
end
