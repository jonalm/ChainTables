"""
    LAYOUT_VERSION

The arrangement of head file and table files this client reads and writes. Purely
local, never a property of the chain: a head of another layout is rebuilt, never
migrated. A copy's `confirmed/` directory needs no new version: `open` ignores it.
"""
const LAYOUT_VERSION = 1

"""
    HEAD_SEPARATOR

The head file's magic: the bytes before the head's CBOR map, which name the layout
before anything is decoded.
"""
const HEAD_SEPARATOR = "chaintables/v1/head"

const HEAD_FIELDS = (
    "layout_version", "chain_id", "format_version", "slot", "transaction_hash",
    "state_fingerprint", "tables", "written_at_ms", "written_by",
)

const WRITTEN_BY_FIELDS = ("lib", "julia")

"""
    Head

One head file as values: which transaction record the local copy's content is the
result of, and which table file holds each table. The pin, bucket and prefix are not in
it. `encode_head` and `decode_head` are its file form; `check_head` its self-consistency.
"""
struct Head
    chain_id::String # base32 text; binds the copy to its chain
    format_version::Int64 # the record format the head's record was read under
    slot::Int64
    transaction_hash::Vector{UInt8}
    state_fingerprint::Vector{UInt8} # the fingerprint of `tables`, checked at open
    tables::Vector{Pair{String, Vector{UInt8}}} # name => table hash, sorted by name
    written_at_ms::Int64 # advisory, never checked
    written_by::ClientVersion # advisory, never checked
end

Base.:(==)(a::Head, b::Head) = all(f -> getfield(a, f) == getfield(b, f), fieldnames(Head))

function Base.hash(h::Head, seed::UInt)
    return hash(map(f -> getfield(h, f), fieldnames(Head)), hash(:Head, seed))
end

"""
    HeadRejected

A head file this client cannot read. `kind` says which action follows: `:not_ours`, a
file that is no ChainTables head; `:layout`, a newer client's layout or record format;
`:damaged`, a head that is not self-consistent. Internal: `open` throws it on as
`NotALocalCopyError`, `LayoutVersionError` or `LocalCopyInconsistentError`.
"""
struct HeadRejected <: ChainTablesError
    kind::Symbol
    detail::String
end

HeadRejected(; kind, detail = "") = HeadRejected(kind, detail)

function Base.showerror(io::IO, e::HeadRejected)
    print_summary(io, e, "the head file cannot be read")
    print_evidence(io, e)
    print(io, "\nOpen the local copy with `open(chain, path)`, which names the next move.")
    return nothing
end

"""
    head_filename(slot) -> String

The head file's name: the slot as twelve digits, zero-padded.
"""
head_filename(slot::Integer) = lpad(string(slot), 12, '0')

function written_by_here()
    return ClientVersion(("ChainTables $(pkgversion(@__MODULE__))", string(VERSION)))
end

"""
    check_head(head)

Throw `ArgumentError` unless `head` is self-consistent: every hash 32 bytes, `tables`
sorted by name without a duplicate, and `state_fingerprint` the fingerprint of `tables`.
"""
function check_head(h::Head)
    h.slot >= 0 || throw(ArgumentError("slot $(h.slot) is negative"))
    check_hash_length("transaction_hash", h.transaction_hash)
    check_hash_length("state_fingerprint", h.state_fingerprint)
    names = first.(h.tables)
    issorted(names) || throw(ArgumentError("tables are not sorted by name: $(repr(names))"))
    fingerprint = tables_fingerprint(h.tables)
    fingerprint == h.state_fingerprint || throw(
        ArgumentError(
            "its state_fingerprint is $(bytes2hex(h.state_fingerprint)), the fingerprint " *
                "of its tables list is $(bytes2hex(fingerprint))"
        )
    )
    return nothing
end

function check_hash_length(name, bytes)
    length(bytes) == 32 ||
        throw(ArgumentError("$name is $(length(bytes)) bytes; a SHA-256 is 32"))
    return nothing
end

# The model checks the hashes are 32 bytes and no name repeats.
function tables_fingerprint(tables)
    try
        return state_fingerprint(tables)
    catch e
        e isa ModelError || rethrow()
        throw(ArgumentError(e.detail))
    end
end

