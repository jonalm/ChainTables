"""
    Content

The whole model: every table the chain created, by name. A `Dict{String, Table}`.
"""
const Content = Dict{String, Table}

function create_table!(c::Content, name::AbstractString, s::Shape)
    is_identifier(name) || throw(
        ModelError("table name $(repr(name)) is not an identifier ([a-z_][a-z0-9_]*)")
    )
    haskey(c, name) && throw(ModelError("table $(repr(name)) already exists"))
    return c[name] = Table(s)
end

function drop_table!(c::Content, name::AbstractString)
    haskey(c, name) || throw(ModelError("unknown table $(repr(name))"))
    delete!(c, name)
    return nothing
end

function table(c::Content, name::AbstractString)
    haskey(c, name) || throw(ModelError("unknown table $(repr(name))"))
    return c[name]
end
