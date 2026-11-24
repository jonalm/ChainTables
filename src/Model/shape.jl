const VALUE_TYPES = ("int64", "float64", "text", "bytes")

# A cell holds exactly one of these carriers, or `missing` where the column is nullable
# (ADR-0025). Nothing is widened or converted: an `Int32`, a `Bool` or a `SubString` is
# refused, because the model is the last stop before the frozen encoder.
const CARRIER_TYPES = (Int64, Float64, String, Vector{UInt8})
const CARRIERS = Dict(zip(VALUE_TYPES, CARRIER_TYPES))
const Cell = Union{Missing, CARRIER_TYPES...}

const HELD_TYPES = "a column holds int64, float64, text or bytes"
const COLUMN_NAME_RULE = "is not an identifier " *
    "([a-z][a-z0-9_]*: a column name starts with a letter)"
const SHAPE_FIELDS = ("columns", "key")

"""
    Column(name, type, nullable)

One column of a shape: its name, its value type (`"int64"`, `"float64"`, `"text"` or
`"bytes"`) and whether it admits null.

A `Shape` checks the name and the value type; a `Column` alone checks nothing.

Examples: test/test_model_shape_examples.jl
"""
struct Column
    name::String
    type::String
    nullable::Bool
end

"""
    Shape(columns, key)
    Shape(wire)

A table's shape: its columns in declaration order and its primary key, the names of the
key columns in key declaration order.

A shape has at least one column, column names that are distinct identifiers, known value
types, and a non-empty key of distinct, existing, non-nullable columns. The second form
reads the wire form that `CBOR.decode` yields,
`{"columns": [[name, type, nullable], …], "key": [name, …]}`, and refuses any other
field. Throws the internal `ModelError` when a rule is broken.

Examples: test/test_model_shape_examples.jl
"""
struct Shape
    columns::Vector{Column}
    key::Vector{String}
    key_positions::Vector{Int}  # of the key columns in `columns`, in key declaration order
    function Shape(columns, key)
        columns = collect(Column, columns)
        key = collect(String, key)
        check_columns(columns)
        return new(columns, key, key_positions(columns, key))
    end
end

function Shape(wire)
    wire isa AbstractDict ||
        throw(ModelError("shape is not a map, got a value of type $(typeof(wire))"))
    unknown = filter(!in(SHAPE_FIELDS), collect(keys(wire)))
    isempty(unknown) || throw(ModelError("unknown shape field $(repr(first(unknown)))"))
    haskey(wire, "columns") || throw(ModelError("shape has no \"columns\""))
    haskey(wire, "key") || throw(ModelError("shape has no \"key\""))
    entries = wire["columns"]
    entries isa AbstractVector || throw(ModelError("shape \"columns\" is not an array"))
    columns = map(column_from_entry, entries)
    key = wire["key"]
    key isa AbstractVector && all(k -> k isa String, key) ||
        throw(ModelError("shape \"key\" is not an array of names"))
    return Shape(columns, String[key...])
end

Base.:(==)(a::Shape, b::Shape) = a.columns == b.columns && a.key == b.key
Base.hash(s::Shape, h::UInt) = hash(s.key, hash(s.columns, hash(:Shape, h)))

function check_columns(columns)
    isempty(columns) && throw(ModelError("table has no columns"))
    seen = Set{String}()
    for c in columns
        check_column_name(c.name)
        c.name in seen && throw(ModelError("duplicate column name $(repr(c.name))"))
        c.type in VALUE_TYPES ||
            throw(ModelError("unknown value type $(repr(c.type)); $HELD_TYPES"))
        push!(seen, c.name)
    end
    return nothing
end

function check_column_name(name)
    is_column_name(name) ||
        throw(ModelError("column name $(repr(name)) $COLUMN_NAME_RULE"))
    return nothing
end

# A letter first, so a column never collides with the `_slot` of `table_with_slots`
# (ADR-0032).
is_column_name(s::AbstractString) = occursin(r"\A[a-z][a-z0-9_]*\z", s)

is_identifier(s::AbstractString) = occursin(r"\A[a-z_][a-z0-9_]*\z", s)

function key_positions(columns, key)
    isempty(key) &&
        throw(ModelError("table has no primary key; every table needs an explicit key"))
    positions = Int[]
    for k in key
        j = findfirst(c -> c.name == k, columns)
        j === nothing &&
            throw(ModelError("key column $(repr(k)) is not a column of the table"))
        j in positions && throw(ModelError("duplicate key column $(repr(k))"))
        columns[j].nullable && throw(
            ModelError("key column $(repr(k)) is nullable; key columns are non-nullable")
        )
        push!(positions, j)
    end
    return positions
end

function column_from_entry(entry)
    is_column_entry(entry) ||
        throw(ModelError("column entry $(repr(entry)) is not [name, type, nullable]"))
    return Column(entry[1], entry[2], entry[3])
end

function is_column_entry(entry)
    entry isa AbstractVector && length(entry) == 3 || return false
    return entry[1] isa String && entry[2] isa String && entry[3] isa Bool
end

# One encoding of a shape, whether it sits in a table file or in a `create_table` op
# (ADR-0025).
function wire(s::Shape)
    columns = Any[Any[c.name, c.type, c.nullable] for c in s.columns]
    return Dict{String, Any}("columns" => columns, "key" => Any[s.key...])
end

function julia_type(value_type::AbstractString)
    haskey(CARRIERS, value_type) ||
        throw(ModelError("unknown value type $(repr(value_type)); $HELD_TYPES"))
    return CARRIERS[value_type]
end

function column_index(s::Shape, name::AbstractString)
    j = findfirst(c -> c.name == name, s.columns)
    j === nothing && throw(ModelError("unknown column $(repr(name))"))
    return j
end

# The key as a tuple: the typed key order and the row index are defined on it.
key_of(s::Shape, row) = Tuple(row[j] for j in s.key_positions)
