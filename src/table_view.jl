# Docstring over 8 lines: one public type with four read surfaces.
"""
    TableView

A read of one table of a local copy, fixed at the head the copy had when the view was
taken with `table`. A `sync!` or `commit!` leaves every view already taken as it was,
and nothing done to a view reaches the copy.

Every `table(copy, :t)` at one head returns the same view, so it is read-only: writing
to a column throws `ArgumentError`; `copy(column)` is a vector of your own. A `bytes`
cell is copied each time it is read.

Iterating yields one `NamedTuple` per row in key order, fields in declaration order,
null as `missing`. It is a Tables.jl table: `Tables.columns(v)` is its own columns,
uncopied. `v[k]` is the row at primary key `k` (`KeyError` when absent), with `haskey`,
`get` and `keys`. A composite key is a tuple in key declaration order, or the cells as
arguments, `v[a, b]`; a row looks up its own key, `v[first(v)]`.

The fields `name`, `chain_id`, `slot` and `transaction_hash` name the head it was taken
at; `columns` is the `NamedTuple` of read-only columns.

Examples: test/test_table_view_examples.jl
"""
struct TableView{C <: NamedTuple}
    name::String
    chain_id::String
    slot::Int64
    transaction_hash::TransactionHash
    shape::Shape
    columns::C # a ReadOnlyColumn per column, in declaration order
    slots::Vector{Int64} # each row's row slot, in the view's order (ADR-0032)
    index::Dict{Any, Int} # key tuple => row number
    nrows::Int
end

"""
    ReadOnlyColumn

A column of a `TableView`: reads go to the view's own vector, writes throw. A bytes cell
is copied on read, because the cell is itself a mutable vector.
"""
struct ReadOnlyColumn{T, V <: AbstractVector{T}} <: AbstractVector{T}
    data::V
end

# Every caller at one head shares the view (ADR-0043).
const READ_ONLY_MESSAGE = "a table view's columns are read-only: every table(copy, :t) " *
    "at one head returns the same view; copy(column) is a vector of your own"

# The rows of a model table, copied out in key order: every column vector is fresh, and
# a bytes cell is copied, so nothing done to the view reaches the model.
# style: inferred the column types are read from the table at run time
function TableView(name::AbstractString, h::Head, t::Table)
    perm = sortperm(key_vector(t))
    names = Tuple(Symbol(c.name) for c in t.shape.columns)
    # A model Table holds one vector per shape column, so map sees equal lengths.
    vectors = map((c, col) -> read_only_column(c, col, perm), t.shape.columns, t.columns)
    columns = NamedTuple{names}(Tuple(vectors))
    index = Dict{Any, Int}(key_at(t, p) => i for (i, p) in enumerate(perm))
    return TableView(
        String(name), h.chain_id, h.slot, TransactionHash(h.transaction_hash), t.shape,
        columns, t.slots[perm], index, length(perm)
    )
end

Base.size(c::ReadOnlyColumn) = size(c.data)
Base.IndexStyle(::Type{<:ReadOnlyColumn}) = IndexLinear()
Base.@propagate_inbounds Base.getindex(c::ReadOnlyColumn, i::Int) = own_cell(c.data[i])
Base.setindex!(::ReadOnlyColumn, _, ::Int) = throw(ArgumentError(READ_ONLY_MESSAGE))

own_cell(x::AbstractVector{UInt8}) = copy(x)
own_cell(x) = x

function read_only_column(c::Column, column, perm)
    out = column[perm]
    c.type == "bytes" && map!(copy_cell, out, out)
    return ReadOnlyColumn(out)
end

copy_cell(x) = x === missing ? missing : copy(x)

"""
    table_with_slots(v::TableView) -> NamedTuple

The view's columns plus a `_slot` column, `(; v.columns..., _slot)`: a Tables.jl table.

`_slot[i]` is the row slot of row `i`, the slot of the last transaction record that
changed its cells, never above `v.slot`. The rows changed after slot `s` are those with
`_slot > s`. The vectors are the view's own read-only columns, not copies.

Examples: test/test_table_view_examples.jl
"""
table_with_slots(v::TableView) = (; v.columns..., _slot = ReadOnlyColumn(v.slots))

