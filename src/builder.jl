# #34 step 4 — ADR-0001, ADR-0019, ADR-0025, ADR-0003, ADR-0005: single-use write builder over the model, sharing apply's checks.
#
# The public write surface lives directly in ChainTables (nothing is exported,
# every call is qualified — ADR-0019). Every structural check runs eagerly, in
# the call that is wrong, through the model's own check functions, so the
# builder's checks and apply's are one code path (ADR-0025); the state gate of
# ADR-0001 (insert on a present key, update or delete on an absent one) runs at
# `commit!` against the model (#34 step 7). Every refusal is a
# `WriteBuilderError` whose message starts with the call to fix (ADR-0020).

using .Model: fail

"""
    WriteBuilder

The single-use write builder (ADR-0019, ADR-0001): the ops of one transaction
record, collected by the op functions below and consumed by `commit!`. Taken
with [`write_builder`](@ref) over a local copy, or constructed over a
`Model.Content` directly (the tests do); `copy` and `head` — the copy's
`(; slot, transaction_hash)` when the builder was taken — ride along for
`commit!`'s stale-head check.

The builder holds no rows of the content it was taken over, only the shape of
every table it names, evolved by its own `create_table!`, `add_column!`,
`drop_column!` and `drop_table!` ops — so an insert after an `add_column!` in
the same builder names the new column. Rows are checked against those shapes
eagerly; whether a key is present or absent is the state gate, which `commit!`
runs. Over a local copy the shapes come from the copy's tables, loaded on the
first op that names one (`pending` holds the names not yet loaded) — a builder
never touches a table it does not name, and `commit!` needs every table it
names resident anyway (ADR-0023).

Fields: `ops`, the canonical ops in call order; `spent`, set by [`spend!`](@ref)
once `commit!` has consumed the builder.
"""
mutable struct WriteBuilder{C,H}
    scratch::Model.Content     # every table named so far as an empty Table carrying its shape, evolved by this builder's shape ops
    pending::Set{String}       # the copy's tables not yet in scratch; a name here exists and is loaded on first mention
    ops::Vector{Ops.Op}
    spent::Bool
    copy::C
    head::H
end

function WriteBuilder(content::Model.Content; copy = nothing, head = nothing, pending = Set{String}())
    scratch = Model.Content(name => Model.Table(t.shape) for (name, t) in content)
    return WriteBuilder{typeof(copy),typeof(head)}(scratch, Set{String}(pending), Ops.Op[], false, copy, head)
end

# The scratch table for `name`, loading its shape from the copy on first mention
# (hash-before-use, whole table resident — `load_table!`'s own rule). Unknown names
# fail in the model's words.
function scratch_table(w::WriteBuilder, name::AbstractString)
    if name in w.pending
        t = load_table!(w.copy, name)
        w.scratch[name] = Model.Table(t.shape)
        delete!(w.pending, name)
    end
    return Model.table(w.scratch, name)
end

"""
    write_builder(copy) -> WriteBuilder

A single-use write builder bound to the copy's current head (ADR-0019). Add ops
with [`create_table!`](@ref), [`add_column!`](@ref), [`drop_column!`](@ref),
[`drop_table!`](@ref), [`insert_rows!`](@ref), [`update_rows!`](@ref) and
[`delete_rows!`](@ref); `commit!` consumes it. Structural checks fail in the
call that is wrong with `WriteBuilderError`; the state gate — a key present
where the op needs it absent, or absent where it needs it present — runs at
`commit!`. A builder held across a `sync!` raises `StaleHeadError` at `commit!`
and is never re-run (ADR-0002).

The `LocalCopy` method lives in `chain.jl` with `commit!`.
"""
function write_builder end

"""
    spend!(w) -> nothing

Mark the builder consumed: the first thing `commit!` does, so a second `commit!`
on the same builder — the forbidden retry written by hand (ADR-0019) — is a
`WriteBuilderError`, as is every op function on a spent builder.
"""
function spend!(w::WriteBuilder)
    w.spent && throw(WriteBuilderError(
        "commit!(w): this builder is spent; a builder is used once, take a new one with write_builder(copy)"))
    w.spent = true
    return nothing
end

live(w::WriteBuilder) =
    w.spent && fail("this builder is spent; commit! consumed it, take a new one with write_builder(copy)")

