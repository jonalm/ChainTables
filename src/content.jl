"""
    Content

Every table of a local copy, by name: a `Dict{String,Table}`. `add_table!`,
`remove_table!` and `content_table` enforce the name rules on top of it.
"""
const Content = Dict{String, Table}

const NOT_TABLE_NAME = "is not an identifier ([a-z_][a-z0-9_]*)"

"""
    add_table!(content, name, shape) -> Table

Add an empty table under `name`, an identifier not yet in use, and return it. Throws
`ModelError`.
"""
function add_table!(c::Content, name::AbstractString, s::Shape)
    is_identifier(name) || throw(
        ModelError(; detail = "table name $(repr(name)) $NOT_TABLE_NAME")
    )
    haskey(c, name) && throw(ModelError(; detail = "table $(repr(name)) already exists"))
    return c[name] = Table(s)
end

"""
    remove_table!(content, name) -> nothing

Remove the table under `name`. Throws `ModelError` when there is none.
"""
function remove_table!(c::Content, name::AbstractString)
    haskey(c, name) || throw(ModelError(; detail = "unknown table $(repr(name))"))
    delete!(c, name)
    return nothing
end

"""
    content_table(content, name) -> Table

Return the table under `name`. Throws `ModelError` when there is none.
"""
function content_table(c::Content, name::AbstractString)
    haskey(c, name) || throw(ModelError(; detail = "unknown table $(repr(name))"))
    return c[name]
end
