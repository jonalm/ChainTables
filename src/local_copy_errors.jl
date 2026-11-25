"""
    NotALocalCopyError

Thrown when `open` is given a path that is not a local copy: a file, a directory that
is not empty and has no `heads/` and `tables/`, or a head file that ChainTables did not
write.
"""
Base.@kwdef struct NotALocalCopyError <: ChainTablesError
    path::Union{Nothing, String} = nothing
    detail::String = ""
end

function Base.showerror(io::IO, e::NotALocalCopyError)
    print_summary(io, e, "the path is not a local copy.")
    print_evidence(io, e)
    print(io, "Open a different path.")
    return nothing
end

"""
    LayoutVersionError

Thrown when `open` finds a head file written under another layout version or a newer
format version than this client reads.

`file` is the head file, relative to `path`.
"""
Base.@kwdef struct LayoutVersionError <: ChainTablesError
    path::Union{Nothing, String} = nothing
    file::Union{Nothing, String} = nothing
    detail::String = ""
end

function Base.showerror(io::IO, e::LayoutVersionError)
    print_summary(io, e, "another version of ChainTables wrote this local copy.")
    print_evidence(io, e)
    print(io, "Delete the directory and sync a fresh local copy, or upgrade ")
    print(io, "ChainTables.")
    return nothing
end

"""
    WrongChainError

Thrown when the local copy at `path` is bound to the chain `bound`, and the chain being
opened or synced is `opened`.
"""
Base.@kwdef struct WrongChainError <: ChainTablesError
    path::Union{Nothing, String} = nothing
    bound::Union{Nothing, String} = nothing
    opened::Union{Nothing, String} = nothing
    detail::String = ""
end

function Base.showerror(io::IO, e::WrongChainError)
    print_summary(io, e, "the local copy is bound to another chain.")
    print_evidence(io, e)
    print(io, "Open a different path for this chain.")
    return nothing
end

"""
    LocalCopyInconsistentError

Thrown when `open` or the load of a table finds a damaged copy: no head file that
agrees with itself, a table file that is missing, or one whose bytes do not hash to its
name.

`file` is the damaged file relative to `path`, when there is one.
"""
Base.@kwdef struct LocalCopyInconsistentError <: ChainTablesError
    path::Union{Nothing, String} = nothing
    slot::Union{Nothing, Int64} = nothing
    file::Union{Nothing, String} = nothing
    detail::String = ""
end

function Base.showerror(io::IO, e::LocalCopyInconsistentError)
    print_summary(io, e, "the local copy is damaged.")
    print_evidence(io, e)
    print(io, "Run `repair!(copy)`, which rewrites a table file from the record ")
    print(io, "cache. If no head can be opened, delete the directory and sync a ")
    print(io, "fresh local copy.")
    return nothing
end
