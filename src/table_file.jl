# Format bytes, frozen for the life of format_version 1 (ADR-0026).
const FP_TABLE_SEPARATOR = "chaintables/v1/fp-table"
const NO_SEPARATOR = "not a table file: expected the separator $(repr(FP_TABLE_SEPARATOR))"
const NOT_SHAPE_ROWS = "not a table file: expected [shape, rows], got an array of"

"""
    HashingIO(io)

An `IO` that hashes with SHA-256 every byte written through it to `io`, so a table file
is hashed as it is streamed rather than buffered.
"""
mutable struct HashingIO{T <: IO} <: IO
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
    write_table(io, table) -> Vector{UInt8}

Stream the table's file to `io` and return its SHA-256, the table hash and the file's
name. The file is `"chaintables/v1/fp-table" ‖ cbor([shape, rows])`, rows in typed key
order, each row its cells in declaration order followed by its row slot.
"""
function write_table(io::IO, t::Table)
    h = HashingIO(io)
    write(h, codeunits(FP_TABLE_SEPARATOR))
    CBOR.write_array_header(h, 2)
    CBOR.encode(h, shape_wire(t.shape))
    CBOR.write_array_header(h, nrows(t))
    foreach(i -> write_table_row(h, t, i), sortperm(key_vector(t)))
    return SHA.digest!(h.ctx)
end

"""
    table_hash(table) -> Vector{UInt8}

Return the 32-byte SHA-256 of the table's file as `write_table` streams it: the first
level of the state fingerprint.
"""
table_hash(t::Table) = write_table(devnull, t)

"""
    read_table(io) -> Table

Read one table file as `write_table` wrote it, refusing anything but the canonical form
with a `ModelError`, and malformed CBOR with a `CBOR.DecodeError`. Hashing the bytes
against the file's name is the caller's.
"""
function read_table(io::IO)
    separator = read(io, ncodeunits(FP_TABLE_SEPARATOR))
    separator == codeunits(FP_TABLE_SEPARATOR) || throw(
        ModelError(; detail = NO_SEPARATOR)
    )
    n = CBOR.read_array_header(io)
    n == 2 || throw(
        ModelError(; detail = "$NOT_SHAPE_ROWS $n")
    )
    t = Table(Shape(CBOR.decode(io)))
    n_rows = CBOR.read_array_header(io)
    foreach(i -> read_table_row!(t, io, i), 1:n_rows)
    check_key_order((key_at(t, i) for i in 1:n_rows); context = "in a table file")
    return t
end

function write_table_row(io::IO, t::Table, i::Int)
    CBOR.write_array_header(io, length(t.columns) + 1)
    foreach(column -> CBOR.encode(io, column[i]), t.columns)
    CBOR.encode(io, t.slots[i])
    return nothing
end

# Slot 0 carries no ops, so no row is stamped 0 (ADR-0032).
function read_table_row!(t::Table, io::IO, i::Int)
    row = CBOR.decode(io)
    n = n_columns(t.shape)
    row isa AbstractVector || throw(ModelError(; detail = "row $i is not an array"))
    length(row) == n + 1 || throw(
        ModelError(; detail = row_entries_text(i, length(row), n))
    )
    slot = row[end]
    slot isa Int64 || throw(
        ModelError(; detail = "row $i's slot is not an int64, $GOT_TYPE $(typeof(slot))")
    )
    slot >= 1 ||
        throw(ModelError(; detail = "row $i's slot is $slot; a row slot is at least 1"))
    cells = @view row[1:n]
    check_row(t.shape, cells)
    push_row!(t, cells, slot)
    return nothing
end

function row_entries_text(i, n_entries, n_cells)
    return "row $i has $n_entries entries; a table file row is [cells…, slot], " *
        "$n_cells cells and its row slot"
end
