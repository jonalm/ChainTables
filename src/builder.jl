"""
    WriteBuilder

The ops of one transaction record, collected by the op functions and consumed by
`commit!`. Taken with `write_builder(copy)`, or built over a `Content` directly.

The builder holds no rows, only the shape of every table it names, evolved by its own
shape ops, so an insert after an `add_column!` names the new column. Over a local copy
a table's shape is loaded on the first op that names it; `pending` holds the copy's
names not yet loaded.
"""
mutable struct WriteBuilder{C, H}
    scratch::Content # every table named so far, as an empty Table carrying its shape
    pending::Set{String} # the copy's tables not yet in scratch
    ops::Vector{Ops.Op} # canonical ops, in call order
    spent::Bool # set by spend! once commit! has consumed the builder
    copy::C
    head::H # the copy's (; slot, transaction_hash) when the builder was taken
end

function WriteBuilder(
        content::Content; copy = nothing, head = nothing, pending = Set{String}()
    )
    scratch = Content(name => Table(t.shape) for (name, t) in content)
    return WriteBuilder{typeof(copy), typeof(head)}(
        scratch, Set{String}(pending), Ops.Op[], false, copy, head
    )
end

"""
    TableDeclaration

The `t` of `create_table!(w, :t) do t … end`: the columns `column!` has declared so
far, and the key once `primary_key!` has named it.
"""
mutable struct TableDeclaration
    columns::Vector{Column}
    key::Union{Nothing, Vector{String}}
end

# Exactly these four types, by identity (ADR-0019, ADR-0025): `Int32` values widen, but
# `Int32` is not a tag.
const TYPE_TAGS = (
    Int64 => "int64", Float64 => "float64", String => "text", Vector{UInt8} => "bytes",
)

const TAG_CHOICES = "Int64, Float64, String, Vector{UInt8}"

function write_builder end

"""
    create_table!(w, :t) do t
        column!(t, :c, T; nullable = false)
        primary_key!(t, :c, …)
    end

Declare a table: its columns in declaration order, and its primary key.

A table needs at least one column and an explicit key of non-nullable columns. A table
name matches `[a-z_][a-z0-9_]*`; a column name starts with a letter, `[a-z][a-z0-9_]*`,
so it never collides with the `_slot` of `table_with_slots`. Throws `WriteBuilderError`
for a refused declaration or a name already in use.

Examples: test/test_builder_examples.jl
"""
function create_table!(f, w::WriteBuilder, table)
    return guarded("create_table!(w, $(repr(table)))") do
        check_not_spent(w)
        name = table_name(table)
        d = TableDeclaration(Column[], nothing)
        f(d)
        # The model's own Shape constructor runs every rule of a shape.
        shape = Shape(d.columns, something(d.key, String[]))
        name in w.pending && fail("table $(repr(name)) already exists")
        add_table!(w.scratch, name, shape)
        push!(w.ops, Ops.CreateTable(name, shape))
    end
end

"""
    column!(t, :c, T; nullable = false)

Declare a column inside a `create_table!` block.

`T` is one of the four type tags `Int64`, `Float64`, `String` and `Vector{UInt8}`, by
identity: `Int32` and `Float32` are not tags, their values widen. Declare a column
before `primary_key!` names it.

Examples: test/test_builder_examples.jl
"""
function column!(d::TableDeclaration, column, T; nullable = false)
    return guarded("column!(t, $(repr(column)), $(repr(T)))") do
        name = column_name(column)
        check_column_name(name)
        any(c -> c.name == name, d.columns) && fail("duplicate column name $(repr(name))")
        push!(d.columns, Column(name, tag_value_type(T, name), nullable))
    end
end

"""
    primary_key!(t, :c, …)

Name the primary key inside a `create_table!` block, once.

The key columns are distinct, declared and non-nullable. Their order here is the order
a composite key sorts and is written in.

Examples: test/test_builder_examples.jl
"""
function primary_key!(d::TableDeclaration, columns...)
    return guarded("primary_key!(t$(join(", " .* repr.(columns))))") do
        d.key === nothing || fail("primary_key! was already called; a table has one key")
        key = String[column_name(c) for c in columns]
        # The model's own Shape constructor runs every rule of a key.
        Shape(d.columns, key)
        d.key = key
    end
end

"""
    add_column!(w, :t, :c, T; nullable = false, fill)

Append a column to table `t`; every existing row receives `fill`.

`fill` is required, and is `missing` only when the column is nullable. `T` is a type tag
as in `column!`; `fill` widens like a cell.

Examples: test/test_builder_examples.jl
"""
function add_column!(w::WriteBuilder, table, column, T; nullable = false, fill)
    call = "add_column!(w, $(repr(table)), $(repr(column)), $(repr(T)))"
    return guarded(call) do
        check_not_spent(w)
        name = table_name(table)
        cname = column_name(column)
        c = Column(cname, tag_value_type(T, cname), nullable)
        t = scratch_table(w, name)
        value = cell(c, fill)
        append_column!(t, c, value, scratch_slot(t))
        push!(w.ops, Ops.AddColumn(name, c, value))
    end
end

"""
    drop_column!(w, :t, :c)

Remove a non-key column from table `t`'s shape and from every row.

Examples: test/test_builder_examples.jl
"""
function drop_column!(w::WriteBuilder, table, column)
    return guarded("drop_column!(w, $(repr(table)), $(repr(column)))") do
        check_not_spent(w)
        name = table_name(table)
        cname = column_name(column)
        t = scratch_table(w, name)
        remove_column!(t, cname, scratch_slot(t))
        push!(w.ops, Ops.DropColumn(name, cname))
    end
end

