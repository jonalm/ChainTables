# #34 step 2 — ADR-0022, ADR-0025, ADR-0003, ADR-0005, ADR-0007, ADR-0026: model, shape, typed values, key order, table_hash, state fingerprint.

"""
    Model

The content of a local copy as Julia values (ADR-0022): per table, a [`Shape`](@ref)
plus a map from primary key to a row of typed values. Replay, apply and the state
fingerprint run on this and on nothing else; no engine sits on the path. Nothing
here is exported (ADR-0019); the read surface (`TableView`) and the write builder
sit on top of it, and every name is internal.

# Typed values (ADR-0025)

A cell holds one of the four value types or null where the shape allows it. The
carriers are exactly `Int64`, `Float64`, `String`, `Vector{UInt8}` and `missing`;
nothing is widened, converted or rendered here (*apply never computes*). A value
of any other type — `Int32`, `Bool`, a `SubString` — is refused, because the
model is the last stop before the frozen encoder and the fingerprint.

# Key order (ADR-0025)

Rows are ordered by the primary key under the typed order, which is exactly
Julia's `isless` and `isequal` on the key tuple: `int64` numerically; `float64`
by IEEE value with `-0.0 < 0.0`, `-0.0 ≠ 0.0`, and NaN equal to itself and after
`+Inf`; `text` and `bytes` bytewise; a composite key lexicographically in key
declaration order. The index is a `Dict` keyed by that tuple, so `-0.0` and
`0.0` are two rows and NaN finds itself.

# The byte stream (ADR-0007, ADR-0023)

    table_hash        = SHA-256("chaintables/v1/fp-table" ‖ cbor([shape, rows]))
    state_fingerprint = SHA-256("chaintables/v1/fp"       ‖ cbor([[name, table_hash], …]))

[`write_table`](@ref) streams exactly the `table_hash` byte stream, separator
included, so a table file's name is `sha256sum` of the file; [`read_table`](@ref)
inverts it and refuses anything but the canonical form. [`state_fingerprint`](@ref)
takes the `[name, hash]` list sorted by name — the head file's `tables` list.

# Errors

Every rule the model enforces raises [`ModelError`](@ref), which is internal: the
write builder folds it into `WriteBuilderError` and apply into
`MalformedRecordError` naming the slot and op (ADR-0020, ADR-0025), so the
builder's checks and apply's are one code path. What makes an op canonical —
rows in typed key order, no duplicate key, update columns in declaration order —
is decided here and nowhere else: the builder produces that form and the
primitives refuse anything else, they never sort. Each batch primitive validates
its whole op before it mutates anything, so a refused op leaves the table as it
was.

# Resident representation

Columnar vectors in declaration order — `Vector{T}`, or `Vector{Union{Missing,T}}`
for a nullable column — plus a `Dict` from key tuple to row index (ADR-0025's
recommendation). Rows are appended in arrival order and sorted by key when
encoded, so an untouched table is never re-sorted.
"""
module Model

import SHA
using ..CBOR

const FP_TABLE_SEPARATOR = "chaintables/v1/fp-table"   # ADR-0026
const FP_SEPARATOR = "chaintables/v1/fp"

"""
    ModelError(msg)

A rule of the model broken: a malformed shape, a cell of the wrong value type,
null in a non-nullable column, an op that contradicts the content (insert on a
present key, update or delete on an absent one), rows out of key order.
Internal: the write builder raises it as `WriteBuilderError`, apply as
`MalformedRecordError` (ADR-0025).
"""
struct ModelError <: Exception
    msg::String
end

Base.showerror(io::IO, e::ModelError) = print(io, "ModelError: ", e.msg)

fail(msg) = throw(ModelError(msg))

# ---------------------------------------------------------------------------
# Value types (ADR-0025)
# ---------------------------------------------------------------------------

const VALUE_TYPES = ("int64", "float64", "text", "bytes")

"""
    julia_type(value_type) -> Type

The one Julia carrier of a wire value type: `"int64" => Int64`, `"float64" =>
Float64`, `"text" => String`, `"bytes" => Vector{UInt8}`.
"""
julia_type(t::AbstractString) =
    t == "int64" ? Int64 : t == "float64" ? Float64 : t == "text" ? String :
    t == "bytes" ? Vector{UInt8} : fail("unknown value type $(repr(t)); a column holds int64, float64, text or bytes")