function Base.eltype(::Type{TableView{C}}) where {C}
    return NamedTuple{fieldnames(C), Tuple{map(eltype, fieldtypes(C))...}}
end
Base.length(v::TableView) = v.nrows
Base.iterate(v::TableView, i::Int = 1) = i > v.nrows ? nothing : (row(v, i), i + 1)

row(v::TableView, i::Int) = eltype(typeof(v))(map(c -> c[i], v.columns))

# Tables.jl, natively (ADR-0043): the columns are the view's own, so nothing is copied.
Tables.istable(::Type{<:TableView}) = true
Tables.columnaccess(::Type{<:TableView}) = true
Tables.columns(v::TableView) = v.columns
Tables.rowaccess(::Type{<:TableView}) = true
Tables.rows(v::TableView) = v
function Tables.schema(v::TableView{C}) where {C}
    return Tables.Schema(fieldnames(C), map(eltype, fieldtypes(C)))
end

function Base.getindex(v::TableView, k)
    i = get(v.index, lookup_key(v, k), 0)
    i == 0 && throw(KeyError(k))
    return row(v, i)
end
Base.getindex(v::TableView, k1, k2, ks...) = v[(k1, k2, ks...)]
Base.haskey(v::TableView, k) = haskey(v.index, lookup_key(v, k))
function Base.get(v::TableView, k, default)
    i = get(v.index, lookup_key(v, k), 0)
    return i == 0 ? default : row(v, i)
end

function Base.keys(v::TableView)
    idx = v.shape.keyidx
    length(idx) == 1 && return copy(v.columns[only(idx)])
    return [Tuple(v.columns[j][i] for j in idx) for i in 1:v.nrows]
end

# Valid Julia would spell out every row; the summary names the head instead.
function Base.show(io::IO, v::TableView)
    print(
        io, "TableView(:", v.name, " at slot ", v.slot, " of chain ", v.chain_id, "; ",
        v.nrows, " rows, columns ", join(keys(v.columns), ", "), ")"
    )
    return nothing
end

# Dispatch, not if/elseif: each kind of key is one Guard and one return.
"""
    lookup_key(v, k) -> Tuple

The index key `k` addresses: a row gives its key columns, and may name others; a
composite key is a tuple in key declaration order; a one-column key also accepts the
bare value. Throws `ArgumentError` for a key of the wrong arity.
"""
function lookup_key(v::TableView, k::NamedTuple)
    foreach(c -> check_row_names_key(v, k, c), v.shape.key)
    return Tuple(k[Symbol(c)] for c in v.shape.key)
end

function lookup_key(v::TableView, k::Tuple)
    n_key = length(v.shape.keyidx)
    length(k) == n_key || throw(
        ArgumentError(
            "table $(repr(v.name)) has a $(key_kind(n_key)) key ($(key_list(v))); " *
                "a key of $(length(k)) cells does not address it"
        )
    )
    return k
end

function lookup_key(v::TableView, k)
    length(v.shape.keyidx) == 1 || throw(
        ArgumentError(
            "table $(repr(v.name)) has a composite key ($(key_list(v))); look it up as " *
                "a tuple in key declaration order, got $(repr(k))"
        )
    )
    return (k,)
end

function check_row_names_key(v::TableView, k::NamedTuple, c)
    haskey(k, Symbol(c)) || throw(
        ArgumentError(
            "table $(repr(v.name)): the row $(repr(k)) names no key column $(repr(c)); " *
                "a row looks up its key, so it names every key column ($(key_list(v)))"
        )
    )
    return nothing
end

key_kind(n_key) = n_key == 1 ? "one-column" : "composite"
key_list(v::TableView) = join(v.shape.key, ", ")
