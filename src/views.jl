# #34 step 8 — ADR-0024, ADR-0019, ADR-0025: the read surface. A `TableView` is a
# Tables.jl table fixed at the head it was taken at, copied out of the model into its own
# column vectors, with a key lookup; `table` takes one and caches it per table per head;
# `shape` is the declaration. ADR-0043: the cached view is shared by every caller at its
# head, so it hands out read-only columns, and it implements Tables.jl natively.

using .Model: Shape
import Tables

"""
    TableView

A read of one table of a local copy, fixed at the head the copy had when the view was
taken (ADR-0024): the only way content is read. Taken with [`table`](@ref); a `sync!`
or `commit!` that moves the copy leaves every view already taken exactly as it was, and
nothing done to a view reaches the copy — the rows were **copied out of the model** into
the view's own column vectors, `bytes` cells included.

**Read-only** (ADR-0043): every `table(copy, :t)` at one head returns this same view, so
its columns refuse writes. `v.columns.x[1] = …` raises; `copy(v.columns.x)` is a vector
of your own. A `bytes` cell is copied each time it is read, so changing one changes only
that copy.

A **Tables.jl table**, natively: `Tables.columns(v)` is `v.columns` with no copy,
`Tables.rows(v)` is `v`, and `Tables.schema(v)` is the declared names and types.
Iterating `v` yields one `NamedTuple` per row in typed key order (ADR-0025), fields in
declaration order, null as `missing`; `length(v)` is the row count and `eltype(v)` the
row type, a nullable column typed `Union{Missing,T}`. A row set read this way goes into
the write builder with no conversion.

A **key lookup**: `v[k]` is the row at primary key `k` and raises `KeyError` when there is
none; `haskey(v, k)`, `get(v, k, default)` and `keys(v)` — every key, in order — follow
Base. A composite key is a tuple in key declaration order, or the cells as arguments,
`v[a, b]`; a one-column key accepts the bare value, and a tuple. A row — any
`NamedTuple` that names every key column, such as one read from a view — looks up its
own key: `v[first(v)]`.

Fields: `name`, the table; `chain_id`, `slot` and `transaction_hash` (a
[`TransactionHash`](@ref)), the head this is a read of, so that staleness is inspectable;
`columns`, the `NamedTuple` of read-only column vectors; `shape`, the model's
[`Shape`](@ref) — [`shape`](@ref)`(v)` is its public form.
"""
struct TableView{C<:NamedTuple}
    name::String
    chain_id::String
    slot::Int64
    transaction_hash::TransactionHash
    shape::Shape
    columns::C                    # ReadOnlyColumn per column, in declaration order
    slots::Vector{Int64}          # row slot of each row, in the view's order (ADR-0032)
    index::Dict{Any,Int}          # key tuple => row, in the view's order
    nrows::Int
end

# A column of a view (ADR-0043): reads go to the view's own vector, writes raise. A bytes
# cell is copied on read, because the cell is itself a mutable vector.
struct ReadOnlyColumn{T,V<:AbstractVector{T}} <: AbstractVector{T}
    data::V
end
Base.size(c::ReadOnlyColumn) = size(c.data)
Base.IndexStyle(::Type{<:ReadOnlyColumn}) = IndexLinear()
Base.@propagate_inbounds Base.getindex(c::ReadOnlyColumn, i::Int) = own_cell(c.data[i])
Base.setindex!(::ReadOnlyColumn, _, ::Int) =
    throw(ArgumentError("a table view's columns are read-only: every table(copy, :t) at one head returns the same view " *
                        "(ADR-0043); copy(column) is a vector of your own"))
own_cell(x::AbstractVector{UInt8}) = copy(x)
own_cell(x) = x

# The rows of a model table, copied out in typed key order: every column vector is fresh,
# and a bytes cell is copied so that nothing a user does to the view reaches the model.
function TableView(name::AbstractString, h::Head, t::Model.Table)
    perm = sortperm(Model.key_vector(t))
    names = Tuple(Symbol(c.name) for c in t.shape.columns)
    vectors = map(zip(t.shape.columns, t.columns)) do (c, col)
        out = col[perm]
        c.type == "bytes" && map!(x -> x === missing ? missing : copy(x), out, out)
        ReadOnlyColumn(out)
    end
    columns = NamedTuple{names}(Tuple(vectors))
    index = Dict{Any,Int}()
    for (i, p) in enumerate(perm)
        index[Model.key_at(t, p)] = i
    end
    return TableView(String(name), h.chain_id, h.slot, TransactionHash(h.transaction_hash), t.shape, columns, t.slots[perm],
                     index, length(perm))
end

"""
    ChainTables.table_with_slots(v::TableView) -> NamedTuple

The view's columns plus a `_slot` column: `(; v.columns..., _slot)`, a `NamedTuple` of
vectors in the view's key order, so a Tables.jl table (ADR-0032). `_slot[i]` is the
**row slot** of row `i`: the slot of the last transaction record that changed its
cells — an `insert` or `update` naming it, or an `add_column`/`drop_column` on its
table. It is per row and always ≤ `v.slot`, which is the head the view was taken at.
The rows changed after slot `s` are exactly those with `_slot > s`.

The vectors are the view's own read-only columns, not copies (ADR-0043).
`Tables.columns(v)` stays pure content, so a row set read from a view goes back into the
write builder unchanged; this is the opt-in read that carries the slots. No column name
starts with `_`, so `_slot` never collides (ADR-0025).
"""
table_with_slots(v::TableView) = (; v.columns..., _slot = ReadOnlyColumn(v.slots))

