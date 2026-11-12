# Docstring over 8 lines: the public type holds the model's lazy-load and cache rules.
# style: inferred LocalCopy is built only by open, whose inference test covers it
"""
    LocalCopy

One open local copy bound to a chain: the directory `path` with `heads/`, `tables/` and,
when pinned, `pin`. Taken with `open` or `as_of`; advanced by `sync!` and `commit!`.

Tables load whole on first touch and stay resident until `close`. A table file is at
most 1 GB on disk, so a resident table stays within a few GB. One process and one thread
use a local copy; nothing is locked. `close` drops the model, after which every call
throws; a temporary copy from `as_of` without a path has its directory deleted.

Examples: test/test_local_copy_examples.jl
"""
mutable struct LocalCopy{C}
    chain::C
    path::String
    head::Union{Nothing, Head} # nothing while the copy is fresh and unbound
    tables::Dict{String, Vector{UInt8}} # the head's name => table hash
    content::Content # tables read from their file or created since the head
    loaded::Set{String} # names read from a file; one no longer in content was dropped
    views::Dict{String, TableView} # one view per table at the current head (ADR-0024)
    temporary::Bool # `close` deletes the directory
    closed::Bool
end

const HEAD_NAME = r"\A[0-9]{12}\z"
const TABLE_NAME = r"\A[0-9a-f]{64}\z"

# Docstring over 8 lines: open has four refusals and a sweep to state.
"""
    open(chain, path) -> LocalCopy

Open the local copy at `path` for `chain`. No network I/O, no replay, nothing hashed.

An absent or empty directory becomes a fresh, unbound copy. Otherwise the highest head
that is self-consistent and whose table files all exist is chosen, else the next lower
one, silently. Throws `NotALocalCopyError`, `LocalCopyInconsistentError`,
`WrongChainError` or `LayoutVersionError`. Then every other head, every table file the
head does not name, and every `.tmp` are deleted. `Base.open` is not extended: call it
qualified, `ChainTables.open`.

Examples: test/test_local_copy_examples.jl
"""
function open(chain, path::AbstractString)
    dir = abspath(path)
    make_or_check_layout(dir)
    copy = LocalCopy{typeof(chain)}(
        chain, dir, nothing, Dict{String, Vector{UInt8}}(), Content(), Set{String}(),
        Dict{String, TableView}(), false, false
    )
    copy.head = choose_head(copy, expected_chain_id(chain))
    copy.tables = head_tables(copy.head)
    sweep!(copy)
    return copy
end

"""
    head(copy) -> (; slot, transaction_hash, state_fingerprint)

Return the head `copy` is at: its slot, its `TransactionHash` and its
`StateFingerprint`. A fresh copy has no head: `sync!(copy)` binds it.

Examples: test/test_local_copy_examples.jl
"""
function head(copy::LocalCopy)
    check_open(copy)
    h = copy.head
    h === nothing && throw(ArgumentError(no_head_message(copy)))
    return (;
        slot = h.slot, transaction_hash = TransactionHash(h.transaction_hash),
        state_fingerprint = StateFingerprint(h.state_fingerprint),
    )
end

"""
    tables(copy) -> Vector{String}

Return the sorted names of every table in `copy` as it stands: the head's tables, less
those dropped since, plus those created since.

Examples: test/test_local_copy_examples.jl
"""
function tables(copy::LocalCopy)
    check_open(copy)
    unread = [name for name in keys(copy.tables) if !(name in copy.loaded)]
    return sort!(collect(union(keys(copy.content), unread)))
end

"""
    is_pinned(copy) -> Bool

Return whether `copy` is a pinned copy: `as_of` pins it, `unpin!` makes it live again,
and `sync!` and `commit!` refuse it while pinned.

Examples: test/test_local_copy_examples.jl
"""
is_pinned(copy::LocalCopy) = isfile(pin_path(copy))

"""
    pin!(copy)

Pin `copy`, so that `sync!` and `commit!` refuse it until `unpin!`.

Examples: test/test_local_copy_examples.jl
"""
function pin!(copy::LocalCopy)
    touch(pin_path(copy))
    return nothing
end

"""
    unpin!(copy)

Make a pinned copy live again: the next `sync!` advances it. Replaying onward from a
pinned slot yields what a replay from slot 0 would. A copy that is not pinned throws
`ArgumentError`. A temporary copy stays temporary.

Examples: test/test_local_copy_examples.jl
"""
function unpin!(copy::LocalCopy)
    check_open(copy)
    is_pinned(copy) || throw(
        ArgumentError(
            "unpin!(copy): the local copy at $(copy.path) is not pinned; it is live already"
        )
    )
    rm(pin_path(copy))
    return nothing
end

"""
    close(copy)

Drop the model and the cached views; every later call on `copy` throws. A view already
taken stays as it was. A temporary copy has its directory deleted. Closing twice does
nothing.
"""
function Base.close(copy::LocalCopy)
    copy.closed && return nothing
    copy.closed = true
    empty!(copy.content)
    empty!(copy.loaded)
    empty!(copy.views)
    copy.temporary && rm(copy.path; recursive = true, force = true)
    return nothing
end

