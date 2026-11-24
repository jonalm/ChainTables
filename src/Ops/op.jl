# "Op" is the Glossary's term, so the abstract type keeps it without an `Abstract` prefix.
"""
    Op

One of the seven ops of the record format: `CreateTable`, `AddColumn`, `DropColumn`,
`DropTable`, `Insert`, `Update` or `Delete`. Every op names its `table`.
"""
abstract type Op end

"""
    CreateTable(table, shape)

The op that creates the table `table` with the `Shape` `shape`.

Examples: test/test_ops_op_examples.jl
"""
struct CreateTable <: Op
    table::String
    shape::Shape
end

"""
    AddColumn(table, column, fill)

The op that adds the `Column` `column` to `table`.

`fill` is the typed value every existing row receives: null (`missing`) only if the
column is nullable.

Examples: test/test_ops_op_examples.jl
"""
struct AddColumn <: Op
    table::String
    column::Column
    fill::Cell
end

"""
    DropColumn(table, column)

The op that drops the non-key column named `column` from `table`.

Examples: test/test_ops_op_examples.jl
"""
struct DropColumn <: Op
    table::String
    column::String
end

"""
    DropTable(table)

The op that drops `table`.

Examples: test/test_ops_op_examples.jl
"""
struct DropTable <: Op
    table::String
end

"""
    Insert(table, rows)

The op that inserts `rows` into `table`.

Each row is a vector of every column's cell in declaration order. The rows are in typed
key order.

Examples: test/test_ops_op_examples.jl
"""
struct Insert <: Op
    table::String
    rows::Vector{Vector{Cell}}
end

"""
    Update(table, columns, rows)

The op that updates the non-key columns `columns` of the rows of `table` named by key.

`columns` are in declaration order. Each row is `[key…, values…]`: the full key in key
declaration order, then one value per column. The rows are in typed key order.

Examples: test/test_ops_op_examples.jl
"""
struct Update <: Op
    table::String
    columns::Vector{String}
    rows::Vector{Vector{Cell}}
end

"""
    Delete(table, keys)

The op that deletes the rows of `table` at `keys`.

Each key is a vector of the key columns' cells in key declaration order. The keys are
in typed key order.

Examples: test/test_ops_op_examples.jl
"""
struct Delete <: Op
    table::String
    keys::Vector{Vector{Cell}}
end

# Fields compare with `isequal`, so an op holding NaN or `missing` equals itself.
function Base.:(==)(a::T, b::T) where {T <: Op}
    return all(f -> isequal(getfield(a, f), getfield(b, f)), fieldnames(T))
end

function Base.hash(op::T, h::UInt) where {T <: Op}
    return foldl((acc, f) -> hash(getfield(op, f), acc), fieldnames(T); init = hash(T, h))
end

const OP_NAMES = (
    CreateTable => "create_table", AddColumn => "add_column", DropColumn => "drop_column",
    DropTable => "drop_table", Insert => "insert", Update => "update", Delete => "delete",
)
const ENVELOPE_OF_OP = ("op", "table")
const NOT_A_TYPED_VALUE = "which is not a typed value"

# The wire discriminator of an op.
op_name(op::Op) = op_name(typeof(op))
function op_name(::Type{T}) where {T <: Op}
    return last(OP_NAMES[findfirst(p -> first(p) === T, OP_NAMES)])
end

# The wire form of an op, ready for `CBOR.encode` (ADR-0025).
function wire(op::CreateTable)
    return op_wire(op, "shape" => Model.wire(op.shape))
end

function wire(op::AddColumn)
    column = Any[op.column.name, op.column.type, op.column.nullable]
    return op_wire(op, "column" => column, "fill" => op.fill)
end

wire(op::DropColumn) = op_wire(op, "column" => op.column)
wire(op::DropTable) = op_wire(op)
wire(op::Insert) = op_wire(op, "rows" => rows_wire(op.rows))
function wire(op::Update)
    return op_wire(op, "columns" => Any[op.columns...], "rows" => rows_wire(op.rows))
end
wire(op::Delete) = op_wire(op, "keys" => rows_wire(op.keys))

