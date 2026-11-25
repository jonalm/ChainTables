const TYPE_TAGS = join(Model.CARRIER_TYPES, ", ")
const TAG_HINTS = (
    AbstractString => "; a text column's tag is String",
    Int32 => "; Int32 values widen at insert, the tag is Int64",
    Float32 => "; Float32 values widen at insert, the tag is Float64",
)

# A row is anything with `propertynames` and `getproperty`: a `NamedTuple`, a Tables.jl
# row, a `DataFrameRow`. These are the values that are certainly none.
const NotARow = Union{
    AbstractChar, AbstractString, AbstractVector, Missing, Nothing, Number, Symbol, Tuple,
}

function name_text(kind, name)
    name isa Union{Symbol, AbstractString} ||
        throw(Model.ModelError("$kind name $(repr(name)) is not a Symbol"))
    return String(name)
end

# A type tag is the Julia type that the write builder takes for a value type, by
# identity: `Int` is `Int64` on a 64-bit platform, and nothing else is a tag.
function value_type_of_tag(T, column)
    position = findfirst(carrier -> carrier === T, Model.CARRIER_TYPES)
    position === nothing && throw(
        Model.ModelError(
            "type tag $(repr(T)) for column $(repr(column)) is not one of " *
                "$TYPE_TAGS$(tag_hint(T))"
        )
    )
    return Model.VALUE_TYPES[position]
end

function tag_hint(T)
    position = findfirst(hint -> first(hint) === T, TAG_HINTS)
    return position === nothing ? "" : last(TAG_HINTS[position])
end

# The rows as a vector, and the columns that they all name.
function named_rows(rows)
    rows isa NamedTuple && throw(
        Model.ModelError(
            "a row set is a collection of rows, got one NamedTuple; wrap the row in a " *
                "vector"
        )
    )
    row_set = collect(rows)
    isempty(row_set) &&
        throw(Model.ModelError("the row set is empty; an op carries at least one row"))
    foreach(i -> check_is_row(row_set[i], i), eachindex(row_set))
    names = Symbol[propertynames(first(row_set))...]
    foreach(i -> check_same_names(row_set[i], i, names), eachindex(row_set))
    return row_set, names
end

function check_is_row(row, i)
    row isa NotARow && throw(
        Model.ModelError(
            "row $i is not a row (a NamedTuple or a Tables.jl row), got a value of type " *
                "$(typeof(row))"
        )
    )
    return nothing
end

function check_same_names(row, i, names)
    own = propertynames(row)
    length(own) == length(names) && all(in(names), own) || throw(
        Model.ModelError(
            "row $i names columns $(Tuple(own)) but row 1 names $(Tuple(names)); the " *
                "columns of an op are uniform"
        )
    )
    return nothing
end

# A value that is no typed value after these conversions is left as it is:
# `Model.check_cell` refuses it, naming the column and the type.
function canonical_cells(columns, row)
    return Any[canonical_cell(c, getproperty(row, Symbol(c.name))) for c in columns]
end

canonical_cell(::Model.Column, x) = x
canonical_cell(::Model.Column, x::Union{Int8, Int16, Int32}) = Int64(x)
# Every NaN becomes the one that the encoder writes: sign and payload are dropped.
canonical_cell(::Model.Column, x::Float64) = isnan(x) ? NaN : x
canonical_cell(c::Model.Column, x::Union{Float16, Float32}) = canonical_cell(c, Float64(x))
canonical_cell(c::Model.Column, x::AbstractString) = canonical_cell(c, String(x))
canonical_cell(::Model.Column, x::AbstractVector{UInt8}) = Vector{UInt8}(x)

function canonical_cell(c::Model.Column, x::String)
    Ops.check_text("column $(repr(c.name))", x)
    return x
end

function canonical_cell(c::Model.Column, ::Nothing)
    throw(
        Model.ModelError(
            "column $(repr(c.name)): nothing is not a value; null is spelt missing"
        )
    )
end
