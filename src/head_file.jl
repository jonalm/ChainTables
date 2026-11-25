# The layout version: which arrangement of head file and table files this client reads
# and writes (ADR-0023). Local only, never a property of the chain.
const LAYOUT_VERSION = 1

# The bytes before the head file's CBOR map. They name the layout before anything is
# decoded (ADR-0026).
const HEAD_SEPARATOR = "chaintables/v1/head"

const HEAD_FIELDS = (
    "layout_version", "chain_id", "format_version", "slot", "transaction_hash",
    "state_fingerprint", "tables", "written_at_ms", "written_by",
)
const WRITTEN_BY_FIELDS = ("lib", "julia")
const HEAD_NAME = r"\A[0-9]{12}\z"
const WIRE_KINDS = Dict{Type, String}(
    Int64 => "an integer", Vector{UInt8} => "bytes", String => "text",
    AbstractVector => "an array", AbstractDict => "a map",
)

# The eight arguments mirror the head file's map field for field.
# The hashes stay bytes, as the file holds them: chain.jl and recovery.jl read these
# fields as bytes.
"""
    Head

One head file as values: which transaction record the content of a local copy is the
result of, and which table file holds each table.

`chain_id` is the chain id as text. `transaction_hash` is the hash of the stored bytes of
the record at `slot`. `tables` holds `name => table_hash` pairs sorted by name, the only
place that says which file is which table, and `state_fingerprint` is the state
fingerprint of that list. `written_at_ms` and `written_by` are advisory and never
checked.

A `Head` agrees with itself: the constructor throws `ArgumentError` for a chain id that
is not one, a negative slot, a hash that is not 32 bytes, tables out of name order or
named twice, and a state fingerprint that is not the one of `tables`.
"""
struct Head
    chain_id::String
    format_version::Int64
    slot::Int64
    transaction_hash::Vector{UInt8}
    state_fingerprint::Vector{UInt8}
    tables::Vector{Pair{String, Vector{UInt8}}}
    written_at_ms::Int64
    written_by::ClientVersions
    function Head(
            chain_id, format_version, slot, transaction_hash, state_fingerprint, tables,
            written_at_ms, written_by,
        )
        chain_id_bytes(chain_id)  # throws for text that is not a chain id
        check_head_values(slot, transaction_hash, state_fingerprint, tables)
        return new(
            chain_id, format_version, slot, transaction_hash, state_fingerprint, tables,
            written_at_ms, written_by,
        )
    end
end

function check_head_values(slot, transaction_hash, state_fingerprint, tables)
    slot >= 0 || throw(ArgumentError("slot $slot is negative"))
    check_sha256("transaction_hash", transaction_hash)
    check_sha256("state_fingerprint", state_fingerprint)
    names = map(first, tables)
    issorted(names) ||
        throw(ArgumentError("tables are not sorted by name: $(repr(names))"))
    computed = tables_fingerprint(tables)
    computed == state_fingerprint || throw(
        ArgumentError(
            "its state_fingerprint is $(bytes2hex(state_fingerprint)), the fingerprint " *
                "of its tables list is $(bytes2hex(computed))"
        )
    )
    return nothing
end

function check_sha256(name, bytes)
    length(bytes) == 32 ||
        throw(ArgumentError("$name is $(length(bytes)) bytes; a SHA-256 is 32"))
    return nothing
end

function tables_fingerprint(tables)
    fingerprint = try
        Model.state_fingerprint(tables)
    catch e
        e isa Model.ModelError || rethrow()
        throw(ArgumentError(e.detail))
    end
    return fingerprint
end

"""
    HeadRejected(kind, detail)

Thrown when a head file cannot be used.

`kind` says which next move it calls for: `:not_ours` for a file that ChainTables did
not write, `:layout` for another layout version or a newer record format, and `:damaged`
for a damaged head file. `detail` continues a sentence that starts with the file's name.

Internal: `open` throws it as `NotALocalCopyError`, `LayoutVersionError` or
`LocalCopyInconsistentError`.
"""
struct HeadRejected <: Exception
    kind::Symbol
    detail::String
end

# The head that follows a checkpoint or a commit. `staged` is the result of
# `write_staged_tables`.
function next_head(
        chain_id, slot, transaction_hash, staged;
        # Only tests set this: a fixed clock.
        at = time(),
    )
    written_at_ms = round(Int64, at * 1000)
    return Head(
        chain_id, Ops.FORMAT_VERSION, slot, Vector{UInt8}(transaction_hash),
        staged.state_fingerprint, staged.tables, written_at_ms, written_by_here(),
    )
end

function written_by_here()
    return (; lib = "ChainTables $(pkgversion(@__MODULE__))", julia = string(VERSION))
end

# Twelve digits, zero-padded, so that the names sort by slot (ADR-0023).
head_filename(slot::Integer) = lpad(string(slot), 12, '0')

# The head file's bytes: the separator, then one CBOR map (ADR-0023).
function encode_head(h::Head)
    wire = Dict{String, Any}(
        "layout_version" => LAYOUT_VERSION, "chain_id" => h.chain_id,
        "format_version" => h.format_version, "slot" => h.slot,
        "transaction_hash" => h.transaction_hash,
        "state_fingerprint" => h.state_fingerprint,
        "tables" => Any[Any[name, hash] for (name, hash) in h.tables],
        "written_at_ms" => h.written_at_ms,
        "written_by" => Dict{String, Any}(
            "lib" => h.written_by.lib, "julia" => h.written_by.julia
        ),
    )
    return vcat(codeunits(HEAD_SEPARATOR), CBOR.encode(wire))