"""
    value_type(x) -> String or nothing

The wire value type `x` is a carrier of, or `nothing` if it is not exactly one
of the four (so `missing`, `Bool`, `Int32` and a `SubString` all give `nothing`).
"""
value_type(::Int64) = "int64"
value_type(::Float64) = "float64"
value_type(::String) = "text"
value_type(::Vector{UInt8}) = "bytes"
value_type(::Any) = nothing

"""
    is_identifier(s) -> Bool

The identifier charset for table and column names: `[a-z_][a-z0-9_]*` (ADR-0025).
"""
is_identifier(s::AbstractString) = occursin(r"^[a-z_][a-z0-9_]*$", s)

# ---------------------------------------------------------------------------
# Shape (ADR-0003, ADR-0025)
# ---------------------------------------------------------------------------

"""
    Column(name, type, nullable)

One column of a shape: its name, its wire value type (`"int64"`, `"float64"`,
`"text"`, `"bytes"`) and whether it admits null.
"""
struct Column
    name::String
    type::String
    nullable::Bool
end

"""
    Shape(columns::Vector{Column}, key::Vector{String})
    Shape(wire::AbstractDict)

A table's shape: columns in declaration order and the primary key in key
declaration order (ADR-0003). The constructor enforces every structural rule —
at least one column, identifier names, no duplicate column, a known value type,
a non-empty key of distinct, existing, non-nullable columns — and raises
[`ModelError`](@ref) otherwise. The second form reads the wire form
`{"columns": [[name, type, nullable], …], "key": [name, …]}` as `CBOR.decode`
yields it, refusing any other field; [`wire`](@ref) is its inverse.
"""
struct Shape
    columns::Vector{Column}
    key::Vector{String}
    keyidx::Vector{Int}          # key column positions, in key declaration order
    function Shape(columns, key)
        columns = collect(Column, columns)
        key = collect(String, key)
        isempty(columns) && fail("table has no columns")
        names = String[]
        for c in columns
            is_identifier(c.name) || fail("column name $(repr(c.name)) is not an identifier ([a-z_][a-z0-9_]*)")
            c.name in names && fail("duplicate column name $(repr(c.name))")
            c.type in VALUE_TYPES || fail("unknown value type $(repr(c.type)); a column holds int64, float64, text or bytes")
            push!(names, c.name)
        end
        isempty(key) && fail("table has no primary key; every table needs an explicit key")
        keyidx = Int[]
        for k in key
            j = findfirst(==(k), names)
            j === nothing && fail("key column $(repr(k)) is not a column of the table")
            j in keyidx && fail("duplicate key column $(repr(k))")
            columns[j].nullable && fail("key column $(repr(k)) is nullable; key columns are non-nullable")
            push!(keyidx, j)
        end
        return new(columns, key, keyidx)
    end
end

Base.:(==)(a::Shape, b::Shape) = a.columns == b.columns && a.key == b.key

function Shape(w::AbstractDict)
    for k in keys(w)
        k in ("columns", "key") || fail("unknown shape field $(repr(k))")
    end
    haskey(w, "columns") || fail("shape has no \"columns\"")
    haskey(w, "key") || fail("shape has no \"key\"")
    cols = w["columns"]
    cols isa AbstractVector || fail("shape \"columns\" is not an array")
    columns = Column[]
    for e in cols
        e isa AbstractVector && length(e) == 3 && e[1] isa String && e[2] isa String && e[3] isa Bool ||
            fail("column entry $(repr(e)) is not [name, type, nullable]")
        push!(columns, Column(e[1], e[2], e[3]))
    end
    key = w["key"]
    key isa AbstractVector && all(k -> k isa String, key) || fail("shape \"key\" is not an array of names")
    return Shape(columns, String[key...])
end
Shape(w) = fail("shape is not a map, got a value of type $(typeof(w))")

