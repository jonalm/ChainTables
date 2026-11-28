const FP_TABLE_SEPARATOR = "chaintables/v1/fp-table"  # ADR-0026
const ROW_LAYOUT = "a table file row is [cells…, slot]"

"""
    HashingIO(io)

An `IO` that hashes every byte written through it, so that a table file is hashed while
it is streamed and never held whole.
"""
struct HashingIO{T <: IO} <: IO
    io::T
    ctx::SHA.SHA256_CTX
end

HashingIO(io::IO) = HashingIO(io, SHA.SHA256_CTX())

function Base.write(h::HashingIO, b::UInt8)
    SHA.update!(h.ctx, (b,))
    return write(h.io, b)
end

function Base.unsafe_write(h::HashingIO, p::Ptr{UInt8}, n::UInt)
    SHA.update!(h.ctx, unsafe_wrap(Vector{UInt8}, p, n))
    return unsafe_write(h.io, p, n)
end

"""
    write_table(io::IO, table)

Stream the table's file to `io` and return its SHA-256, which is the `table_hash` and
the file's name.

The file is `"chaintables/v1/fp-table"` followed by the CBOR of `[shape, rows]`: the rows
in typed key order, each row `[cells…, slot]`, its cells in declaration order and then
its row slot.

Examples: test/test_model_table_file_examples.jl
"""
function write_table(io::IO, t::Table)
    hashing = HashingIO(io)
    write(hashing, codeunits(FP_TABLE_SEPARATOR))
    CBOR.write_array_header(hashing, 2)
    CBOR.encode(hashing, wire(t.shape))
    CBOR.write_array_header(hashing, n_rows(t))
    foreach(i -> write_row(hashing, t, i), sortperm(key_vector(t)))
    return SHA.digest!(hashing.ctx)
end

function write_row(io::IO, t::Table, i::Int)
    CBOR.write_array_header(io, length(t.columns) + 1)
    foreach(column -> CBOR.encode(io, column[i]), t.columns)
    CBOR.encode(io, t.slots[i])
    return nothing
end

"""
    table_hash(table)

Return the 32-byte hash of a table: the SHA-256 of the bytes `write_table` streams.

It is the first level of the state fingerprint and the name of the table's file.

Examples: test/test_model_table_file_examples.jl
"""
table_hash(t::Table) = write_table(devnull, t)

"""
    read_table(io::IO)

Read one table file from `io`, as `write_table` wrote it, and return the `Table`.

Refuses anything but the canonical form: a wrong separator, a wrong outer arity, a
malformed shape, a cell off its value type, a row slot that is not an int64 of at least
1, rows out of key order or duplicated. Throws the internal `ModelError` for these and
the internal `CBOR.DecodeError` for malformed CBOR. The caller checks that the bytes
hash to the file's name.

Examples: test/test_model_table_file_examples.jl
"""
function read_table(io::IO)
    magic = read(io, ncodeunits(FP_TABLE_SEPARATOR))
    magic == codeunits(FP_TABLE_SEPARATOR) || throw(
        ModelError("not a table file: expected the separator $(repr(FP_TABLE_SEPARATOR))")
    )
    n = CBOR.read_array_header(io)
    n == 2 ||
        throw(ModelError("not a table file: expected [shape, rows], got an array of $n"))
    t = Table(Shape(CBOR.decode(io)))
    n_stored = CBOR.read_array_header(io)
    foreach(i -> push_stored_row!(t, CBOR.decode(io), i), 1:n_stored)
    check_key_order((key_at(t, i) for i in 1:n_stored); context = "in a table file")
    return t
end

# Slot 0 carries no ops, so no row is ever stamped 0 (ADR-0032).
function push_stored_row!(t::Table, row, i)
    n_cells = length(t.shape.columns)
    row isa AbstractVector || throw(ModelError("row $i is not an array"))
    expected = "$ROW_LAYOUT, $n_cells cells and its row slot"
    length(row) == n_cells + 1 ||
        throw(ModelError("row $i has $(length(row)) entries; $expected"))
    slot = row[end]
    slot isa Int64 || throw(
        ModelError("row $i's slot is not an int64, got a value of type $(typeof(slot))")
    )
    slot >= 1 || throw(ModelError("row $i's slot is $slot; a row slot is at least 1"))
    cells = @view row[1:n_cells]
    check_row(t.shape, cells)
    push_row!(t, cells, slot)
    return nothing
end
