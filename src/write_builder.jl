const SPENT_AT_COMMIT = "commit!(w): this builder is spent; a builder is used once, " *
    "take a new one with write_builder(copy)"
const SPENT = "this builder is spent; commit! consumed it, take a new one with " *
    "write_builder(copy)"

# A scratch table holds a shape and never rows, so the slot that a column op stamps on
# it reaches no row (ADR-0032).
const SCRATCH_SLOT = 0

"""
    WriteBuilder

The write builder: the ops of one transaction record, collected by the op functions and
consumed by `commit!`. Taken with `write_builder(copy)` and used once.

It holds no rows of the local copy, only the shape of each table it names, as its own
`create_table!`, `add_column!`, `drop_column!` and `drop_table!` ops leave it: an insert
after an `add_column!` in the same builder names the new column. A table's shape is
loaded from the local copy at the first op that names the table.

Rows are checked against the shapes in the call that passes them, and a wrong call
throws `WriteBuilderError`. Whether a key is present or absent is checked by `commit!`.
"""
mutable struct WriteBuilder{C}
    const copy::LocalCopy{C}
    const head::Head  # the copy's head when the builder was taken
    const scratch::Model.Content  # each table named so far, with its shape and no rows
    const pending::Set{String}  # the copy's tables that are not in `scratch` yet
    const ops::Vector{Ops.Op}
    spent::Bool
end

function WriteBuilder(local_copy::LocalCopy, head_file::Head)
    scratch = Model.Content(
        name => Model.Table(t.shape) for (name, t) in local_copy.content
    )
    pending = setdiff(keys(local_copy.tables), local_copy.loaded)
    return WriteBuilder(local_copy, head_file, scratch, pending, Ops.Op[], false)
end

"""
    TableDeclaration

The `t` of `create_table!(w, :t) do t … end`: the columns that `column!` declared so
far, and the key once `primary_key!` named it.
"""
mutable struct TableDeclaration
    const columns::Vector{Model.Column}
    key::Union{Nothing, Vector{String}}
end

# The `do` block is the documented way to declare a table (ADR-0001).
"""
    create_table!(w, name) do t
        column!(t, :c, T; nullable = false)
        primary_key!(t, :c)
    end

Add the op that creates the table `name`, with the columns and the primary key that the
block declares.

A table has at least one column and a primary key of non-nullable columns. A table name
is an identifier, `[a-z_][a-z0-9_]*`. Throws `WriteBuilderError` for a name in use and
for a declaration that breaks a rule.

Examples: test/test_write_builder_examples.jl
"""
function create_table!(f, w::WriteBuilder, name)
    return add_op!(create_table_op, w, "create_table!(w, $(repr(name)))", f, name)
end

"""
    column!(t, name, T; nullable = false)

Declare a column inside a `create_table!` block.

`T` is one of the four type tags: `Int64`, `Float64`, `String` or `Vector{UInt8}`.
`Int32` and `Float32` are not tags; their values widen. A column name starts with a
letter, `[a-z][a-z0-9_]*`. Throws `WriteBuilderError` for another tag and for a name
that is no identifier or is declared twice.

Examples: test/test_write_builder_examples.jl
"""
function column!(declaration::TableDeclaration, name, T; nullable = false)
    call = "column!(t, $(repr(name)), $(repr(T)))"
    column = translated(declared_column, call, declaration, name, T, nullable)
    push!(declaration.columns, column)
    return nothing
end

"""
    primary_key!(t, names...)

Name the primary key inside a `create_table!` block, once.

The key's columns are distinct, declared and non-nullable. Their order here is the key
declaration order: the order a composite key sorts in. Throws `WriteBuilderError` for a
key that breaks a rule and for a second call.

Examples: test/test_write_builder_examples.jl
"""
function primary_key!(declaration::TableDeclaration, names...)
    call = "primary_key!(t$(join(map(name -> ", " * repr(name), names))))"
    declaration.key = translated(declared_key, call, declaration, names)
    return nothing
end

"""
    add_column!(w, table, name, T; nullable = false, fill)

Add the op that appends a column to `table`.

`T` is a type tag, as in `column!`. `fill` is the typed value that every row of the
table receives: `missing` only if the column is nullable. It widens like a cell.
Throws `WriteBuilderError` for a column that exists and for a `fill` off the column's
value type.

Examples: test/test_write_builder_examples.jl
"""
function add_column!(w::WriteBuilder, table, name, T; nullable = false, fill)
    call = "add_column!(w, $(repr(table)), $(repr(name)), $(repr(T)))"
    return add_op!(add_column_op, w, call, table, (name, T, nullable), fill)