"""
    drop_table!(w, :t)

Drop table `t`.

To change a table's shape, use `add_column!` and `drop_column!`, or `drop_table!`,
`create_table!` and `insert_rows!` in one builder.

Examples: test/test_builder_examples.jl
"""
function drop_table!(w::WriteBuilder, table)
    return guarded("drop_table!(w, $(repr(table)))") do
        check_not_spent(w)
        name = table_name(table)
        forget_table!(w, name)
        push!(w.ops, Ops.DropTable(name))
    end
end

"""
    insert_rows!(w, :t, rows)

Insert a row set into table `t`.

Every row names every column, in any field order; cells widen and are checked against
the shape; keys are distinct within the op. A key already present is refused at
`commit!`, not here.

Examples: test/test_builder_examples.jl
"""
function insert_rows!(w::WriteBuilder, table, rows)
    return guarded("insert_rows!(w, $(repr(table)))") do
        check_not_spent(w)
        name = table_name(table)
        s = scratch_table(w, name).shape
        rs, names = row_set(rows)
        check_insert_names(s, names)
        vectors = Ops.sort_rows((cells(s.columns, r) for r in rs), r -> key_of(s, r))
        check_insert(s, vectors)
        push!(w.ops, Ops.Insert(name, vectors))
    end
end

"""
    update_rows!(w, :t, rows)

Update a row set of table `t`.

Every row names the full primary key plus the same non-empty set of non-key columns,
the columns changed. A key never changes: delete the row, then insert it. `missing`
read from a view and handed back is null, unchanged. A key that is absent is refused at
`commit!`, not here.

Examples: test/test_builder_examples.jl
"""
function update_rows!(w::WriteBuilder, table, rows)
    return guarded("update_rows!(w, $(repr(table)))") do
        check_not_spent(w)
        name = table_name(table)
        s = scratch_table(w, name).shape
        rs, names = row_set(rows)
        check_update_names(s, names)
        value_columns = changed_columns(s, names)
        vectors = update_vectors(s, value_columns, rs)
        changed = String[c.name for c in value_columns]
        check_update(s, changed, vectors)
        push!(w.ops, Ops.Update(name, changed, vectors))
    end
end

"""
    delete_rows!(w, :t, rows)

Delete a row set of table `t`: every row names the key columns and nothing else.

A key that is absent is refused at `commit!`, not here.

Examples: test/test_builder_examples.jl
"""
function delete_rows!(w::WriteBuilder, table, rows)
    return guarded("delete_rows!(w, $(repr(table)))") do
        check_not_spent(w)
        name = table_name(table)
        s = scratch_table(w, name).shape
        rs, names = row_set(rows)
        check_delete_names(s, names)
        key_columns = s.columns[s.keyidx]
        vectors = Ops.sort_rows((cells(key_columns, r) for r in rs), Tuple)
        check_delete(s, vectors)
        push!(w.ops, Ops.Delete(name, vectors))
    end
end

"""
    spend!(w)

Mark the builder consumed. `commit!` calls it first, so a second `commit!` on the same
builder throws `WriteBuilderError`, as does every op function on a spent builder.
"""
function spend!(w::WriteBuilder)
    w.spent &&
        throw(WriteBuilderError(; call = "commit!(w)", detail = "this builder is spent"))
    w.spent = true
    return nothing
end

# Every op function runs under this: a ModelError, from the model's checks or the
# builder's own, becomes one WriteBuilderError naming the call to fix.
function guarded(f, call)
    try
        f()
    catch e
        e isa ModelError || rethrow()
        throw(WriteBuilderError(; call, detail = e.detail))
    end
    return nothing
end

function check_not_spent(w::WriteBuilder)
    w.spent && fail("this builder is spent: commit! consumed it")
    return nothing
end

table_name(x::Union{Symbol, AbstractString}) = String(x)
table_name(x) = fail("table name $(repr(x)) is not a Symbol")

column_name(x::Union{Symbol, AbstractString}) = String(x)
column_name(x) = fail("column name $(repr(x)) is not a Symbol")

function tag_value_type(T, column)
    i = findfirst(p -> first(p) === T, TYPE_TAGS)
    i === nothing || return last(TYPE_TAGS[i])
    return fail(
        "type tag $(repr(T)) for column $(repr(column)) is not one of " *
            TAG_CHOICES * tag_hint(T)
    )
end

tag_hint(::Type{AbstractString}) = "; a text column's tag is String"
tag_hint(::Type{Int32}) = "; Int32 values widen at insert, the tag is Int64"
tag_hint(::Type{Float32}) = "; Float32 values widen at insert, the tag is Float64"
tag_hint(_) = ""

"""
    scratch_table(w, name) -> Table

The scratch table for `name`. A table of the copy is loaded on first mention, through
`load_table!` and its hash check. An unknown name throws `ModelError`.
"""
function scratch_table(w::WriteBuilder, name::AbstractString)
    name in w.pending && take_from_copy!(w, name)
    return content_table(w.scratch, name)
end

function take_from_copy!(w::WriteBuilder, name::AbstractString)
    w.scratch[name] = Table(load_table!(w.copy, name).shape)
    delete!(w.pending, name)
    return nothing
end

# A scratch table holds a shape and never rows, so the slot its column ops stamp is a
# placeholder that stamps nothing (ADR-0032).
function scratch_slot(t::Table)
    nrows(t) == 0 ||
        throw(AssertionError("BUG: scratch table holds $(nrows(t)) rows; it holds a shape"))
    return 0
end

function forget_table!(w::WriteBuilder, name::AbstractString)
    # A table dropped unread is never loaded: nothing of it is needed until commit!.
    if name in w.pending
        delete!(w.pending, name)
    else
        remove_table!(w.scratch, name)
    end
    return nothing
end
