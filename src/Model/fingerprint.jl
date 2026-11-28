const FP_SEPARATOR = "chaintables/v1/fp"  # ADR-0026

"""
    state_fingerprint(tables)
    state_fingerprint(content::Content)

Return the 32-byte state fingerprint: the SHA-256 of `"chaintables/v1/fp"` followed by
the CBOR of `[[name, table_hash], …]`, sorted by name.

`tables` holds `name => table_hash` pairs, as a head file lists them. The second form
hashes every table of a content first. Throws the internal `ModelError` for a hash that
is not 32 bytes or a table named twice.

Examples: test/test_model_fingerprint_examples.jl
"""
function state_fingerprint(tables)
    entries = sort!([(String(first(p)), last(p)) for p in tables]; by = first)
    check_table_hashes(entries)
    io = IOBuffer()
    write(io, codeunits(FP_SEPARATOR))
    CBOR.encode(io, Any[Any[name, Vector{UInt8}(hash)] for (name, hash) in entries])
    return SHA.sha256(take!(io))
end

function state_fingerprint(c::Content)
    return state_fingerprint(name => table_hash(t) for (name, t) in c)
end

function check_table_hashes(entries)
    for (i, (name, hash)) in enumerate(entries)
        hash isa AbstractVector{UInt8} && length(hash) == 32 ||
            throw(ModelError(not_a_hash(name, hash)))
        i > 1 && first(entries[i - 1]) == name &&
            throw(ModelError("duplicate table name $(repr(name))"))
    end
    return nothing
end

function not_a_hash(name, hash)
    size = hash isa AbstractVector{UInt8} ? length(hash) : "not"
    return "table_hash of $(repr(name)) is $size bytes; a SHA-256 is 32"
end