"""
    encode_head(head) -> Vector{UInt8}

The head file's bytes: `HEAD_SEPARATOR`, then one CBOR map through the frozen encoder.
"""
function encode_head(h::Head)
    fields = Dict{String, Any}(
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
    return vcat(codeunits(HEAD_SEPARATOR), CBOR.encode(fields))
end

"""
    decode_head(bytes) -> Head

Read one head file as `encode_head` wrote it, then `check_head` it. Throws
`HeadRejected` for a file that is not a head, another layout or a newer record format,
an unknown or mis-typed field, malformed CBOR, or a head that is not self-consistent.
"""
function decode_head(bytes::AbstractVector{UInt8})
    check_head_magic(bytes)
    fields = decode_head_map(bytes)
    check_head_versions(fields)
    h = head_from_map(fields)
    check_decoded_head(h)
    return h
end

reject_head(kind, detail) = throw(HeadRejected(; kind, detail))

function check_head_magic(bytes)
    has_prefix(bytes, codeunits(HEAD_SEPARATOR)) && return nothing
    magic = other_layout_magic(bytes)
    magic === nothing && reject_head(:not_ours, "is not a ChainTables head file")
    return reject_head(:layout, "begins $(repr(magic)), not $(repr(HEAD_SEPARATOR))")
end

function has_prefix(bytes, prefix)
    return length(bytes) >= length(prefix) && view(bytes, 1:length(prefix)) == prefix
end

# "chaintables/v<digits>/head" at the start of the bytes, or nothing: another layout
# version's magic is told apart from a file that is not ours at all.
function other_layout_magic(bytes)
    lead = codeunits("chaintables/v")
    tail = codeunits("/head")
    has_prefix(bytes, lead) || return nothing
    i = length(lead) + 1
    while i <= length(bytes) && UInt8('0') <= bytes[i] <= UInt8('9')
        i += 1
    end
    i > length(lead) + 1 || return nothing
    has_prefix(view(bytes, i:length(bytes)), tail) || return nothing
    return String(bytes[1:(i - 1 + length(tail))])
end

function decode_head_map(bytes)
    start = length(HEAD_SEPARATOR)
    fields = try
        CBOR.decode(bytes[(start + 1):end])
    catch e
        e isa CBOR.DecodeError || rethrow()
        reject_head(:damaged, "cannot be decoded: $(e.detail) at byte $(start + e.offset)")
    end
    fields isa AbstractDict || reject_head(:damaged, "is not a map")
    foreach(k -> check_known_field(k, HEAD_FIELDS, "head"), keys(fields))
    return fields
end

function check_known_field(k, known, what)
    k in known || reject_head(:damaged, "unknown $what field $(repr(k))")
    return nothing
end

function check_head_versions(fields)
    layout = head_value(fields, "layout_version", Int64, "an integer")
    layout == LAYOUT_VERSION ||
        reject_head(:layout, "layout version $layout is not this client's, $LAYOUT_VERSION")
    format = head_value(fields, "format_version", Int64, "an integer")
    format > Ops.FORMAT_VERSION && reject_head(
        :layout,
        "format_version $format is above this client's maximum, $(Ops.FORMAT_VERSION)"
    )
    format >= 1 ||
        reject_head(:damaged, "format_version $format is not a version this client reads")
    return nothing
end

function head_from_map(fields)
    chain_id = head_value(fields, "chain_id", String, "text")
    is_chain_id_text(chain_id) ||
        reject_head(:damaged, "chain_id $(repr(chain_id)) is not a chain id")
    entries = head_value(fields, "tables", AbstractVector, "an array")
    return Head(
        chain_id, head_value(fields, "format_version", Int64, "an integer"),
        head_value(fields, "slot", Int64, "an integer"),
        head_value(fields, "transaction_hash", Vector{UInt8}, "bytes"),
        head_value(fields, "state_fingerprint", Vector{UInt8}, "bytes"),
        map(table_entry, entries), head_value(fields, "written_at_ms", Int64, "an integer"),
        written_by_from_map(head_value(fields, "written_by", AbstractDict, "a map")),
    )
end

function head_value(fields, name, ::Type{T}, what) where {T}
    haskey(fields, name) || reject_head(:damaged, "has no $(repr(name))")
    value = fields[name]
    value isa T || reject_head(:damaged, "$name is not $what")
    return value::T
end

function is_chain_id_text(s)
    try
        chain_id_bytes(s)
    catch e
        e isa ArgumentError || rethrow()
        return false
    end
    return true
end

function table_entry(e)
    e isa AbstractVector && length(e) == 2 && e[1] isa String && e[2] isa Vector{UInt8} ||
        reject_head(:damaged, "tables entry $(repr(e)) is not [name, hash]")
    return Pair{String, Vector{UInt8}}(e[1], e[2])
end

function written_by_from_map(by)
    foreach(k -> check_known_field(k, WRITTEN_BY_FIELDS, "written_by"), keys(by))
    lib = head_value(by, "lib", String, "text")
    return ClientVersion((lib, head_value(by, "julia", String, "text")))
end

function check_decoded_head(h::Head)
    try
        check_head(h)
    catch e
        e isa ArgumentError || rethrow()
        reject_head(:damaged, "is not self-consistent: $(e.msg)")
    end
    return nothing
end
