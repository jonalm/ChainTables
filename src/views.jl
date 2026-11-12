# style: inferred the view's column types are read from the table file at run time
"""
    table(copy, :t) -> TableView

Return the `TableView` of table `t` as of `copy`'s head now.

The view is taken once per table per head: a second `table(copy, :t)` before the head
moves returns the same view. No network I/O, and the head does not move. An unknown
table, a fresh copy and a closed copy throw `ArgumentError`.

Examples: test/test_views_examples.jl
"""
function table(copy::LocalCopy, name)
    check_open(copy)
    n = view_name("table", name)
    h = copy.head
    h === nothing && throw(ArgumentError(no_head_message(copy)))
    haskey(copy.views, n) && return copy.views[n]
    return copy.views[n] = TableView(n, h, view_table(copy, "table", name, n))
end

"""
    shape(copy, :t) -> (; columns, key)
    shape(v::TableView) -> (; columns, key)

Return the declaration of table `t`: what `create_table!` and every `add_column!` and
`drop_column!` since carried.

`columns` holds a `(; name, type, nullable)` per column in declaration order, `name` a
`Symbol` and `type` a type tag of `column!`; `key` holds the primary key's column names
in key declaration order. The first form loads the table if it is not loaded yet.

Examples: test/test_views_examples.jl
"""
function shape(copy::LocalCopy, name)
    check_open(copy)
    n = view_name("shape", name)
    return public_shape(view_table(copy, "shape", name, n).shape)
end

shape(v::TableView) = public_shape(v.shape)

function view_name(call, name)
    name isa Union{Symbol, AbstractString} || throw(
        ArgumentError(
            "$call(copy, $(repr(name))): table name $(repr(name)) is not a Symbol"
        )
    )
    return String(name)
end

function view_table(copy::LocalCopy, call, name, n)
    try
        return load_table!(copy, n)
    catch e
        e isa ModelError || rethrow()
        throw(ArgumentError("$call(copy, $(repr(name))): $(e.detail)"))
    end
end

function public_shape(s::Shape)
    return (; columns = map(public_column, s.columns), key = Symbol.(s.key))
end

# Every type tag is a DataType; the assert keeps the column vector concrete.
function public_column(c::Column)
    return (; name = Symbol(c.name), type = julia_type(c.type)::DataType, c.nullable)
end
