"""
    insert_rows!(w, table, rows)

Add the op that inserts a row set into `table`.

`rows` is any collection of rows: `NamedTuple`s or Tables.jl rows. Every row names every
column of the table, in any order. Cells widen and are checked against the shape, and
the keys are distinct within the op. Throws `WriteBuilderError` for a row set that
breaks a rule. `commit!` refuses an insert on a key that is present.

Examples: test/test_row_ops_examples.jl
"""
function insert_rows!(w::WriteBuilder, table, rows)
    return add_op!(insert_op, w, "insert_rows!(w, $(repr(table)))", table, rows)
end

"""
    update_rows!(w, table, rows)

Add the op that updates a row set of `table`.

Every row names the full primary key and the same non-empty set of other columns: the
columns that change. A key never changes; delete the row and insert it again. Throws
`WriteBuilderError` for a row set that breaks a rule. `commit!` refuses an update on a
key that is absent.

Examples: test/test_row_ops_examples.jl
"""
function update_rows!(w::WriteBuilder, table, rows)
    return add_op!(update_op, w, "update_rows!(w, $(repr(table)))", table, rows)
end

"""
    delete_rows!(w, table, rows)

Add the op that deletes a row set from `table`.

Every row names the key columns and nothing else. Throws `WriteBuilderError` for a row
set that breaks a rule. `commit!` refuses a delete on a key that is absent.

Examples: test/test_row_ops_examples.jl
"""
function delete_rows!(w::WriteBuilder, table, rows)
    return add_op!(delete_op, w, "delete_rows!(w, $(repr(table)))", table, rows)
end

# Each op holds its rows in typed key order, with the cells of an insert in declaration
# order (ADR-0025).
function insert_op(w::WriteBuilder, table, rows)
    text = name_text("table", table)
    s = scratch_table(w, text).shape
    row_set, names = named_rows(rows)
    foreach(name -> Model.column_index(s, String(name)), names)
    all_names = map(c -> c.name, s.columns)
    check_names_each(names, all_names, "column", "an insert names every column")
    cells = [canonical_cells(s.columns, row) for row in row_set]
    sort_by_key!(row -> Model.key_of(s, row), cells, s.columns)
    Model.check_insert(s, cells)
    return Ops.Insert(text, cells)
end

# An update row is `[key…, values…]`: the key in key declaration order, then the
# changed columns in declaration order.
function update_op(w::WriteBuilder, table, rows)
    text = name_text("table", table)
    s = scratch_table(w, text).shape
    row_set, names = named_rows(rows)
    foreach(name -> Model.column_index(s, String(name)), names)
    check_names_each(names, s.key, "key column", "an update names the full key")
    key_columns = s.columns[s.key_positions]
    changed = [c for c in s.columns if Symbol(c.name) in names && c.name ∉ s.key]
    columns = vcat(key_columns, changed)
    cells = [canonical_cells(columns, row) for row in row_set]
    n_key = length(key_columns)
    sort_by_key!(row -> Tuple(row[1:n_key]), cells, columns)
    changed_names = String[c.name for c in changed]
    Model.check_update(s, changed_names, cells)
    return Ops.Update(text, changed_names, cells)
end

function delete_op(w::WriteBuilder, table, rows)
    text = name_text("table", table)
    s = scratch_table(w, text).shape
    row_set, names = named_rows(rows)
    foreach(name -> check_is_key_column(s, String(name)), names)
    check_names_each(names, s.key, "key column", "a delete names the full key")
    key_columns = s.columns[s.key_positions]
    cells = [canonical_cells(key_columns, row) for row in row_set]
    sort_by_key!(Tuple, cells, key_columns)
    Model.check_delete(s, cells)
    return Ops.Delete(text, cells)
end

function check_names_each(names, wanted, kind, rule)
    absent = findfirst(name -> Symbol(name) ∉ names, wanted)
    absent === nothing || throw(
        Model.ModelError("row set names no $kind $(repr(wanted[absent])); $rule")
    )
    return nothing
end

function check_is_key_column(s::Model.Shape, name)
    column = s.columns[Model.column_index(s, name)]
    column.name in s.key || throw(
        Model.ModelError(
            "row set names column $(repr(name)); a delete names the key columns only"
        )
    )
    return nothing
end

# The cells are checked before the sort: `isless` on two key cells of different types
# would throw a `MethodError`. Each row has one cell per column, so no lengths are
# compared.
function sort_by_key!(key_of::F, rows, columns) where {F}
    foreach(row -> foreach(Model.check_cell, columns, row), rows)
    return sort!(rows; by = key_of)
end