"""
    wire(shape) -> Dict

The shape's wire form, ready for `CBOR.encode` (ADR-0025): one encoding whether it
sits in a table file or in a `create_table` op.
"""
wire(s::Shape) = Dict{String,Any}(
    "columns" => Any[Any[c.name, c.type, c.nullable] for c in s.columns],
    "key" => Any[s.key...],
)

ncols(s::Shape) = length(s.columns)

"""
    column_index(shape, name) -> Int

The declaration position of column `name`; a [`ModelError`](@ref) if there is none.
"""
function column_index(s::Shape, name::AbstractString)
    j = findfirst(c -> c.name == name, s.columns)
    j === nothing && fail("unknown column $(repr(name))")
    return j
end

"""
    key_of(shape, row) -> Tuple

The primary key of a row (a vector of cells in declaration order), as the tuple
the typed key order and the index are defined on.
"""
key_of(s::Shape, row) = Tuple(row[j] for j in s.keyidx)

# ---------------------------------------------------------------------------
# Cell and row checks — the one code path the builder and apply share
# ---------------------------------------------------------------------------

"""
    check_cell(column, x) -> nothing

`x` is a typed value of the column's value type, or null where the column is
nullable; a [`ModelError`](@ref) otherwise.
"""
function check_cell(c::Column, x)
    if x === missing
        c.nullable || fail("column $(repr(c.name)) is $(c.type) and does not admit null")
    else
        value_type(x) == c.type || fail("column $(repr(c.name)) is $(c.type), got a value of type $(typeof(x))")
    end
    return nothing
end

"""
    check_row(shape, row) -> nothing

`row` has one cell per column, each passing [`check_cell`](@ref).
"""
function check_row(s::Shape, row)
    length(row) == ncols(s) || fail("row has $(length(row)) cells; the shape has $(ncols(s)) columns")
    for (c, x) in zip(s.columns, row)
        check_cell(c, x)
    end
    return nothing
end

"""
    check_key_order(keys; context = "inside one op") -> nothing

`keys` (tuples in key declaration order) are strictly increasing under the
typed key order: the canonical form of an op's rows and of a table file
(ADR-0025). The one place the rule lives: [`check_insert`](@ref),
[`check_update`](@ref), [`check_delete`](@ref) and [`read_table`](@ref) all run
it, so the builder, apply and the table file agree on what is refused. A
duplicate is named with `context`; the order message is the same everywhere.
"""
function check_key_order(keys; context = "inside one op")
    prev = nothing
    started = false
    for k in keys
        if started
            isequal(prev, k) && fail("duplicate key $(repr(k)) $context")
            isless(prev, k) || fail("rows are not in primary-key order: $(repr(k)) after $(repr(prev))")
        end
        prev = k
        started = true
    end
    return nothing
end

"""
    check_insert(shape, rows) -> nothing

The structural half of an insert, without the table: every row passes
[`check_row`](@ref) and the rows are the canonical payload — in typed key
order, no duplicate key ([`check_key_order`](@ref)). The write builder sorts
and then runs exactly this in `insert_rows!`; [`insert_rows!`](@ref) runs it
and then the state gate, so the two are one code path (ADR-0025).
"""
function check_insert(s::Shape, rows)
    for row in rows
        check_row(s, row)
    end
    check_key_order(key_of(s, row) for row in rows)
    return nothing
end

"""
    check_update(shape, names, rows) -> Vector{Int}

The structural half of an update, without the table: `names` are distinct
non-key columns, at least one, in declaration order; each row is `[key…,
values…]` with the right cell count, every cell of its column's value type;
the rows in typed key order with no duplicate key ([`check_key_order`](@ref)).
Returns the declaration positions of `names`. The write builder orders the
columns, sorts the rows and then runs exactly this in `update_rows!`;
[`update_rows!`](@ref) runs it and then the state gate.
"""
function check_update(s::Shape, names, rows)
    isempty(names) && fail("update names no non-key column")
    cols = Int[]
    for n in names
        j = column_index(s, n)
        j in s.keyidx && fail("update names key column $(repr(n)); a key never changes (delete then insert)")
        j in cols && fail("duplicate column $(repr(n)) in one update")
        push!(cols, j)
    end
    issorted(cols) || fail("update columns are not in declaration order: $(repr(names))")
    nk = length(s.keyidx)
    for row in rows
        length(row) == nk + length(cols) ||
            fail("update row has $(length(row)) cells; expected $nk key cells and $(length(cols)) values")
        for (i, j) in enumerate(s.keyidx)
            check_cell(s.columns[j], row[i])
        end
        for (p, j) in enumerate(cols)
            check_cell(s.columns[j], row[nk+p])
        end
    end
    check_key_order(Tuple(row[1:nk]) for row in rows)
    return cols