Base.eltype(::Type{TableView{C}}) where {C} = NamedTuple{fieldnames(C),Tuple{map(eltype, fieldtypes(C))...}}
Base.length(v::TableView) = v.nrows
Base.iterate(v::TableView, i::Int = 1) = i > v.nrows ? nothing : (row(v, i), i + 1)
row(v::TableView, i::Int) = eltype(typeof(v))(map(c -> c[i], v.columns))

# Tables.jl, natively (ADR-0043): the columns are the view's own, so nothing is copied.
Tables.istable(::Type{<:TableView}) = true
Tables.columnaccess(::Type{<:TableView}) = true
Tables.columns(v::TableView) = v.columns
Tables.rowaccess(::Type{<:TableView}) = true
Tables.rows(v::TableView) = v
Tables.schema(v::TableView{C}) where {C} = Tables.Schema(fieldnames(C), map(eltype, fieldtypes(C)))

# The index key for a lookup: a composite key is a tuple in key declaration order; a
# one-column key accepts the bare value or a tuple; a row (a NamedTuple) gives its key
# columns, and may name others.
function lookup_key(v::TableView, k)
    nk = length(v.shape.keyidx)
    if k isa NamedTuple
        for c in v.shape.key
            haskey(k, Symbol(c)) || throw(ArgumentError("table $(repr(v.name)): the row $(repr(k)) names no key column " *
                "$(repr(c)); a row looks up its key, so it names every key column ($(join(v.shape.key, ", ")))"))
        end
        return Tuple(k[Symbol(c)] for c in v.shape.key)
    end
    if k isa Tuple
        length(k) == nk || throw(ArgumentError("table $(repr(v.name)) has a $(nk == 1 ? "one-column" : "composite") key " *
            "($(join(v.shape.key, ", "))); a key of $(length(k)) cells does not address it"))
        return k
    end
    nk == 1 || throw(ArgumentError("table $(repr(v.name)) has a composite key ($(join(v.shape.key, ", "))); look it up as " *
        "a tuple in key declaration order, got $(repr(k))"))
    return (k,)
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
    length(idx) == 1 && return copy(v.columns[idx[1]])
    return [Tuple(v.columns[j][i] for j in idx) for i in 1:v.nrows]
end

Base.show(io::IO, v::TableView) = print(io, "TableView(:", v.name, " at slot ", v.slot, " of chain ", v.chain_id, "; ",
                                        v.nrows, " rows, columns ", join(keys(v.columns), ", "), ")")

"""
    table(copy, :t) -> TableView

The [`TableView`](@ref) of table `t` as of the copy's head now (ADR-0024): the table is
loaded if it is not yet (hash-before-use, ADR-0023) and its rows copied out, once per
table per head — a second `table(copy, :t)` before the head moves returns the same
object, and the cache is dropped when the head moves or the copy closes. Every caller
shares that view, so its columns are read-only (ADR-0043). No network
I/O, and the head does not move. An unknown table, a copy with no head yet and a closed
copy raise.
"""
function table(copy::LocalCopy, name)
    check_open(copy)
    n = view_name("table", name)
    h = copy.head
    h === nothing && throw(ArgumentError("the local copy at $(copy.path) has no head yet; sync!(copy) binds it"))
    haskey(copy.views, n) && return copy.views[n]::TableView
    t = view_table(copy, "table", name, n)
    return copy.views[n] = TableView(n, h, t)
end

function view_name(call, name)
    name isa Union{Symbol,AbstractString} || throw(ArgumentError("$call(copy, $(repr(name))): table name $(repr(name)) is not a Symbol"))
    return String(name)
end
function view_table(copy::LocalCopy, call, name, n)
    try
        return load_table!(copy, n)
    catch e
        e isa ModelError || rethrow()
        throw(ArgumentError("$call(copy, $(repr(name))): $(e.msg)"))
    end
end

"""
    shape(copy, :t) -> (; columns, key)
    shape(v::TableView) -> (; columns, key)

The declaration of table `t` as the write builder built it (ADR-0024, ADR-0025): equal to
what `create_table!` plus every `add_column!` and `drop_column!` since carried.
`columns` is a vector of `(; name, type, nullable)` in declaration order — `name` a
`Symbol`, `type` the type tag `column!` takes (`Int64`, `Float64`, `String`,
`Vector{UInt8}`) — and `key` the primary key's column names in key declaration order.
Reads the table (its shape is in its file), so the table is loaded if it is not yet.
"""
function shape(copy::LocalCopy, name)
    check_open(copy)
    n = view_name("shape", name)
    return public_shape(view_table(copy, "shape", name, n).shape)
end
shape(v::TableView) = public_shape(v.shape)

public_shape(s::Shape) = (; columns = [(; name = Symbol(c.name), type = Model.julia_type(c.type), nullable = c.nullable) for c in s.columns],
                          key = Symbol[Symbol(k) for k in s.key])
