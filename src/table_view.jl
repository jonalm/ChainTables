const READ_ONLY_COLUMN = "a table view's columns are read-only: every table(copy, :t) " *
    "at one head returns the same view; copy(column) is a vector of your own"

"""
    ReadOnlyColumn(data)

One column of a `TableView`: reads go to the view's own vector, and writes throw. A
bytes cell is copied on each read, because the cell is itself a mutable vector.
"""
struct ReadOnlyColumn{T, V <: AbstractVector{T}} <: AbstractVector{T}
    data::V
end

Base.size(column::ReadOnlyColumn) = size(column.data)
Base.IndexStyle(::Type{<:ReadOnlyColumn}) = IndexLinear()

Base.@propagate_inbounds function Base.getindex(column::ReadOnlyColumn, i::Int)
    return Model.owned_cell(column.data[i])
end

Base.setindex!(::ReadOnlyColumn, _, ::Int) = throw(ArgumentError(READ_ONLY_COLUMN))

# The fields are the documented way to read a view's head and columns, and `v[key]`,
# `haskey`, `get` and `keys` are its documented lookup (ADR-0024): no accessors, and
# the Base methods stay.
"""
    TableView

A read of one table of a local copy, fixed at the head the copy had when the view was
taken. Taken with `table`.

A `sync!` or `commit!` that moves the copy leaves the view as it was: the rows were
copied out. Every `table(copy, :t)` at one head returns the same view, so its columns
refuse writes; `copy(v.columns.x)` is a vector of your own.

A Tables.jl table: `Tables.columns(v)` is `v.columns`. Iterating `v` gives one
`NamedTuple` per row in typed key order, null as `missing`. `v[key]` is the row at a
primary key and throws `KeyError` when there is none; `haskey`, `get` and `keys` follow
Base. A composite key is a tuple in key declaration order, or the cells as arguments. A
`NamedTuple` that names every key column looks up its own key.

Fields: `name`; `chain_id`, `slot` and `transaction_hash`, the head this is a read of;
`columns`, a `NamedTuple` of read-only column vectors.
"""
struct TableView{C <: NamedTuple}
    name::String
    chain_id::String
    slot::Int64
    transaction_hash::TransactionHash
    shape::Model.Shape
    columns::C  # one ReadOnlyColumn per column, in declaration order
    slots::Vector{Int64}  # the row slot of each row, in the view's order (ADR-0032)
    index::Dict{Model.Key, Int}  # key tuple => row, in the view's order
end

# The rows are copied out of the model in typed key order, so that nothing done to the
# view reaches the model.
function TableView(name::AbstractString, head_file::Head, t::Model.Table)
    order = sortperm(Model.key_vector(t))
    names = Tuple(Symbol(c.name) for c in t.shape.columns)
    vectors = Tuple(ReadOnlyColumn(copied_column(column, order)) for column in t.columns)
    index = Dict{Model.Key, Int}(Model.key_at(t, p) => i for (i, p) in enumerate(order))
    transaction_hash = TransactionHash(head_file.transaction_hash)
    return TableView(
        String(name), head_file.chain_id, head_file.slot, transaction_hash, t.shape,
        NamedTuple{names}(vectors), t.slots[order], index,
    )
end

function copied_column(column, order)
    return eltype(column)[Model.owned_cell(column[p]) for p in order]
end

Base.eltype(::Type{TableView{C}}) where {C} = NamedTuple{fieldnames(C), row_types(C)}
Base.length(v::TableView) = length(v.slots)
Base.iterate(v::TableView, i::Int = 1) = i > length(v) ? nothing : (row(v, i), i + 1)

function Base.getindex(v::TableView, key)
    i = get(v.index, lookup_key(v, key), 0)
    i == 0 && throw(KeyError(key))
    return row(v, i)
end

Base.getindex(v::TableView, cell, next, cells...) = v[(cell, next, cells...)]
Base.haskey(v::TableView, key) = haskey(v.index, lookup_key(v, key))

function Base.get(v::TableView, key, default)
    i = get(v.index, lookup_key(v, key), 0)
    return i == 0 ? default : row(v, i)
end

function Base.keys(v::TableView)
    positions = v.shape.key_positions
    length(positions) == 1 && return copy(v.columns[only(positions)])
    return [Tuple(v.columns[j][i] for j in positions) for i in 1:length(v)]
end

# Valid Julia would write out every row, so the rows are summarised as a count.
function Base.show(io::IO, v::TableView)
    print(io, "TableView(")
    show(io, v.name)
    print(io, "; chain_id = ")
    show(io, v.chain_id)
    print(io, ", slot = ", v.slot, ", n_rows = ", length(v), ", columns = ")
    show(io, keys(v.columns))
    print(io, ")")
    return nothing
end

# The columns are the view's own, so nothing is copied (ADR-0043).
Tables.istable(::Type{<:TableView}) = true
Tables.columnaccess(::Type{<:TableView}) = true
Tables.columns(v::TableView) = v.columns
Tables.rowaccess(::Type{<:TableView}) = true
Tables.rows(v::TableView) = v
Tables.schema(::TableView{C}) where {C} = Tables.Schema(fieldnames(C), column_types(C))

"""
    table_with_slots(v::TableView)

Return the view's columns plus a `_slot` column, as a `NamedTuple` of vectors in the
view's order.

`_slot[i]` is the row slot of row `i`: the slot of the last transaction record that
changed its cells. It is at most `v.slot`, so the rows changed after slot `s` are those
with `_slot > s`. The vectors are the view's own read-only columns, not copies. No
column name starts with `_`, so `_slot` never collides.

Examples: test/test_table_view_examples.jl
"""
table_with_slots(v::TableView) = (; v.columns..., _slot = ReadOnlyColumn(v.slots))

column_types(::Type{C}) where {C} = map(eltype, fieldtypes(C))
row_types(::Type{C}) where {C} = Tuple{column_types(C)...}

row(v::TableView, i::Int) = eltype(typeof(v))(map(column -> column[i], v.columns))

# A row looks up its own key, and may name other columns too.
function lookup_key(v::TableView, named::NamedTuple)
    absent = findfirst(name -> !haskey(named, Symbol(name)), v.shape.key)
    absent === nothing || throw(ArgumentError(names_no_key_column(v, named, absent)))
    return Tuple(named[Symbol(name)] for name in v.shape.key)
end

function lookup_key(v::TableView, key::Tuple)
    n_key = length(v.shape.key)
    length(key) == n_key || throw(ArgumentError(does_not_address(v, key)))
    return key
end

function lookup_key(v::TableView, cell)
    length(v.shape.key) == 1 || throw(
        ArgumentError(
            "table $(repr(v.name)) has a composite key ($(key_names(v))); look it up " *
                "as a tuple in key declaration order, got $(repr(cell))"
        )
    )
    return (cell,)
end

function names_no_key_column(v::TableView, named, absent)
    return "table $(repr(v.name)): the row $(repr(named)) names no key column " *
        "$(repr(v.shape.key[absent])); a row looks up its key, so it names every key " *
        "column ($(key_names(v)))"
end

function does_not_address(v::TableView, key)
    kind = length(v.shape.key) == 1 ? "one-column" : "composite"
    return "table $(repr(v.name)) has a $kind key ($(key_names(v))); a key of " *
        "$(length(key)) cells does not address it"
end

key_names(v::TableView) = join(v.shape.key, ", ")
