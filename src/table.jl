# The primitives the seven ops reduce to. Each checks its whole op before it mutates, so a
# refused op leaves the table as it was. Each that changes a row's cells stamps the row
# with `slot`, the slot of the record the op is in (ADR-0032); none has a default for it.

"""
    Table(shape)
    Table(shape, rows, slot)

One table of a content: its shape, columnar storage in declaration order, the row slot of
each row, and an index from key tuple to row. `rows` are checked like an insert and each
is stamped with `slot`. `Table(shape)` is the empty table.
"""
mutable struct Table
    shape::Shape
    columns::Vector{Vector}
    slots::Vector{Int64} # row slot of each row, aligned with the columns
    index::Dict{Any, Int}
end

function Table(s::Shape)
    return Table(s, Vector[column_storage(c) for c in s.columns], Int64[], Dict{Any, Int}())
end

function Table(s::Shape, rows, slot)
    t = Table(s)
    insert_table_rows!(t, rows, slot)
    return t
end

nrows(t::Table) = length(t.slots)
has_row(t::Table, key::Tuple) = haskey(t.index, key)

"""
    row_of(table, key::Tuple) -> Vector{Any}

Return a copy of the row at `key`, its cells in declaration order.
"""
row_of(t::Table, key::Tuple) = row_at(t, t.index[key])

row_at(t::Table, i::Int) = Any[col[i] for col in t.columns]
key_at(t::Table, i::Int) = Tuple(t.columns[j][i] for j in t.shape.keyidx)

"""
    key_vector(table) -> AbstractVector

Return every row's key in storage order: the key column itself when the key is one
column, so a sort runs on a concrete vector; else a vector of key tuples.
"""
function key_vector(t::Table)
    idx = t.shape.keyidx
    length(idx) == 1 && return t.columns[only(idx)]
    return Any[key_at(t, i) for i in 1:nrows(t)]
end

"""
    rows_in_key_order(table)

Return the rows, as vectors of cells in declaration order, in typed key order: the order
of the table file and the state fingerprint.
"""
rows_in_key_order(t::Table) = (row_at(t, i) for i in sortperm(key_vector(t)))

"""
    insert_table_rows!(table, rows, slot) -> nothing

Insert rows (cells in declaration order, in typed key order), each stamped with `slot`.
Throws `ModelError` when `check_insert` fails or a key is present.
"""
function insert_table_rows!(t::Table, rows, slot)
    check_insert(t.shape, rows)
    foreach(row -> check_absent(t, key_of(t.shape, row)), rows)
    foreach(row -> push_row!(t, row, slot), rows)
    return nothing
end

"""
    update_table_rows!(table, names, rows, slot) -> nothing

Set the non-key columns `names` (in declaration order) of the rows named by key. Each
row is `[key…, values…]` and is stamped with `slot`, whether or not its values change.
Throws `ModelError` when `check_update` fails or a key is absent.
"""
function update_table_rows!(t::Table, names, rows, slot)
    columns = check_update(t.shape, names, rows)
    n_key = length(t.shape.keyidx)
    foreach(row -> check_present(t, Tuple(row[1:n_key]), "update"), rows)
    foreach(row -> set_row_values!(t, columns, row, slot), rows)
    return nothing
end

"""
    delete_table_rows!(table, keys) -> nothing

Delete the rows at `keys` (in key declaration order, in typed key order); their slots go
with them. Throws `ModelError` when `check_delete` fails or a key is absent.
"""
function delete_table_rows!(t::Table, keys)
    check_delete(t.shape, keys)
    foreach(k -> check_present(t, Tuple(k), "delete"), keys)
    dropped = Set(t.index[Tuple(k)] for k in keys)
    kept = setdiff(1:nrows(t), dropped)
    t.columns = map(col -> col[kept], t.columns)
    t.slots = t.slots[kept]
    reindex!(t)
    return nothing
end

"""
    append_column!(table, column, fill, slot) -> nothing

Append `column` to the shape and give every row the typed value `fill` (null only in a
nullable column). Every row is stamped with `slot`. Throws `ModelError`.
"""
function append_column!(t::Table, c::Column, fill_value, slot)
    any(x -> x.name == c.name, t.shape.columns) &&
        throw(ModelError(; detail = "column $(repr(c.name)) already exists"))
    check_cell(c, fill_value)
    # The new Shape re-validates the column's name and type before anything mutates.
    shape = Shape(vcat(t.shape.columns, c), t.shape.key)
    column = column_storage(c)
    append!(column, [owned_cell(fill_value) for _ in 1:nrows(t)])
    push!(t.columns, column)
    t.shape = shape
    fill!(t.slots, slot)
    return nothing
end

"""
    remove_column!(table, name, slot) -> nothing

Remove the non-key column `name` from the shape and every row. Every row is stamped with
`slot`. Throws `ModelError` for a key column or an unknown one.
"""
function remove_column!(t::Table, name::AbstractString, slot)
    j = column_index(t.shape, name)
    j in t.shape.keyidx && throw(
        ModelError(; detail = "column $(repr(name)) is a key column and cannot be dropped")
    )
    shape = Shape(deleteat!(copy(t.shape.columns), j), t.shape.key)
    deleteat!(t.columns, j)
    t.shape = shape
    fill!(t.slots, slot)
    return nothing
end

function column_storage(c::Column)
    T = julia_type(c.type)
    return c.nullable ? Vector{Union{Missing, T}}() : Vector{T}()
end

# A bytes cell is copied in, so no caller alias can change content under the model; the
# other carriers are immutable.
owned_cell(x::Vector{UInt8}) = copy(x)
owned_cell(x) = x

function check_absent(t::Table, k::Tuple)
    has_row(t, k) &&
        throw(ModelError(; detail = "insert names a key that is present: $(repr(k))"))
    return nothing
end

function check_present(t::Table, k::Tuple, op_name)
    has_row(t, k) ||
        throw(ModelError(; detail = "$op_name names a key that is absent: $(repr(k))"))
    return nothing
end

function push_row!(t::Table, row, slot)
    foreach((column, x) -> push!(column, owned_cell(x)), t.columns, row)
    push!(t.slots, slot)
    t.index[key_at(t, nrows(t))] = nrows(t)
    return nothing
end

function set_row_values!(t::Table, columns::Vector{Int}, row, slot)
    n_key = length(t.shape.keyidx)
    i = t.index[Tuple(row[1:n_key])]
    for (p, j) in enumerate(columns)
        t.columns[j][i] = owned_cell(row[n_key + p])
    end
    t.slots[i] = slot
    return nothing
end

function reindex!(t::Table)
    empty!(t.index)
    for i in 1:nrows(t)
        t.index[key_at(t, i)] = i
    end
    return nothing
end
