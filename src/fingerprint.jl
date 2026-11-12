# Format bytes, frozen for the life of format_version 1 (ADR-0026).
const FP_SEPARATOR = "chaintables/v1/fp"
const NOT_SHA256 = "bytes; a SHA-256 is 32"

"""
    state_fingerprint(tables) -> Vector{UInt8}
    state_fingerprint(content::Content) -> Vector{UInt8}

Return the 32-byte state fingerprint, `SHA-256("chaintables/v1/fp" ‖ cbor([[name,
table_hash], …]))` over `name => table_hash` pairs sorted by name. The first form takes
the head file's pairs; the second hashes every table of a content first. Throws
`ModelError` for a duplicate name or a hash that is not 32 bytes.
"""
function state_fingerprint(tables)
    entries = sort!([(String(first(p)), last(p)) for p in tables]; by = first)
    check_fingerprint_entries(entries)
    io = IOBuffer()
    write(io, codeunits(FP_SEPARATOR))
    CBOR.encode(io, [(name, Vector{UInt8}(h)) for (name, h) in entries])
    return SHA.sha256(take!(io))
end

state_fingerprint(c::Content) = state_fingerprint(name => table_hash(t) for (name, t) in c)

function check_fingerprint_entries(entries)
    for i in eachindex(entries)
        name, h = entries[i]
        size_text = h isa AbstractVector{UInt8} ? length(h) : "not"
        is_sha256(h) || throw(
            ModelError(; detail = "table_hash of $(repr(name)) is $size_text $NOT_SHA256")
        )
        i > 1 && first(entries[i - 1]) == name &&
            throw(ModelError(; detail = "duplicate table name $(repr(name))"))
    end
    return nothing
end

is_sha256(h) = h isa AbstractVector{UInt8} && length(h) == 32
