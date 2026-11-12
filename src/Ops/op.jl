"""
    Cell

A typed value or null, as an op carries it.
"""
const Cell = Union{Missing, Int64, Float64, String, Vector{UInt8}}

"""
    Op

One of the seven ops of a transaction record. Every op names its `table`.
"""
abstract type Op end

"""
    CreateTable(table, shape)

The op that creates `table` with `shape`, empty.
"""
struct CreateTable <: Op
    table::String
    shape::Shape
end

"""
    AddColumn(table, column, fill)

The op that appends `column`, giving every row the typed value `fill` (null only in a
nullable column).
"""
struct AddColumn <: Op
    table::String
    column::Column
    fill::Cell
end

"""
    DropColumn(table, column)

The op that removes the non-key `column` from `table`.
"""
struct DropColumn <: Op
    table::String
    column::String
end

"""
    DropTable(table)

The op that removes `table`.
"""
struct DropTable <: Op
    table::String
end

"""
    Insert(table, rows)

The op that inserts `rows`, each every column in declaration order, in typed key order.
"""
struct Insert <: Op
    table::String
    rows::Vector{Vector{Cell}}
end

"""
    Update(table, columns, rows)

The op that sets the non-key `columns` (in declaration order) of the rows named by key.
Each row is `[key…, values…]`, in typed key order.
"""
struct Update <: Op
    table::String
    columns::Vector{String}
    rows::Vector{Vector{Cell}}
end

"""
    Delete(table, keys)

The op that deletes the rows at `keys`, each the key columns in key declaration order, in
typed key order.
"""
struct Delete <: Op
    table::String
    keys::Vector{Vector{Cell}}
end

const OP_TYPES = (CreateTable, AddColumn, DropColumn, DropTable, Insert, Update, Delete)
const ROWS_NOT_ARRAYS = "is not an array of arrays"
const NOT_TYPED = "which is not a typed value"

# Fields compare with `isequal`, so an op with a NaN cell equals its decoded copy.
function Base.:(==)(a::T, b::T) where {T <: Op}
    return all(f -> isequal(getfield(a, f), getfield(b, f)), fieldnames(T))
end

function Base.hash(op::T, h::UInt) where {T <: Op}
    return hash(map(f -> getfield(op, f), fieldnames(T)), hash(T, h))
end

"""
    op_name(op) -> String

Return the op's wire discriminator: `create_table`, `add_column`, `drop_column`,
`drop_table`, `insert`, `update` or `delete`.
"""
op_name(op::Op) = op_name(typeof(op))
op_name(::Type{CreateTable}) = "create_table"
op_name(::Type{AddColumn}) = "add_column"
op_name(::Type{DropColumn}) = "drop_column"
op_name(::Type{DropTable}) = "drop_table"
op_name(::Type{Insert}) = "insert"
op_name(::Type{Update}) = "update"
op_name(::Type{Delete}) = "delete"

# The fields each op carries besides "op" and "table"; a wire op has exactly these.
op_fields(::Type{CreateTable}) = ("shape",)
op_fields(::Type{AddColumn}) = ("column", "fill")
op_fields(::Type{DropColumn}) = ("column",)
op_fields(::Type{DropTable}) = ()
op_fields(::Type{Insert}) = ("rows",)
op_fields(::Type{Update}) = ("columns", "rows")
op_fields(::Type{Delete}) = ("keys",)

"""
    wire(op) -> Dict{String,Any}
    wire(record) -> Dict{String,Any}

Return the wire form of an op or a record, for `CBOR.encode`.
"""
function wire(op::CreateTable)
    return Dict{String, Any}(
        "op" => op_name(op), "table" => op.table, "shape" => shape_wire(op.shape)
    )
end

function wire(op::AddColumn)
    c = op.column
    return Dict{String, Any}(
        "op" => op_name(op), "table" => op.table,
        "column" => Any[c.name, c.type, c.nullable], "fill" => op.fill,
    )
end

function wire(op::DropColumn)
    return Dict{String, Any}(
        "op" => op_name(op), "table" => op.table, "column" => op.column
    )
end

wire(op::DropTable) = Dict{String, Any}("op" => op_name(op), "table" => op.table)

function wire(op::Insert)
    return Dict{String, Any}(
        "op" => op_name(op), "table" => op.table, "rows" => rows_wire(op.rows)
    )
