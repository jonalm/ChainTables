const INSERT_RULE = "an insert names every column"
const UPDATE_RULE = "an update names the full key"
const DELETE_RULE = "a delete names the full key"

const NOT_A_ROW = Union{
    Number, AbstractString, AbstractVector, Tuple, AbstractChar, Symbol, Nothing, Missing,
}

"""
    row_set(rows) -> (rows, names)

The rows as a vector, and the column names they all name. A row is anything with
`propertynames` and `getproperty`: a `NamedTuple`, a Tables.jl row, a `DataFrameRow`.
A row set is non-empty and its rows name the same columns.
"""
function row_set(rows)
    rows isa NamedTuple &&
        fail("a row set is a collection of rows, got one NamedTuple; wrap it in a vector")
    rs = collect(rows)
    isempty(rs) && fail("the row set is empty; an op carries at least one row")
    foreach(check_is_row, eachindex(rs), rs)
    names = Symbol[propertynames(first(rs))...]
    foreach(i -> check_uniform_names(rs[i], i, names), 2:length(rs))
    return rs, names
end

function check_is_row(i, r)
    is_row(r) ||
        fail(
        "row $i is not a row (a NamedTuple or a Tables.jl row), " *
            "got a value of type $(typeof(r))"
    )
    return nothing
end

is_row(::NOT_A_ROW) = false
is_row(_) = true

function check_uniform_names(r, i, names)
    n = propertynames(r)
    length(n) == length(names) && all(in(names), n) || fail(
        "row $i names columns $(Tuple(n)) but row 1 names $(Tuple(names)); " *
            "the columns of an op are uniform"
    )
    return nothing
end

function check_insert_names(s::Shape, names)
    foreach(n -> column_index(s, String(n)), names)
    foreach(c -> require_named(names, "column", c.name, INSERT_RULE), s.columns)
    return nothing
end

function check_update_names(s::Shape, names)
    foreach(n -> column_index(s, String(n)), names)
    foreach(k -> require_named(names, "key column", k, UPDATE_RULE), s.key)
    return nothing
end

function check_delete_names(s::Shape, names)
    foreach(n -> require_key_column(s, n), names)
    foreach(k -> require_named(names, "key column", k, DELETE_RULE), s.key)
    return nothing
end

function require_named(names, label, column, rule)
    Symbol(column) in names || fail("row set names no $label $(repr(column)); $rule")
    return nothing
end

function require_key_column(s::Shape, n::Symbol)
    c = s.columns[column_index(s, String(n))]
    c.name in s.key ||
        fail("row set names column $(repr(c.name)); a delete names the key columns only")
    return nothing
end

"""
    cell(column, x)

`x` as the typed value `column` stores: integers and floats widen, every NaN becomes
the one canonical NaN, text is checked, and any `AbstractVector{UInt8}` becomes a
`Vector{UInt8}`. A value of another type passes through for the model's check to refuse.
"""
cell(::Column, x::Int64) = x
# Every NaN encodes as f97e00 (ADR-0025): sign and payload are dropped.
cell(::Column, x::Float64) = isnan(x) ? NaN : x
cell(c::Column, x::String) = Ops.check_text("column $(repr(c.name))", x)
# The model copies the vector when it takes the row.
cell(::Column, x::Vector{UInt8}) = x
cell(::Column, ::Missing) = missing
cell(c::Column, x::Union{Int8, Int16, Int32}) = cell(c, Int64(x))
cell(c::Column, x::Union{Float16, Float32}) = cell(c, Float64(x))
cell(c::Column, x::AbstractString) = cell(c, String(x))
cell(c::Column, x::AbstractVector{UInt8}) = cell(c, Vector{UInt8}(x))
function cell(c::Column, ::Nothing)
    return fail("column $(repr(c.name)): nothing is not a value; null is spelt missing")
end
# check_cell refuses it, naming the column and the type.
cell(::Column, x) = x

cells(columns, row) = Any[cell(c, getproperty(row, Symbol(c.name))) for c in columns]

# The non-key columns the rows name, in declaration order whatever the rows' field order.
function changed_columns(s::Shape, names)
    return [c for c in s.columns if Symbol(c.name) in names && !(c.name in s.key)]
end

# Each row as [key…, values…], the key in key declaration order, sorted by key.
function update_vectors(s::Shape, value_columns, rs)
    key_columns = s.columns[s.keyidx]
    n_key = length(key_columns)
    rows = (vcat(cells(key_columns, r), cells(value_columns, r)) for r in rs)
    return Ops.sort_rows(rows, r -> Tuple(r[1:n_key]))
end