# Every public entry runs under this: the model's ModelError, and the builder's
# own checks raised the same way, become one WriteBuilderError whose message
# starts with the call to fix.
function guarded(f, call)
    try
        f()
    catch e
        e isa Model.ModelError || rethrow()
        throw(WriteBuilderError("$call: $(e.msg)"))
    end
    return nothing
end

# ---------------------------------------------------------------------------
# Names and type tags (ADR-0019, ADR-0025)
# ---------------------------------------------------------------------------

tablename(x::Union{Symbol,AbstractString}) = String(x)
tablename(x) = fail("table name $(repr(x)) is not a Symbol")
colname(x::Union{Symbol,AbstractString}) = String(x)
colname(x) = fail("column name $(repr(x)) is not a Symbol")

"""
    TYPE_TAGS

The four type tags and the value type each names (ADR-0019, ADR-0025): `Int64`,
`Float64`, `String`, `Vector{UInt8}`, by identity. Nothing else is a tag — not
`AbstractString`, not `Int32` (its values widen, the tag stays `Int64`), not
`Bool`. `Int` is `Int64` on 64-bit platforms and is accepted as that.
"""
const TYPE_TAGS = (Int64 => "int64", Float64 => "float64", String => "text", Vector{UInt8} => "bytes")

function tag_value_type(T, column)
    for (tag, vt) in TYPE_TAGS
        T === tag && return vt
    end
    hint = T === AbstractString ? "; a text column's tag is String" :
           T === Int32 ? "; Int32 values widen at insert, the tag is Int64" :
           T === Float32 ? "; Float32 values widen at insert, the tag is Float64" : ""
    fail("type tag $(repr(T)) for column $(repr(column)) is not one of Int64, Float64, String, Vector{UInt8}$hint")
end

# ---------------------------------------------------------------------------
# Cells (ADR-0025): the builder-side conversions — widening, NaN canonicalised,
# text checked — then the model's own check_cell refuses anything else by type.
# ---------------------------------------------------------------------------

cell(::Model.Column, x::Int64) = x
cell(::Model.Column, x::Float64) = isnan(x) ? NaN : x          # every NaN is f97e00: sign and payload dropped
cell(c::Model.Column, x::String) = Ops.check_text("column $(repr(c.name))", x)
cell(::Model.Column, x::Vector{UInt8}) = x                       # copied by the model when it takes the row
cell(::Model.Column, ::Missing) = missing
cell(c::Model.Column, x::Union{Int8,Int16,Int32}) = cell(c, Int64(x))
cell(c::Model.Column, x::Union{Float16,Float32}) = cell(c, Float64(x))
cell(c::Model.Column, x::AbstractString) = cell(c, String(x))
cell(c::Model.Column, x::AbstractVector{UInt8}) = cell(c, Vector{UInt8}(x))
cell(c::Model.Column, ::Nothing) = fail("column $(repr(c.name)): nothing is not a value; null is spelt missing")
cell(::Model.Column, x) = x                                      # refused by Model.check_cell, naming the column and the type

cells(cols, row) = Any[cell(c, getproperty(row, Symbol(c.name))) for c in cols]

# ---------------------------------------------------------------------------
# Row sets (ADR-0019, ADR-0024): any iterable of rows, a row being anything with
# propertynames and getproperty — a NamedTuple, a Tables.jl row, a DataFrameRow.
# Tables.jl is consumed as an interface only, so a column table is passed
# through Tables.rows by the caller.
# ---------------------------------------------------------------------------

is_row(r) = !(r isa Number || r isa AbstractString || r isa AbstractVector || r isa Tuple ||
              r isa AbstractChar || r isa Symbol || r === nothing || r === missing)

# The rows as a vector, and the columns they all name, checked uniform.
function rowset(rows)
    rows isa NamedTuple && fail("a row set is a collection of rows, got one NamedTuple; wrap the row in a vector")
    rs = collect(rows)
    isempty(rs) && fail("the row set is empty; an op carries at least one row")
    for (i, r) in enumerate(rs)
        is_row(r) || fail("row $i is not a row (a NamedTuple or a Tables.jl row), got a value of type $(typeof(r))")
    end
    names = Symbol[propertynames(rs[1])...]
    for i in 2:length(rs)
        n = propertynames(rs[i])
        length(n) == length(names) && all(x -> x in names, n) ||
            fail("row $i names columns $(Tuple(n)) but row 1 names $(Tuple(names)); the columns of an op are uniform")
    end
    return rs, names