function op_wire(op::Op, fields...)
    return Dict{String, Any}("op" => op_name(op), "table" => op.table, fields...)
end

rows_wire(rows) = Any[Any[row...] for row in rows]

# The fields each op carries besides "op" and "table": a wire op has exactly these.
op_fields(::Type{CreateTable}) = ("shape",)
op_fields(::Type{AddColumn}) = ("column", "fill")
op_fields(::Type{DropColumn}) = ("column",)
op_fields(::Type{DropTable}) = ()
op_fields(::Type{Insert}) = ("rows",)
op_fields(::Type{Update}) = ("columns", "rows")
op_fields(::Type{Delete}) = ("keys",)

# Reads one op from the wire form `CBOR.decode` yields. A cell is checked against its
# column at apply, where the shape is known; here it only has to be a typed value.
function op_from_wire(wire)
    wire isa AbstractDict ||
        throw(ModelError("op is not a map, got a value of type $(typeof(wire))"))
    haskey(wire, "op") || throw(ModelError("op has no \"op\" field"))
    haskey(wire, "table") || throw(ModelError("op has no \"table\" field"))
    T = op_type(wire["op"])
    stray = filter(k -> k ∉ ENVELOPE_OF_OP && k ∉ op_fields(T), collect(keys(wire)))
    isempty(stray) || throw(
        ModelError("unknown field $(repr(first(stray))) on $(with_article(op_name(T))) op")
    )
    return op_from_wire(T, wire, text_field(wire, T, "table"))
end

function op_from_wire(::Type{CreateTable}, wire, table)
    return CreateTable(table, Shape(field(wire, CreateTable, "shape")))
end

function op_from_wire(::Type{AddColumn}, wire, table)
    column = column_from_entry(field(wire, AddColumn, "column"))
    fill = field(wire, AddColumn, "fill")
    fill isa Cell || throw(ModelError(stray_value(AddColumn, "fill", fill)))
    return AddColumn(table, column, fill)
end

function op_from_wire(::Type{DropColumn}, wire, table)
    return DropColumn(table, text_field(wire, DropColumn, "column"))
end

op_from_wire(::Type{DropTable}, wire, table) = DropTable(table)
op_from_wire(::Type{Insert}, wire, table) = Insert(table, rows_field(wire, Insert, "rows"))

function op_from_wire(::Type{Update}, wire, table)
    columns = field(wire, Update, "columns")
    columns isa AbstractVector && all(c -> c isa String, columns) ||
        throw(ModelError("\"columns\" of an update op is not an array of names"))
    return Update(table, String[columns...], rows_field(wire, Update, "rows"))
end

op_from_wire(::Type{Delete}, wire, table) = Delete(table, rows_field(wire, Delete, "keys"))

function op_type(name)
    i = findfirst(p -> isequal(last(p), name), OP_NAMES)
    known = join(map(last, OP_NAMES), ", ")
    i === nothing && throw(ModelError("unknown op $(repr(name)); the ops are $known"))
    return first(OP_NAMES[i])
end

function field(wire, T, name)
    haskey(wire, name) || throw(ModelError("$(op_name(T)) op has no $(repr(name)) field"))
    return wire[name]
end

function text_field(wire, T, name)
    x = field(wire, T, name)
    x isa String ||
        throw(ModelError("$(repr(name)) of $(with_article(op_name(T))) op is not text"))
    return x
end

function rows_field(wire, T, name)
    rows = field(wire, T, name)
    op = with_article(op_name(T))
    rows isa AbstractVector && all(row -> row isa AbstractVector, rows) ||
        throw(ModelError("$(repr(name)) of $op op is not an array of arrays"))
    return [typed_row(row, T, name) for row in rows]
end

function typed_row(row, T, name)
    stray = findfirst(x -> !(x isa Cell), row)
    stray === nothing || throw(ModelError(stray_value(T, name, row[stray])))
    return Cell[row...]
end

function stray_value(T, name, x)
    op = with_article(op_name(T))
    return "$(repr(name)) of $op op holds a value of type $(typeof(x)), $NOT_A_TYPED_VALUE"
end

with_article(name) = (first(name) in "aeiou" ? "an " : "a ") * name
