# `table` and `shape` name no I/O: the names are the package's API (ADR-0024).
# style: inferred the types of the view's columns come from the table's shape at run time
"""
    table(local_copy, name)

Return the `TableView` of the table `name` at the head of the local copy.

The table is loaded if it is not yet, and its rows are copied out once per head: a
second call before the head moves returns the same view. No network I/O, and the head
does not move. Throws `ArgumentError` for a name that is not a table and for a copy
with no head, and `LocalCopyInconsistentError` for a damaged table file.

Examples: test/test_views_examples.jl
"""
function table(local_copy::LocalCopy, name)
    check_open(local_copy)
    text = table_name_text("table", name)
    head_file = bound_head(local_copy)
    haskey(local_copy.views, text) && return local_copy.views[text]
    loaded = load_named_table!(local_copy, "table", name)
    return local_copy.views[text] = TableView(text, head_file, loaded)
end

"""
    shape(local_copy, name)
    shape(v::TableView)

Return the shape of a table as `(; columns, key)`.

`columns` is a vector of `(; name, type, nullable)` in declaration order, with `name` a
`Symbol` and `type` the type tag that `column!` takes: `Int64`, `Float64`, `String` or
`Vector{UInt8}`. `key` holds the names of the primary key's columns in key declaration
order. The first form loads the table if it is not loaded yet, and throws
`ArgumentError` for a name that is not a table.

Examples: test/test_views_examples.jl
"""
function shape(local_copy::LocalCopy, name)
    check_open(local_copy)
    return declared_shape(load_named_table!(local_copy, "shape", name).shape)
end

shape(v::TableView) = declared_shape(v.shape)

function table_name_text(call, name)
    name isa Union{Symbol, AbstractString} || throw(
        ArgumentError(
            "$call(copy, $(repr(name))): table name $(repr(name)) is not a Symbol"
        )
    )
    return String(name)
end

function load_named_table!(local_copy::LocalCopy, call, name)
    text = table_name_text(call, name)
    loaded = try
        load_table!(local_copy, text)
    catch e
        e isa Model.ModelError || rethrow()
        throw(ArgumentError("$call(copy, $(repr(name))): $(e.detail)"))
    end
    return loaded
end

function declared_shape(s::Model.Shape)
    return (; columns = map(shape_column, s.columns), key = map(Symbol, s.key))
end

function shape_column(c::Model.Column)
    return (; name = Symbol(c.name), type = Model.julia_type(c.type), c.nullable)
end