end

function wire(op::Update)
    return Dict{String, Any}(
        "op" => op_name(op), "table" => op.table,
        "columns" => Any[op.columns...], "rows" => rows_wire(op.rows),
    )
end

function wire(op::Delete)
    return Dict{String, Any}(
        "op" => op_name(op), "table" => op.table, "keys" => rows_wire(op.keys)
    )
end

rows_wire(rows) = Any[Any[r...] for r in rows]

"""
    op_from_wire(w) -> Op

Read one op from its wire form as `CBOR.decode` yields it. Throws `ModelError` for an
unknown op, a missing or unknown field, or a field of the wrong form; the cells are
checked against the shape at apply.
"""
function op_from_wire(w::AbstractDict)
    haskey(w, "op") || throw(ModelError(; detail = "op has no \"op\" field"))
    haskey(w, "table") || throw(ModelError(; detail = "op has no \"table\" field"))
    T = op_type(w["op"])
    unknown = filter(k -> !(k in ("op", "table") || k in op_fields(T)), collect(keys(w)))
    isempty(unknown) || throw(
        ModelError(; detail = unknown_field_text(first(unknown), T))
    )
    return op_from_wire(T, w, text_field(w, T, "table"))
end

function op_from_wire(w)
    throw(ModelError(; detail = "op is not a map, got a value of type $(typeof(w))"))
end

function op_from_wire(::Type{CreateTable}, w, table)
    return CreateTable(table, Shape(field(w, CreateTable, "shape")))
end

function op_from_wire(::Type{AddColumn}, w, table)
    column = column_from_entry(field(w, AddColumn, "column"))
    return AddColumn(table, column, cell_from_wire(field(w, AddColumn, "fill"), "fill"))
end

function op_from_wire(::Type{DropColumn}, w, table)
    return DropColumn(table, text_field(w, DropColumn, "column"))
end

op_from_wire(::Type{DropTable}, w, table) = DropTable(table)
op_from_wire(::Type{Insert}, w, table) = Insert(table, rows_field(w, Insert, "rows"))

function op_from_wire(::Type{Update}, w, table)
    columns = field(w, Update, "columns")
    columns isa AbstractVector && all(c -> c isa String, columns) || throw(
        ModelError(; detail = "\"columns\" of an update op is not an array of names")
    )
    return Update(table, String[columns...], rows_field(w, Update, "rows"))
end

op_from_wire(::Type{Delete}, w, table) = Delete(table, rows_field(w, Delete, "keys"))

# The one place a wire tag becomes an op type.
function op_type(name)
    i = name isa String ? findfirst(T -> op_name(T) == name, OP_TYPES) : nothing
    names = join(map(op_name, OP_TYPES), ", ")
    i === nothing &&
        throw(ModelError(; detail = "unknown op $(repr(name)); the ops are $names"))
    return OP_TYPES[i]
end

with_article(::Type{T}) where {T <: Op} = article(op_name(T)) * op_name(T)
article(name) = first(name) in ('a', 'e', 'i', 'o', 'u') ? "an " : "a "

function field(w, ::Type{T}, name) where {T <: Op}
    haskey(w, name) ||
        throw(ModelError(; detail = "$(op_name(T)) op has no $(repr(name)) field"))
    return w[name]
end

function text_field(w, ::Type{T}, name) where {T <: Op}
    x = field(w, T, name)
    x isa String ||
        throw(ModelError(; detail = "$(repr(name)) of $(with_article(T)) op is not text"))
    return x
end

function rows_field(w, ::Type{T}, name) where {T <: Op}
    x = field(w, T, name)
    x isa AbstractVector && all(r -> r isa AbstractVector, x) || throw(
        ModelError(; detail = "$(repr(name)) of $(with_article(T)) op $ROWS_NOT_ARRAYS")
    )
    return Vector{Cell}[map(c -> cell_from_wire(c, name), row) for row in x]
end

# A value that is no typed value is refused when the op is read, before any shape is known.
function cell_from_wire(x, name)
    x isa Cell || throw(
        ModelError(; detail = "$(repr(name)) holds a $(typeof(x)), $NOT_TYPED")
    )
    return x
end

function unknown_field_text(name, ::Type{T}) where {T <: Op}
    return "unknown field $(repr(name)) on $(with_article(T)) op"
end