end

"""
    check_delete(shape, keys) -> nothing

The structural half of a delete, without the table: every key (a tuple or
vector in key declaration order) has one cell per key column, each of its
column's value type; the keys in typed key order with no duplicate
([`check_key_order`](@ref)). The write builder sorts and then runs exactly
this in `delete_rows!`; [`delete_rows!`](@ref) runs it and then the state gate.
"""
function check_delete(s::Shape, ks)
    for k in ks
        k = Tuple(k)
        length(k) == length(s.keyidx) || fail("key $(repr(k)) has $(length(k)) cells; the key has $(length(s.keyidx))")
        for (i, j) in enumerate(s.keyidx)
            check_cell(s.columns[j], k[i])
        end
    end
    check_key_order(Tuple(k) for k in ks)
    return nothing
end

# ---------------------------------------------------------------------------
# Table: shape + columnar rows + key index
# ---------------------------------------------------------------------------

"""
    Table(shape)
    Table(shape, rows)

One table of the model: its [`Shape`](@ref), columnar storage and a `Dict` from
key tuple to row index. `rows` are vectors of cells in declaration order, checked
like an insert (types, nullability, typed key order, no duplicate key): the
canonical payload, as an op or a table file carries it.
"""
mutable struct Table
    shape::Shape
    columns::Vector{Vector}
    index::Dict{Any,Int}
end

column_storage(c::Column) = c.nullable ? Vector{Union{Missing,julia_type(c.type)}}() : Vector{julia_type(c.type)}()

Table(s::Shape) = Table(s, Vector[column_storage(c) for c in s.columns], Dict{Any,Int}())

function Table(s::Shape, rows)
    t = Table(s)
    insert_rows!(t, rows)
    return t
end

nrows(t::Table) = isempty(t.columns) ? 0 : length(t.columns[1])
Base.haskey(t::Table, key::Tuple) = haskey(t.index, key)
"""
    getrow(table, key::Tuple) -> Vector{Any}

The row at `key`, cells in declaration order, copied out of the columns.
"""
getrow(t::Table, key::Tuple) = row_at(t, t.index[key])
row_at(t::Table, i::Int) = Any[col[i] for col in t.columns]
key_at(t::Table, i::Int) = Tuple(t.columns[j][i] for j in t.shape.keyidx)

# A bytes cell is copied in so no caller alias can change content under the
# model; the other carriers are immutable.
own(x::Vector{UInt8}) = copy(x)
own(x) = x

# The key sequence of every row, typed when the key is one column so the sort
# runs on a concrete vector.
function key_vector(t::Table)
    idx = t.shape.keyidx
    return length(idx) == 1 ? t.columns[idx[1]] : Any[key_at(t, i) for i in 1:nrows(t)]
end

"""
    rows_in_key_order(table)

The rows as vectors of cells in declaration order, sorted by the typed key order
— the order the table file and the fingerprint use.
"""
rows_in_key_order(t::Table) = (row_at(t, i) for i in sortperm(key_vector(t)))

# ---------------------------------------------------------------------------
# The primitives the seven ops reduce to (ADR-0022). Each checks its whole op,
# then mutates.
# ---------------------------------------------------------------------------

"""
    insert_rows!(table, rows) -> nothing

Insert rows (vectors of cells in declaration order, in typed key order):
[`check_insert`](@ref), then the state gate of ADR-0001 — every key absent
from the table; nothing is written if any check fails.
"""
function insert_rows!(t::Table, rows)
    check_insert(t.shape, rows)
    for row in rows
        k = key_of(t.shape, row)
        haskey(t.index, k) && fail("insert names a key that is present: $(repr(k))")
    end
    for row in rows
        push_row!(t, row)
    end
    return nothing
