const Key = Tuple{Vararg{Union{CARRIER_TYPES...}}}
const ColumnVector = Union{
    map(T -> Vector{T}, CARRIER_TYPES)...,
    map(T -> Vector{Union{Missing, T}}, CARRIER_TYPES)...,
}

# Rows are appended in arrival order and sorted by key only when encoded, so an
# untouched table is never sorted again (ADR-0025).
"""
    Table(shape)
    Table(shape, rows, slot)

One table of the model: its `Shape`, one typed vector per column, each row's row slot
and an index from key tuple to row.

`rows` are vectors of cells in declaration order, in typed key order with no duplicate
key, checked like an insert. Every row is stamped with `slot`. `Table(shape)` is the
empty table. Throws the internal `ModelError` when a row breaks a rule.

Examples: test/test_model_table_examples.jl
"""
mutable struct Table
    shape::Shape
    columns::Vector{ColumnVector}  # one per shape column, in declaration order
    slots::Vector{Int64}  # the row slot of each row, aligned with the columns
    index::Dict{Key, Int}  # key tuple => row position
end

Table(s::Shape) = Table(s, map(column_storage, s.columns), Int64[], Dict{Key, Int}())

function Table(s::Shape, rows, slot)
    t = Table(s)
    insert_rows!(t, rows, slot)
    return t
end

function column_storage(c::Column)
    T = julia_type(c.type)
    return c.nullable ? Vector{Union{Missing, T}}() : Vector{T}()
end

n_rows(t::Table) = length(t.slots)

key_at(t::Table, i::Int) = Tuple(t.columns[j][i] for j in t.shape.key_positions)

# Typed when the key is one column, so that the sort runs on a concrete vector.
function key_vector(t::Table)
    positions = t.shape.key_positions
    length(positions) == 1 && return t.columns[only(positions)]
    return Key[key_at(t, i) for i in 1:n_rows(t)]
end

# Each primitive below checks its whole op before it changes anything, so a refused op
# leaves the table as it was. Each one that changes a row's cells stamps the row with
# `slot`, the slot of the record the op is in (ADR-0032).

function insert_rows!(t::Table, rows, slot)
    check_insert(t.shape, rows)
    foreach(row -> check_absent(t, key_of(t.shape, row)), rows)
    foreach(row -> push_row!(t, row, slot), rows)
    return nothing
end

function check_absent(t::Table, key)
    haskey(t.index, key) &&
        throw(ModelError("insert names a key that is present: $(repr(key))"))
    return nothing
end

function push_row!(t::Table, row, slot)
    foreach((column, x) -> push!(column, owned_cell(x)), t.columns, row)
    push!(t.slots, slot)
    t.index[key_at(t, n_rows(t))] = n_rows(t)
    return nothing
end

# A bytes cell is copied in, so that no caller's alias can change content under the
# model. The other carriers are immutable.
owned_cell(x::Vector{UInt8}) = copy(x)
owned_cell(x) = x

# A named row is stamped whether or not its values change: apply never compares them.
function update_rows!(t::Table, names, rows, slot)
    positions = check_update(t.shape, names, rows)
    n_key = length(t.shape.key_positions)
    foreach(row -> check_present(t, Tuple(row[1:n_key]), "update"), rows)
    foreach(row -> set_row!(t, positions, row, slot), rows)
    return nothing
end

function check_present(t::Table, key, op)
    haskey(t.index, key) ||
        throw(ModelError("$op names a key that is absent: $(repr(key))"))
    return nothing
end

function set_row!(t::Table, positions, row, slot)
    n_key = length(t.shape.key_positions)
    i = t.index[Tuple(row[1:n_key])]
    for (p, j) in enumerate(positions)
        t.columns[j][i] = owned_cell(row[n_key + p])
    end
    t.slots[i] = slot
    return nothing
end

function delete_rows!(t::Table, keys)
    check_delete(t.shape, keys)
    foreach(key -> check_present(t, Tuple(key), "delete rows"), keys)
    keep = setdiff(1:n_rows(t), (t.index[Tuple(key)] for key in keys))
    t.columns = map(column -> column[keep], t.columns)
    t.slots = t.slots[keep]
    reindex!(t)
    return nothing
end

function reindex!(t::Table)
    empty!(t.index)
    for i in 1:n_rows(t)
        t.index[key_at(t, i)] = i
    end
    return nothing
end

# Every row's cells change, so every row is stamped with `slot`.
function add_column!(t::Table, c::Column, fill_value, slot)
    any(x -> x.name == c.name, t.shape.columns) &&
        throw(ModelError("column $(repr(c.name)) already exists"))
    check_cell(c, fill_value)
    shape = Shape(vcat(t.shape.columns, c), t.shape.key)
    column = column_storage(c)
    append!(column, (owned_cell(fill_value) for _ in 1:n_rows(t)))
    push!(t.columns, column)
    t.shape = shape
    fill!(t.slots, slot)
    return nothing
end

# Every row's cells change, so every row is stamped with `slot`.
function drop_column!(t::Table, name::AbstractString, slot)
    j = column_index(t.shape, name)
    j in t.shape.key_positions &&
        throw(ModelError("column $(repr(name)) is a key column and cannot be dropped"))
    shape = Shape(deleteat!(copy(t.shape.columns), j), t.shape.key)
    deleteat!(t.columns, j)
    t.shape = shape
    fill!(t.slots, slot)
    return nothing
end