end

# ---------------------------------------------------------------------------
# create_table! and its declaration block (ADR-0001, ADR-0003)
# ---------------------------------------------------------------------------

"""
    TableDeclaration

The `t` of `create_table!(w, :t) do t … end`: the columns declared so far by
[`column!`](@ref), and the key once [`primary_key!`](@ref) has named it.
"""
mutable struct TableDeclaration
    columns::Vector{Model.Column}
    key::Union{Nothing,Vector{String}}
end

"""
    create_table!(w, :t) do t
        column!(t, :c, T; nullable = false)
        …
        primary_key!(t, :c, …)
    end

Declare a table (ADR-0003, ADR-0025): its columns in declaration order, and its
primary key. The block is the one place a do-block reads well (ADR-0001). A
table needs at least one column and an explicit key of non-nullable columns;
names are identifiers, `[a-z_][a-z0-9_]*`. Refuses a name already in use.
"""
function create_table!(f, w::WriteBuilder, table)
    guarded("create_table!(w, $(repr(table)))") do
        live(w)
        name = tablename(table)
        d = TableDeclaration(Model.Column[], nothing)
        f(d)
        shape = Model.Shape(d.columns, something(d.key, String[]))   # every rule of a shape, the model's own
        name in w.pending && fail("table $(repr(name)) already exists")
        Model.create_table!(w.scratch, name, shape)
        push!(w.ops, Ops.CreateTable(name, shape))
    end
end

"""
    column!(t, :c, T; nullable = false)

Declare a column inside a `create_table!` block. `T` is one of the four type
tags — `Int64`, `Float64`, `String`, `Vector{UInt8}` — by identity (ADR-0019);
`Int32` and `Float32` are not tags, their values widen. Declare columns before
`primary_key!` names them.
"""
function column!(d::TableDeclaration, column, T; nullable = false)
    guarded("column!(t, $(repr(column)), $(repr(T)))") do
        name = colname(column)
        Model.is_identifier(name) || fail("column name $(repr(name)) is not an identifier ([a-z_][a-z0-9_]*)")
        any(c -> c.name == name, d.columns) && fail("duplicate column name $(repr(name))")
        push!(d.columns, Model.Column(name, tag_value_type(T, name), nullable))
    end
end

"""
    primary_key!(t, :c, …)

Name the primary key inside a `create_table!` block, once: distinct, existing,
non-nullable columns, in key declaration order — the order a composite key
sorts and is written in (ADR-0025).
"""
function primary_key!(d::TableDeclaration, columns...)
    guarded("primary_key!(t$(join(", " .* repr.(columns))))") do
        d.key === nothing || fail("primary_key! was already called; a table has one primary key")
        key = String[colname(c) for c in columns]
        Model.Shape(d.columns, key)                                 # every rule of a key, the model's own
        d.key = key
    end
end

# ---------------------------------------------------------------------------
# The column and table ops (ADR-0025)
# ---------------------------------------------------------------------------

"""
    add_column!(w, :t, :c, T; nullable = false, fill)

Append a column; `fill` is the typed value every existing row receives, and is
required — null (`missing`) only if the column is nullable (ADR-0025). `T` is
a type tag as in [`column!`](@ref); `fill` widens like a cell.
"""
function add_column!(w::WriteBuilder, table, column, T; nullable = false, fill)
    guarded("add_column!(w, $(repr(table)), $(repr(column)), $(repr(T)))") do
        live(w)
        name = tablename(table)
        cname = colname(column)
        c = Model.Column(cname, tag_value_type(T, cname), nullable)
        t = scratch_table(w, name)
        f = cell(c, fill)
        Model.add_column!(t, c, f)                                  # exists, fill against the column, identifier
        push!(w.ops, Ops.AddColumn(name, c, f))
    end
end

