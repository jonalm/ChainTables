const KEY_NEVER_CHANGES = "a key never changes (delete then insert)"

# The builder and apply share these checks, so what makes an op canonical is decided
# here and nowhere else (ADR-0025): the builder produces that form, and the checks
# refuse anything else. They never sort.

function check_cell(c::Column, x)
    ismissing(x) && !c.nullable && throw(
        ModelError("column $(repr(c.name)) is $(c.type) and does not admit null")
    )
    ismissing(x) || typeof(x) === get(CARRIERS, c.type, nothing) || throw(
        ModelError("column $(repr(c.name)) is $(c.type), got a value of type $(typeof(x))")
    )
    return nothing
end

function check_row(s::Shape, row)
    n_columns = length(s.columns)
    length(row) == n_columns || throw(
        ModelError("row has $(length(row)) cells; the shape has $n_columns columns")
    )
    foreach(check_cell, s.columns, row)
    return nothing
end

# Strictly increasing under the typed key order, which is Julia's `isless` and
# `isequal` on the key tuple: -0.0 < 0.0, NaN equals itself and sorts after +Inf, text
# and bytes compare bytewise, a composite key lexicographically (ADR-0025).
function check_key_order(keys; context = "inside one op")
    previous = nothing
    for key in keys
        if previous !== nothing
            isequal(previous, key) &&
                throw(ModelError("duplicate key $(repr(key)) $context"))
            isless(previous, key) || throw(ModelError(out_of_order(key, previous)))
        end
        previous = key
    end
    return nothing
end

function out_of_order(key, previous)
    return "rows are not in primary-key order: $(repr(key)) after $(repr(previous))"
end

function check_insert(s::Shape, rows)
    foreach(row -> check_row(s, row), rows)
    check_key_order(key_of(s, row) for row in rows)
    return nothing
end

# Returns the declaration positions of `names`. Each row is `[key…, values…]`.
function check_update(s::Shape, names, rows)
    positions = update_positions(s, names)
    n_key = length(s.key_positions)
    columns = s.columns[vcat(s.key_positions, positions)]
    foreach(row -> check_update_row(columns, n_key, row), rows)
    check_key_order(Tuple(row[1:n_key]) for row in rows)
    return positions
end

function update_positions(s::Shape, names)
    isempty(names) && throw(ModelError("update names no non-key column"))
    positions = Int[]
    for name in names
        j = column_index(s, name)
        j in s.key_positions &&
            throw(ModelError("update names key column $(repr(name)); $KEY_NEVER_CHANGES"))
        j in positions && throw(ModelError("duplicate column $(repr(name)) in one update"))
        push!(positions, j)
    end
    issorted(positions) || throw(
        ModelError("update columns are not in declaration order: $(repr(names))")
    )
    return positions
end

function check_update_row(columns, n_key, row)
    n_cells = length(columns)
    expected = "expected $n_key key cells and $(n_cells - n_key) values"
    length(row) == n_cells ||
        throw(ModelError("update row has $(length(row)) cells; $expected"))
    foreach(check_cell, columns, row)
    return nothing
end

function check_delete(s::Shape, keys)
    key_columns = s.columns[s.key_positions]
    foreach(key -> check_key(key_columns, Tuple(key)), keys)
    check_key_order(Tuple(key) for key in keys)
    return nothing
end

function check_key(key_columns, key::Tuple)
    n_key = length(key_columns)
    length(key) == n_key || throw(
        ModelError("key $(repr(key)) has $(length(key)) cells; the key has $n_key")
    )
    foreach(check_cell, key_columns, key)
    return nothing
end