end

"""
    drop_column!(w, table, name)

Add the op that drops a column from the shape of `table` and from every row.

Throws `WriteBuilderError` for a key column and for a column that the table lacks.

Examples: test/test_write_builder_examples.jl
"""
function drop_column!(w::WriteBuilder, table, name)
    call = "drop_column!(w, $(repr(table)), $(repr(name)))"
    return add_op!(drop_column_op, w, call, table, name)
end

"""
    drop_table!(w, table)

Add the op that drops `table`.

The name is then free: a later `create_table!` in the same builder may use it. Throws
`WriteBuilderError` for a table that does not exist.

Examples: test/test_write_builder_examples.jl
"""
function drop_table!(w::WriteBuilder, table)
    return add_op!(drop_table_op, w, "drop_table!(w, $(repr(table)))", table)
end

# The first thing `commit!` does, so that a second `commit!` on one builder throws.
function spend!(w::WriteBuilder)
    w.spent && throw(WriteBuilderError(; detail = SPENT_AT_COMMIT))
    w.spent = true
    return nothing
end

# Every op function runs under this, so that a refused call leaves the builder as it
# was. `op_of` returns the op, or throws the internal `ModelError`.
function add_op!(op_of::F, w::WriteBuilder, call, arguments...) where {F}
    w.spent && throw(WriteBuilderError(; detail = "$call: $SPENT"))
    push!(w.ops, translated(op_of, call, w, arguments...))
    return nothing
end

# The model's checks and the builder's own throw the internal `ModelError`. Here it
# becomes the `WriteBuilderError` whose `detail` starts with the call to fix.
function translated(f::F, call, arguments...) where {F}
    result = try
        f(arguments...)
    catch e
        e isa Model.ModelError || rethrow()
        throw(WriteBuilderError(; detail = "$call: $(e.detail)"))
    end
    return result
end

function create_table_op(w::WriteBuilder, f, name)
    text = name_text("table", name)
    declaration = TableDeclaration(Model.Column[], nothing)
    f(declaration)
    declared = Model.Shape(declaration.columns, something(declaration.key, String[]))
    text in w.pending && throw(Model.ModelError("table $(repr(text)) already exists"))
    Model.create_table!(w.scratch, text, declared)
    return Ops.CreateTable(text, declared)
end

function declared_column(declaration::TableDeclaration, name, T, nullable)
    text = name_text("column", name)
    Model.check_column_name(text)
    any(c -> c.name == text, declaration.columns) &&
        throw(Model.ModelError("duplicate column name $(repr(text))"))
    return Model.Column(text, value_type_of_tag(T, text), nullable)
end

function declared_key(declaration::TableDeclaration, names)
    declaration.key === nothing || throw(
        Model.ModelError("primary_key! was already called; a table has one primary key")
    )
    key = String[name_text("column", name) for name in names]
    # Every rule of a key is the model's own: the shape is built for its checks.
    Model.Shape(declaration.columns, key)
    return key
end

function add_column_op(w::WriteBuilder, table, declared, fill_value)
    text = name_text("table", table)
    name, T, nullable = declared
    column_text = name_text("column", name)
    column = Model.Column(column_text, value_type_of_tag(T, column_text), nullable)
    scratch = scratch_table(w, text)
    cell = canonical_cell(column, fill_value)
    Model.add_column!(scratch, column, cell, SCRATCH_SLOT)
    return Ops.AddColumn(text, column, cell)
end

function drop_column_op(w::WriteBuilder, table, name)
    text = name_text("table", table)
    column = name_text("column", name)
    Model.drop_column!(scratch_table(w, text), column, SCRATCH_SLOT)
    return Ops.DropColumn(text, column)
end

function drop_table_op(w::WriteBuilder, table)
    text = name_text("table", table)
    if text in w.pending
        # Dropped unread: nothing of the table is needed until `commit!`.
        delete!(w.pending, text)
    else
        Model.drop_table!(w.scratch, text)
    end
    return Ops.DropTable(text)
end

# A table of the local copy enters the scratch content at the first op that names it.
function scratch_table(w::WriteBuilder, name)
    name in w.pending && load_shape!(w, name)
    return Model.table(w.scratch, name)
end

function load_shape!(w::WriteBuilder, name)
    w.scratch[name] = Model.Table(load_table!(w.copy, name).shape)
    delete!(w.pending, name)
    return nothing
end