"""
    drop_column!(w, :t, :c)

Remove a non-key column from the shape and from every row. Refuses a key column
and nothing else (ADR-0025).
"""
function drop_column!(w::WriteBuilder, table, column)
    guarded("drop_column!(w, $(repr(table)), $(repr(column)))") do
        live(w)
        name = tablename(table)
        cname = colname(column)
        Model.drop_column!(scratch_table(w, name), cname)
        push!(w.ops, Ops.DropColumn(name, cname))
    end
end

"""
    drop_table!(w, :t)

Drop a table. A table is re-shaped by `add_column!`/`drop_column!`, or by
`drop_table!` + `create_table!` + `insert_rows!` inside one record (ADR-0003).
"""
function drop_table!(w::WriteBuilder, table)
    guarded("drop_table!(w, $(repr(table)))") do
        live(w)
        name = tablename(table)
        if name in w.pending                 # dropped unread: nothing of it is needed until commit!
            delete!(w.pending, name)
        else
            Model.drop_table!(w.scratch, name)
        end
        push!(w.ops, Ops.DropTable(name))
    end
end

# ---------------------------------------------------------------------------
# The row ops (ADR-0005, ADR-0025)
# ---------------------------------------------------------------------------

"""
    insert_rows!(w, :t, rows)

Insert a row set: every row names every column of the table (ADR-0005), in any
field order; cells widen and are checked against the shape; keys are distinct
within the op. The op carries the rows in typed key order with cells in
declaration order. Insert on a present key is the state gate, at `commit!`.
"""
function insert_rows!(w::WriteBuilder, table, rows)
    guarded("insert_rows!(w, $(repr(table)))") do
        live(w)
        name = tablename(table)
        s = scratch_table(w, name).shape
        rs, names = rowset(rows)
        foreach(n -> Model.column_index(s, String(n)), names)
        for c in s.columns
            Symbol(c.name) in names || fail("row set names no column $(repr(c.name)); an insert names every column")
        end
        vecs = Ops.sort_rows((cells(s.columns, r) for r in rs), r -> Model.key_of(s, r))
        Model.check_insert(s, vecs)
        push!(w.ops, Ops.Insert(name, vecs))
    end
end

"""
    update_rows!(w, :t, rows)

Update a row set: every row names the full primary key plus the same non-empty
set of non-key columns — the columns changed (ADR-0005); a key never changes,
delete then insert. `missing` read from a view and handed back is null,
unchanged. Update on an absent key is the state gate, at `commit!`.
"""
function update_rows!(w::WriteBuilder, table, rows)
    guarded("update_rows!(w, $(repr(table)))") do
        live(w)
        name = tablename(table)
        s = scratch_table(w, name).shape
        rs, names = rowset(rows)
        foreach(n -> Model.column_index(s, String(n)), names)
        for k in s.key
            Symbol(k) in names || fail("row set names no key column $(repr(k)); an update names the full key")
        end
        keycols = [s.columns[j] for j in s.keyidx]
        valcols = [c for c in s.columns if Symbol(c.name) in names && !(c.name in s.key)]   # declaration order
        columns = String[c.name for c in valcols]
        nk = length(s.keyidx)
        vecs = Ops.sort_rows((vcat(cells(keycols, r), cells(valcols, r)) for r in rs), r -> Tuple(r[1:nk]))
        Model.check_update(s, columns, vecs)
        push!(w.ops, Ops.Update(name, columns, vecs))
    end
end

"""
    delete_rows!(w, :t, rows)

Delete a row set: every row names the key columns and nothing else (ADR-0005).
Delete on an absent key is the state gate, at `commit!`.
"""
function delete_rows!(w::WriteBuilder, table, rows)
    guarded("delete_rows!(w, $(repr(table)))") do
        live(w)
        name = tablename(table)
        s = scratch_table(w, name).shape
        rs, names = rowset(rows)
        for n in names
            c = s.columns[Model.column_index(s, String(n))]
            c.name in s.key || fail("row set names column $(repr(c.name)); a delete names the key columns only")
        end
        for k in s.key
            Symbol(k) in names || fail("row set names no key column $(repr(k)); a delete names the full key")
        end
        keycols = [s.columns[j] for j in s.keyidx]
        vecs = Ops.sort_rows((cells(keycols, r) for r in rs), Tuple)
        Model.check_delete(s, vecs)
        push!(w.ops, Ops.Delete(name, vecs))
    end
end
