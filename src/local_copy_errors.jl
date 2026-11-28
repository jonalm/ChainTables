const NOT_A_LOCAL_COPY_NEXT_MOVES = Dict(
    :not_a_directory => "The path is a file. Open a directory path.",
    :no_layout => "The directory is not empty and has no `heads/` and `tables/`. Open " *
        "a different path, or empty this directory if it is disposable.",
    :foreign_head => "ChainTables did not write the head file. Open a different path.",
)

const NOT_A_LOCAL_COPY_NEXT_MOVE = "Open a different path."

"""
    NotALocalCopyError

Thrown when `open` is given a path that is not a local copy.

`reason` is `:not_a_directory` for a file, `:no_layout` for a directory that is not
empty and has no `heads/` and `tables/`, and `:foreign_head` for a head file that
ChainTables did not write. `file` is that head file, relative to `path`.
"""
Base.@kwdef struct NotALocalCopyError <: ChainTablesError
    path::Union{Nothing, String} = nothing
    file::Union{Nothing, String} = nothing
    reason::Union{Nothing, Symbol} = nothing
    detail::String = ""
end

function Base.showerror(io::IO, e::NotALocalCopyError)
    print_summary(io, e, "the path is not a local copy.")
    print_evidence(io, e)
    print(io, get(NOT_A_LOCAL_COPY_NEXT_MOVES, e.reason, NOT_A_LOCAL_COPY_NEXT_MOVE))
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
    bucket::Union{Nothing, String} = nothing
    prefix::Union{Nothing, String} = nothing
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

const REPAIR_TABLE_FILE = "Run `repair!(copy)`, which rewrites the table file from the " *
    "record cache."

const DAMAGED_COPY_NEXT_MOVES = Dict(
    :no_usable_head => "`repair!` needs a head file that can be opened. Delete the " *
        "directory and sync a fresh local copy.",
    :table_file_missing => REPAIR_TABLE_FILE,
    :table_file_hash => REPAIR_TABLE_FILE,
    :table_file_not_canonical => REPAIR_TABLE_FILE,
    :row_slot_above_head => REPAIR_TABLE_FILE,
)

const DAMAGED_COPY_NEXT_MOVE = "Run `repair!(copy)`, which rewrites a table file from " *
    "the record cache. If no head file can be opened, delete the directory and sync a " *
    "fresh local copy."

"""
    LocalCopyInconsistentError

Thrown when `open` or the load of a table finds a damaged copy.

`reason` is `:no_usable_head` when `open` finds no head file that agrees with itself and
whose table files all exist. For a table file it is `:table_file_missing`,
`:table_file_hash` (the bytes do not hash to the file's name),
`:table_file_not_canonical` or `:row_slot_above_head`. `file` is the damaged file
relative to `path`: the table file, or the highest head file. `chain_id` and `slot` are
the head's, when a head was opened.
"""
Base.@kwdef struct LocalCopyInconsistentError <: ChainTablesError
    path::Union{Nothing, String} = nothing
    chain_id::Union{Nothing, String} = nothing
    slot::Union{Nothing, Int64} = nothing
    file::Union{Nothing, String} = nothing
    reason::Union{Nothing, Symbol} = nothing
    detail::String = ""
end

function Base.showerror(io::IO, e::LocalCopyInconsistentError)
    print_summary(io, e, "the local copy is damaged.")
    print_evidence(io, e)
    print(io, get(DAMAGED_COPY_NEXT_MOVES, e.reason, DAMAGED_COPY_NEXT_MOVE))
    return nothing
end