"""
    expected_chain_id(chain) -> Union{Nothing,String}

The chain id `open(chain, path)` checks a bound copy's head against, as base32 text, or
`nothing` when `chain` does not know its id; then the first `sync!` checks the binding.
"""
expected_chain_id(chain) = nothing

function make_or_check_layout(dir::AbstractString)
    is_non_directory(dir) &&
        throw(NotALocalCopyError(; path = dir, detail = "it exists and is not a directory"))
    is_empty_dir(dir) && return make_layout(dir)
    isdir(joinpath(dir, "heads")) && isdir(joinpath(dir, "tables")) || throw(
        NotALocalCopyError(;
            path = dir, detail = "a non-empty directory without heads/ and tables/"
        )
    )
    return nothing
end

is_non_directory(path) = ispath(path) && !isdir(path)
is_empty_dir(path) = !isdir(path) || isempty(readdir(path))

function make_layout(dir::AbstractString)
    mkpath(joinpath(dir, "heads"))
    mkpath(joinpath(dir, "tables"))
    return nothing
end

heads_dir(copy::LocalCopy) = joinpath(copy.path, "heads")
tables_dir(copy::LocalCopy) = joinpath(copy.path, "tables")
pin_path(copy::LocalCopy) = joinpath(copy.path, "pin")
head_path(copy::LocalCopy, slot) = joinpath(heads_dir(copy), head_filename(slot))
function table_path(copy::LocalCopy, hash::AbstractVector{UInt8})
    return joinpath(tables_dir(copy), bytes2hex(hash))
end

head_tables(::Nothing) = Dict{String, Vector{UInt8}}()
head_tables(h::Head) = Dict(h.tables)

"""
    choose_head(copy, expected) -> Union{Nothing,Head}

The head at open: the candidates in descending slot order. A foreign file, a newer
layout and a foreign chain throw at once; damage and a missing table file fall through
to the next lower head; no usable head throws `LocalCopyInconsistentError`.
"""
function choose_head(copy::LocalCopy, expected)
    names = sort!(filter(contains(HEAD_NAME), readdir(heads_dir(copy))); rev = true)
    isempty(names) && return nothing
    reasons = String[]
    for name in names
        found = usable_head(copy, name, expected)
        found isa Head && return found
        push!(reasons, found)
    end
    throw(
        LocalCopyInconsistentError(;
            path = copy.path, file = "heads/$(first(names))", detail = join(reasons, "; ")
        )
    )
end

# The head named `name`, or the reason it cannot be used.
function usable_head(copy::LocalCopy, name::AbstractString, expected)
    file = "heads/$name"
    h = read_head_file(copy, file)
    h isa Head || return h
    slot = parse(Int64, name)
    h.slot == slot || return "head $file is named for slot $slot but says slot $(h.slot)"
    check_bound_chain(copy, h, expected)
    i = findfirst(p -> !isfile(table_path(copy, last(p))), h.tables)
    i === nothing || return missing_table_reason(file, h.tables[i])
    return h
end

function read_head_file(copy::LocalCopy, file::AbstractString)
    try
        return decode_head(read(joinpath(copy.path, file)))
    catch e
        e isa HeadRejected || rethrow()
        detail = "head $file $(e.detail)"
        e.kind === :not_ours && throw(NotALocalCopyError(; path = copy.path, detail))
        e.kind === :layout &&
            throw(LayoutVersionError(; path = copy.path, file, detail = e.detail))
        return detail
    end
end

function check_bound_chain(copy::LocalCopy, h::Head, expected)
    (expected === nothing || h.chain_id == expected) && return nothing
    throw(
        WrongChainError(;
            path = copy.path, bound = h.chain_id, h.slot, opened = String(expected)
        )
    )
end

function missing_table_reason(file, (name, hash))
    return "head $file names table file tables/$(bytes2hex(hash)) " *
        "(table $(repr(name))), which is missing"
end

"""
    sweep!(copy)

Delete every head but the copy's, every table file its head does not name, and every
`.tmp` in `heads/` and `tables/`. Everything deleted is derived. Runs at open, after the
head is chosen, and after every head write.
"""
function sweep!(copy::LocalCopy)
    keep = copy.head === nothing ? nothing : head_filename(copy.head.slot)
    remove_files(f -> is_stale_head(f, keep), heads_dir(copy))
    named = Set(bytes2hex(h) for h in values(copy.tables))
    remove_files(f -> is_stale_table(f, named), tables_dir(copy))
    return nothing
end

is_stale_head(f, keep) = endswith(f, ".tmp") || (contains(f, HEAD_NAME) && f != keep)
is_stale_table(f, named) = endswith(f, ".tmp") || (contains(f, TABLE_NAME) && !(f in named))

function remove_files(is_stale, dir::AbstractString)
    foreach(f -> rm(joinpath(dir, f); force = true), filter(is_stale, readdir(dir)))
    return nothing
end

function check_open(copy::LocalCopy)
    copy.closed && throw(
        ArgumentError("the local copy at $(copy.path) is closed; open(chain, path) again")
    )
    return nothing
end

function no_head_message(copy::LocalCopy)
    return "the local copy at $(copy.path) has no head yet; sync!(copy) binds it"
end
