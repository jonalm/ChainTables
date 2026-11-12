# The structural checks of an op, without the table. The write builder and apply run the
# same functions, so what one refuses the other refuses (ADR-0025). They never sort: the
# builder sorts, then checks.

const KEY_CHANGE = "a key never changes (delete then insert)"
const GOT_TYPE = "got a value of type"
const OUT_OF_ORDER = "rows are not in primary-key order:"

"""
    check_cell(column, x) -> nothing

Throw `ModelError` unless `x` is a typed value of the column's value type, or null in a
nullable column.
"""
function check_cell(c::Column, x)
    ismissing(x) && c.nullable && return nothing
    ismissing(x) && throw(
        ModelError(; detail = "column $(repr(c.name)) is $(c.type) and does not admit null")
    )
    value_type(x) == c.type || throw(
        ModelError(; detail = "column $(repr(c.name)) is $(c.type), $GOT_TYPE $(typeof(x))")
    )
    return nothing
end

"""
    check_row(shape, row) -> nothing

Throw `ModelError` unless `row` has one cell per column, each passing `check_cell`.
"""
function check_row(s::Shape, row)
    n = n_columns(s)
    length(row) == n || throw(
        ModelError(; detail = "row has $(length(row)) cells; the shape has $n columns")
    )
    foreach(check_cell, s.columns, row)
    return nothing
end

"""
    check_key_order(keys; context = "inside one op") -> nothing

Throw `ModelError` unless `keys` (tuples in key declaration order) strictly increase in
the typed key order: the canonical form of an op's rows and of a table file. A duplicate
is named with `context`.
"""
function check_key_order(keys; context = "inside one op")
    previous = nothing
    for k in keys
        isnothing(previous) || check_key_follows(previous, k, context)
        previous = k
    end
    return nothing
end

function check_key_follows(previous, k, context)
    isequal(previous, k) &&
        throw(ModelError(; detail = "duplicate key $(repr(k)) $context"))
    isless(previous, k) || throw(
        ModelError(; detail = "$OUT_OF_ORDER $(repr(k)) after $(repr(previous))")
    )
    return nothing
end

"""
    check_insert(shape, rows) -> nothing

Throw `ModelError` unless every row passes `check_row` and the rows are in typed key
order with no duplicate key.
"""
function check_insert(s::Shape, rows)
    foreach(row -> check_row(s, row), rows)
    check_key_order(key_of(s, row) for row in rows)
    return nothing
end

"""
    check_update(shape, names, rows) -> Vector{Int}

Return the declaration positions of `names`, the columns an update changes. Throws
`ModelError` unless `names` are distinct non-key columns in declaration order, at least
one, and each row is `[key…, values…]` of typed values, in typed key order with no
duplicate key.
"""
function check_update(s::Shape, names, rows)
    columns = update_columns(s, names)
    foreach(row -> check_update_row(s, columns, row), rows)
    n_key = length(s.keyidx)
    check_key_order(Tuple(row[1:n_key]) for row in rows)
    return columns
end

function update_columns(s::Shape, names)
    isempty(names) && throw(ModelError(; detail = "update names no non-key column"))
    columns = Int[]
    for name in names
        j = column_index(s, name)
        j in s.keyidx && throw(
            ModelError(; detail = "update names key column $(repr(name)); $KEY_CHANGE")
        )
        j in columns &&
            throw(ModelError(; detail = "duplicate column $(repr(name)) in one update"))
        push!(columns, j)
    end
    issorted(columns) || throw(
        ModelError(; detail = "update columns are not in declaration order: $(repr(names))")
    )
    return columns
end

function check_update_row(s::Shape, columns::Vector{Int}, row)
    n_key = length(s.keyidx)
    n_values = length(columns)
    length(row) == n_key + n_values || throw(
        ModelError(; detail = update_row_text(length(row), n_key, n_values))
    )
    foreach(check_cell, s.columns[s.keyidx], row[1:n_key])
    foreach(check_cell, s.columns[columns], row[(n_key + 1):end])
    return nothing
end

"""
    check_delete(shape, keys) -> nothing

Throw `ModelError` unless every key (a tuple or vector in key declaration order) has one
typed value per key column, and the keys are in typed key order with no duplicate.
"""
function check_delete(s::Shape, keys)
    foreach(k -> check_key_cells(s, Tuple(k)), keys)
    check_key_order(Tuple(k) for k in keys)
    return nothing
end

function check_key_cells(s::Shape, k::Tuple)
    n_key = length(s.keyidx)
    length(k) == n_key || throw(
        ModelError(; detail = "key $(repr(k)) has $(length(k)) cells; the key has $n_key")
    )
    foreach(check_cell, s.columns[s.keyidx], k)
    return nothing
end

function update_row_text(n_cells, n_key, n_values)
    return "update row has $n_cells cells; expected $n_key key cells and $n_values values"
end