end

# Reads one head file as `encode_head` wrote it. Throws `HeadRejected` for anything
# else: another separator, another layout version, a newer format version, an unknown
# or mistyped field, malformed CBOR, a head that does not agree with itself.
function decode_head(bytes::AbstractVector{UInt8})
    wire = head_wire(bytes)
    check_versions(wire)
    chain_id = typed_field(wire, "chain_id", String)
    format_version = typed_field(wire, "format_version", Int64)
    slot = typed_field(wire, "slot", Int64)
    transaction_hash = typed_field(wire, "transaction_hash", Vector{UInt8})
    state_fingerprint = typed_field(wire, "state_fingerprint", Vector{UInt8})
    entries = typed_field(wire, "tables", AbstractVector)
    tables = Pair{String, Vector{UInt8}}[table_entry(entry) for entry in entries]
    written_at_ms = typed_field(wire, "written_at_ms", Int64)
    written_by = written_by_field(wire)
    head_file = try
        Head(
            chain_id, format_version, slot, transaction_hash, state_fingerprint, tables,
            written_at_ms, written_by,
        )
    catch e
        e isa ArgumentError || rethrow()
        throw(HeadRejected(:damaged, "is not self-consistent: $(e.msg)"))
    end
    return head_file
end

function head_wire(bytes)
    check_separator(bytes)
    wire = decoded_map(bytes, ncodeunits(HEAD_SEPARATOR))
    unknown = filter(!in(HEAD_FIELDS), collect(keys(wire)))
    isempty(unknown) ||
        throw(HeadRejected(:damaged, "has the unknown field $(repr(first(unknown)))"))
    return wire
end

# The separator of another layout version is told apart from a file that is not a head
# file at all: the two call for different next moves.
function check_separator(bytes)
    has_bytes_at(bytes, 1, codeunits(HEAD_SEPARATOR)) && return nothing
    other = other_layout_separator(bytes)
    other === nothing &&
        throw(HeadRejected(:not_ours, "is not a ChainTables head file"))
    throw(HeadRejected(:layout, "begins $(repr(other)), not $(repr(HEAD_SEPARATOR))"))
end

function has_bytes_at(bytes, start, part)
    stop = start + length(part) - 1
    return stop <= length(bytes) && view(bytes, start:stop) == part
end

# "chaintables/v<digits>/head" at the start of the bytes, or `nothing`.
function other_layout_separator(bytes)
    lead = codeunits("chaintables/v")
    tail = codeunits("/head")
    has_bytes_at(bytes, 1, lead) || return nothing
    first_digit = length(lead) + 1
    after_digits = findnext(!is_ascii_digit, bytes, first_digit)
    after_digits === nothing && return nothing
    after_digits > first_digit || return nothing
    has_bytes_at(bytes, after_digits, tail) || return nothing
    return String(bytes[1:(after_digits + length(tail) - 1)])
end

is_ascii_digit(byte::UInt8) = UInt8('0') <= byte <= UInt8('9')

function decoded_map(bytes, n_separator)
    wire = try
        CBOR.decode(bytes[(n_separator + 1):end])
    catch e
        e isa CBOR.DecodeError || rethrow()
        at = n_separator + e.offset
        throw(HeadRejected(:damaged, "cannot be decoded: $(e.detail) at byte $at"))
    end
    wire isa AbstractDict || throw(HeadRejected(:damaged, "is not a map"))
    return wire
end

function check_versions(wire)
    layout_version = typed_field(wire, "layout_version", Int64)
    layout_version == LAYOUT_VERSION || throw(
        HeadRejected(
            :layout,
            "has layout version $layout_version; this client's is $LAYOUT_VERSION"
        )
    )
    format_version = typed_field(wire, "format_version", Int64)
    newest = Ops.FORMAT_VERSION
    format_version > newest && throw(
        HeadRejected(
            :layout,
            "has format version $format_version, above this client's maximum, $newest"
        )
    )
    format_version >= 1 || throw(
        HeadRejected(
            :damaged,
            "has format version $format_version, which is not a version this client reads"
        )
    )
    return nothing
end

function typed_field(wire, name, ::Type{T}) where {T}
    haskey(wire, name) || throw(HeadRejected(:damaged, "has no $(repr(name))"))
    value = wire[name]
    value isa T || throw(HeadRejected(:damaged, "$name is not $(WIRE_KINDS[T])"))
    return value
end

function table_entry(entry)
    is_table_entry(entry) || throw(
        HeadRejected(:damaged, "tables entry $(repr(entry)) is not [name, hash]")
    )
    return entry[1] => entry[2]
end

function is_table_entry(entry)
    entry isa AbstractVector && length(entry) == 2 || return false
    return entry[1] isa String && entry[2] isa Vector{UInt8}
end

function written_by_field(wire)
    written_by = typed_field(wire, "written_by", AbstractDict)
    unknown = filter(!in(WRITTEN_BY_FIELDS), collect(keys(written_by)))
    isempty(unknown) || throw(
        HeadRejected(:damaged, "has the unknown written_by field $(repr(first(unknown)))")
    )
    lib = typed_field(written_by, "lib", String)
    julia = typed_field(written_by, "julia", String)
    return (; lib, julia)
end
