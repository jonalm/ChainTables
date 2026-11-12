const VALUE_TYPES = ("int64", "float64", "text", "bytes")
const VALUE_TYPE_LIST = "a column holds int64, float64, text or bytes"
const SHAPE_FIELDS = ("columns", "key")
const NOT_COLUMN_NAME = "is not an identifier " *
    "([a-z][a-z0-9_]*: a column name starts with a letter)"
const NOT_COLUMN_ENTRY = "is not [name, type, nullable]"
const KEY_NOT_NULLABLE = "key columns are non-nullable"
const NO_KEY = "table has no primary key; every table needs an explicit key"

"""
    Column(name, type, nullable)

One column of a shape: its name, its value type (`"int64"`, `"float64"`, `"text"` or
`"bytes"`) and whether it admits null.
"""
struct Column
    name::String
    type::String
    nullable::Bool
end

"""
    Shape(columns::Vector{Column}, key::Vector{String})
    Shape(wire::AbstractDict)

A table's shape: its columns in declaration order and its primary key in key declaration
order. The constructor enforces every structural rule and throws `ModelError` otherwise.
The second form reads the wire form `{"columns": [[name, type, nullable], …], "key":
[name, …]}` as `CBOR.decode` yields it; `shape_wire` is its inverse.
"""
struct Shape
    columns::Vector{Column}
    key::Vector{String}
    keyidx::Vector{Int} # key column positions, in key declaration order
    function Shape(columns, key)
        columns = collect(Column, columns)
        key = collect(String, key)
        check_columns(columns)
        return new(columns, key, key_positions(columns, key))
    end
end

Base.:(==)(a::Shape, b::Shape) = a.columns == b.columns && a.key == b.key
Base.hash(s::Shape, h::UInt) = hash(s.key, hash(s.columns, hash(:Shape, h)))

function Shape(wire::AbstractDict)
    unknown = filter(∉(SHAPE_FIELDS), collect(keys(wire)))
    isempty(unknown) ||
        throw(ModelError(; detail = "unknown shape field $(repr(first(unknown)))"))
    haskey(wire, "columns") || throw(ModelError(; detail = "shape has no \"columns\""))
    haskey(wire, "key") || throw(ModelError(; detail = "shape has no \"key\""))
    entries = wire["columns"]
    entries isa AbstractVector ||
        throw(ModelError(; detail = "shape \"columns\" is not an array"))
    key = wire["key"]
    is_name_list(key) ||
        throw(ModelError(; detail = "shape \"key\" is not an array of names"))
    return Shape(map(column_from_entry, entries), String[key...])
end

# The wire form is decoded data: anything but a map is refused with its type named.
function Shape(wire)
    throw(ModelError(; detail = "shape is not a map, got a value of type $(typeof(wire))"))
end

"""
    shape_wire(shape) -> Dict{String,Any}

Return the shape's wire form for `CBOR.encode`: one encoding whether it sits in a table
file or in a `create_table` op.
"""
function shape_wire(s::Shape)
    return Dict{String, Any}(
        "columns" => Any[Any[c.name, c.type, c.nullable] for c in s.columns],
        "key" => Any[s.key...],
    )
end

"""
    julia_type(value_type) -> Type

Return the one Julia carrier of a value type: `Int64`, `Float64`, `String` or
`Vector{UInt8}`. Throws `ModelError` for an unknown value type.
"""
function julia_type(t::AbstractString)
    t == "int64" && return Int64
    t == "float64" && return Float64
    t == "text" && return String
    t == "bytes" && return Vector{UInt8}
    throw(ModelError(; detail = "unknown value type $(repr(t)); $VALUE_TYPE_LIST"))
end

"""
    value_type(x) -> Union{Nothing,String}

Return the value type `x` is a carrier of, or `nothing` when `x` is not exactly one of
the four carriers (`missing`, `Bool`, `Int32` and a `SubString` all give `nothing`).
"""
value_type(::Int64) = "int64"
value_type(::Float64) = "float64"
value_type(::String) = "text"
value_type(::Vector{UInt8}) = "bytes"
value_type(::Any) = nothing

"""
    is_identifier(s) -> Bool

Return whether `s` is a table name: `[a-z_][a-z0-9_]*`.
"""
is_identifier(s::AbstractString) = occursin(r"\A[a-z_][a-z0-9_]*\z", s)

"""
    is_column_name(s) -> Bool

Return whether `s` is a column name: `[a-z][a-z0-9_]*`. A letter comes first, so no
column collides with the `_slot` of `table_with_slots`.
"""
is_column_name(s::AbstractString) = occursin(r"\A[a-z][a-z0-9_]*\z", s)

"""
    check_column_name(name) -> nothing

Throw `ModelError` unless `name` is a column name, worded as every refusal of one is.
"""
function check_column_name(name)
    is_column_name(name) || throw(
        ModelError(; detail = "column name $(repr(name)) $NOT_COLUMN_NAME")
    )
    return nothing
end

n_columns(s::Shape) = length(s.columns)

"""
    column_index(shape, name) -> Int

Return the declaration position of column `name`. Throws `ModelError` when there is none.
"""
function column_index(s::Shape, name::AbstractString)
    j = findfirst(c -> c.name == name, s.columns)
    j === nothing && throw(ModelError(; detail = "unknown column $(repr(name))"))
    return j
end

"""
    key_of(shape, row) -> Tuple

Return the primary key of a row (cells in declaration order), as the tuple the typed key
order and the index are defined on.
"""
key_of(s::Shape, row) = Tuple(row[j] for j in s.keyidx)

function check_columns(columns::Vector{Column})
    isempty(columns) && throw(ModelError(; detail = "table has no columns"))
    names = String[]
    for c in columns
        check_column_name(c.name)
        c.name in names &&
            throw(ModelError(; detail = "duplicate column name $(repr(c.name))"))
        c.type in VALUE_TYPES || throw(
            ModelError(; detail = "unknown value type $(repr(c.type)); $VALUE_TYPE_LIST")
        )
        push!(names, c.name)
    end
    return nothing
end

function key_positions(columns::Vector{Column}, key::Vector{String})
    isempty(key) && throw(ModelError(; detail = NO_KEY))
    positions = Int[]
    for k in key
        j = findfirst(c -> c.name == k, columns)
        j === nothing && throw(
            ModelError(; detail = "key column $(repr(k)) is not a column of the table")
        )
        j in positions && throw(ModelError(; detail = "duplicate key column $(repr(k))"))
        columns[j].nullable && throw(
            ModelError(; detail = "key column $(repr(k)) is nullable; $KEY_NOT_NULLABLE")
        )
        push!(positions, j)
    end
    return positions
end

"""
    column_from_entry(entry) -> Column

Read one wire column entry, `[name, type, nullable]`. Throws `ModelError` for any other
form; the name and type are checked where the column joins a shape.
"""
function column_from_entry(e)
    is_column_entry(e) ||
        throw(ModelError(; detail = "column entry $(repr(e)) $NOT_COLUMN_ENTRY"))
    return Column(e[1], e[2], e[3])
end

function is_column_entry(e)
    return e isa AbstractVector && length(e) == 3 &&
        e[1] isa String && e[2] isa String && e[3] isa Bool
end

is_name_list(x) = x isa AbstractVector && all(k -> k isa String, x)