end

function push_row!(t::Table, row)
    for (col, x) in zip(t.columns, row)
        push!(col, own(x))
    end
    t.index[key_at(t, nrows(t))] = nrows(t)
    return nothing
end

"""
    update_rows!(table, names, rows) -> nothing

Update the non-key columns `names` (in declaration order) of the rows named by
their key. Each row is `[key…, values…]`: the full key in key declaration order
followed by one value per name, and the rows are in typed key order (ADR-0005,
ADR-0025). [`check_update`](@ref), then the state gate — every key present in
the table; nothing is written if any check fails.
"""
function update_rows!(t::Table, names, rows)
    cols = check_update(t.shape, names, rows)
    nk = length(t.shape.keyidx)
    for row in rows
        k = Tuple(row[1:nk])
        haskey(t.index, k) || fail("update names a key that is absent: $(repr(k))")
    end
    for row in rows
        i = t.index[Tuple(row[1:nk])]
        for (p, j) in enumerate(cols)
            t.columns[j][i] = own(row[nk+p])
        end
    end
    return nothing
end

"""
    delete_rows!(table, keys) -> nothing

Delete the rows at `keys` (tuples in key declaration order, in typed key
order): [`check_delete`](@ref), then the state gate — every key present in the
table; nothing is written if any check fails.
"""
function delete_rows!(t::Table, ks)
    check_delete(t.shape, ks)
    for k in ks
        k = Tuple(k)
        haskey(t.index, k) || fail("delete names a key that is absent: $(repr(k))")
    end
    drop = falses(nrows(t))
    for k in ks
        drop[t.index[Tuple(k)]] = true
    end
    keep = findall(!, drop)
    for j in eachindex(t.columns)
        t.columns[j] = t.columns[j][keep]
    end
    reindex!(t)
    return nothing
end

function reindex!(t::Table)
    empty!(t.index)
    for i in 1:nrows(t)
        t.index[key_at(t, i)] = i
    end
    return nothing
end

"""
    add_column!(table, column, fill) -> nothing

Append a column to the shape and give every row the typed value `fill`, checked
against the column: null only if it is nullable (ADR-0025).
"""
function add_column!(t::Table, c::Column, fillvalue)
    any(x -> x.name == c.name, t.shape.columns) && fail("column $(repr(c.name)) already exists")
    check_cell(c, fillvalue)
    shape = Shape(vcat(t.shape.columns, c), t.shape.key)   # re-validates the name and type
    col = column_storage(c)
    for _ in 1:nrows(t)
        push!(col, own(fillvalue))
    end
    push!(t.columns, col)
    t.shape = shape
    return nothing
end

"""
    drop_column!(table, name) -> nothing

Remove a non-key column from the shape and from every row. Refuses a key column
and nothing else (ADR-0025).
"""
function drop_column!(t::Table, name::AbstractString)
    j = column_index(t.shape, name)
    j in t.shape.keyidx && fail("column $(repr(name)) is a key column and cannot be dropped")
    shape = Shape(deleteat!(copy(t.shape.columns), j), t.shape.key)
    deleteat!(t.columns, j)
    t.shape = shape
    return nothing
end

# ---------------------------------------------------------------------------
# Content: the tables of a local copy, by name
# ---------------------------------------------------------------------------

"""
    Content

The whole model: every table the chain created, by name. A `Dict{String,Table}`;
[`create_table!`](@ref), [`drop_table!`](@ref) and [`table`](@ref) enforce the
name rules on top of it.
"""
const Content = Dict{String,Table}

"""
    create_table!(content, name, shape) -> Table

Add an empty table under `name`, which must be an identifier not yet in use.
"""
function create_table!(c::Content, name::AbstractString, s::Shape)
    is_identifier(name) || fail("table name $(repr(name)) is not an identifier ([a-z_][a-z0-9_]*)")
    haskey(c, name) && fail("table $(repr(name)) already exists")
    return c[name] = Table(s)
end

"""
    drop_table!(content, name) -> nothing
"""
function drop_table!(c::Content, name::AbstractString)
    haskey(c, name) || fail("unknown table $(repr(name))")
    delete!(c, name)
    return nothing
end

"""
    table(content, name) -> Table

The table under `name`; a [`ModelError`](@ref) if there is none.
"""
function table(c::Content, name::AbstractString)
    haskey(c, name) || fail("unknown table $(repr(name))")
    return c[name]
end

# ---------------------------------------------------------------------------
# table_hash, the table file stream, state_fingerprint (ADR-0007, ADR-0023)
# ---------------------------------------------------------------------------

# An IO that hashes everything written through it, so a table file is hashed as
# it is streamed rather than buffered (ADR-0023's 1 GB ceiling).
mutable struct HashingIO{T<:IO} <: IO
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

Stream the table's file to `io` — `"chaintables/v1/fp-table" ‖ cbor([shape, rows])`
with rows in typed key order — and return its SHA-256, which is the
[`table_hash`](@ref) and the file's name (ADR-0007, ADR-0023).
"""
function write_table(io::IO, t::Table)
    h = HashingIO(io)
    write(h, codeunits(FP_TABLE_SEPARATOR))
    CBOR.write_array_header(h, 2)
    CBOR.encode(h, wire(t.shape))
    CBOR.write_array_header(h, nrows(t))
    for row in rows_in_key_order(t)
        CBOR.encode(h, row)
    end
    return SHA.digest!(h.ctx)
end

"""
    table_hash(table) -> Vector{UInt8}

`SHA-256("chaintables/v1/fp-table" ‖ cbor([shape, rows]))`, 32 bytes: the
first level of the state fingerprint and the name of the table's file.
"""
table_hash(t::Table) = write_table(devnull, t)

"""
    read_table(io) -> Table

Read one table file stream as [`write_table`](@ref) wrote it. Refuses anything
but the canonical form — a wrong separator, a wrong outer arity, a malformed
shape, a cell off its value type, rows out of key order or duplicated — with a
[`ModelError`](@ref), and malformed CBOR with `CBOR.DecodeError`. Hashing the
bytes against the file's name is the caller's (ADR-0023, hash before use).
"""
function read_table(io::IO)
    magic = read(io, ncodeunits(FP_TABLE_SEPARATOR))
    magic == codeunits(FP_TABLE_SEPARATOR) ||
        fail("not a table file: expected the separator $(repr(FP_TABLE_SEPARATOR))")
    n = CBOR.read_array_header(io)
    n == 2 || fail("not a table file: expected [shape, rows], got an array of $n")
    shape = Shape(CBOR.decode(io))
    t = Table(shape)
    nr = CBOR.read_array_header(io)
    for i in 1:nr
        row = CBOR.decode(io)
        row isa AbstractVector || fail("row $i is not an array")
        check_row(shape, row)
        push_row!(t, row)
    end
    check_key_order((key_at(t, i) for i in 1:nr); context = "in a table file")
    return t
end

"""
    state_fingerprint(tables) -> Vector{UInt8}
    state_fingerprint(content::Content) -> Vector{UInt8}

`SHA-256("chaintables/v1/fp" ‖ cbor([[name, table_hash], …]))` over `name =>
table_hash` pairs sorted by name, 32 bytes (ADR-0007). The first form is what
the head file's `tables` list feeds it; the second hashes every table of a
content first.
"""
function state_fingerprint(tables)
    entries = sort!([(String(first(p)), last(p)) for p in tables]; by = first)
    for i in eachindex(entries)
        name, h = entries[i]
        h isa AbstractVector{UInt8} && length(h) == 32 ||
            fail("table_hash of $(repr(name)) is $(h isa AbstractVector{UInt8} ? length(h) : "not") bytes; a SHA-256 is 32")
        i > 1 && entries[i-1][1] == name && fail("duplicate table name $(repr(name))")
    end
    io = IOBuffer()
    write(io, codeunits(FP_SEPARATOR))
    CBOR.encode(io, Any[Any[name, Vector{UInt8}(h)] for (name, h) in entries])
    return SHA.sha256(take!(io))
end

state_fingerprint(c::Content) = state_fingerprint(name => table_hash(t) for (name, t) in c)

end # module Model
