const TABLE_NAME = r"\A[0-9a-f]{64}\z"

"""
    LocalCopy

One open local copy, bound to a chain: the directory `path` with `heads/`, `tables/`
and, when the copy is pinned, `pin`.

Taken with `open` or `as_of`, and moved by `sync!` and `commit!`. A table is loaded
whole at its first use and stays loaded until `close`. After `close` every call on the
copy throws `ArgumentError`. One process and one thread use a local copy at a time:
nothing is locked.
"""
mutable struct LocalCopy{C}
    chain::C
    path::String
    head::Union{Nothing, Head}  # `nothing` while the copy is fresh and unbound
    tables::Dict{String, Vector{UInt8}}  # the head's tables, name => table_hash
    content::Model.Content  # the tables read from a file or created since the head
    loaded::Set{String}  # read from a file; one no longer in `content` was dropped
    views::Dict{String, TableView}  # one per table at the head, dropped when it moves
    temporary::Bool  # `close` deletes the directory (ADR-0015)
    closed::Bool
end

function LocalCopy(chain, path, head_file)
    return LocalCopy(
        chain, path, head_file, table_hashes(head_file), Model.Content(), Set{String}(),
        Dict{String, TableView}(), false, false,
    )
end

table_hashes(::Nothing) = Dict{String, Vector{UInt8}}()
table_hashes(head_file::Head) = Dict(head_file.tables)

# `open`, `head` and `tables` name no I/O: the names are the package's API (ADR-0019).
"""
    open(chain, path)

Open the local copy at `path` for `chain` and return the `LocalCopy`.

No network I/O, no replay, and nothing is hashed. An absent or empty directory becomes
a fresh copy with no head. With head files present, `open` chooses the highest one that
agrees with itself and whose table files all exist. Then it deletes every other head
file, every table file that the head does not name and every `.tmp` file.

Throws `NotALocalCopyError` for a path that is not a local copy, `LayoutVersionError`
for a copy that another version of ChainTables wrote, `WrongChainError` for a copy
bound to another chain than `chain`, and `LocalCopyInconsistentError` when no head file
can be used.

Examples: test/test_local_copy_examples.jl
"""
function open(chain, path::AbstractString)
    path = abspath(path)
    write_layout(path)
    head_file = read_highest_usable_head(path, expected_chain_id(chain))
    local_copy = LocalCopy(chain, path, head_file)
    sweep_orphans(local_copy)
    # TODO: delete with the warning, when s3.jl is rewritten:
    # https://github.com/jonalm/julia_codestyle/issues/129
    warn_unsupported_store(chain)
    return local_copy
end

"""
    head(local_copy)

Return the head of the local copy as `(; slot, transaction_hash, state_fingerprint)`,
with a `TransactionHash` and a `StateFingerprint`.

Throws `ArgumentError` while the copy is fresh and has no head.

Examples: test/test_local_copy_examples.jl
"""
function head(local_copy::LocalCopy)
    check_open(local_copy)
    head_file = bound_head(local_copy)
    transaction_hash = TransactionHash(head_file.transaction_hash)
    state_fingerprint = StateFingerprint(head_file.state_fingerprint)
    return (; head_file.slot, transaction_hash, state_fingerprint)
end

"""
    tables(local_copy)

Return the sorted names of the tables of the local copy: the head's tables, without
those dropped since and with those created since.

Examples: test/test_local_copy_examples.jl
"""
function tables(local_copy::LocalCopy)
    check_open(local_copy)
    unread = setdiff(keys(local_copy.tables), local_copy.loaded)
    return sort!(collect(union(unread, keys(local_copy.content))))
end

"""
    is_pinned(local_copy)

Return whether the local copy is a pinned copy: whether its `pin` file exists.

`as_of` pins a copy and `unpin!` makes it live. `sync!` and `commit!` refuse a pinned
copy.

Examples: test/test_local_copy_examples.jl
"""
is_pinned(local_copy::LocalCopy) = isfile(pin_path(local_copy))

"""
    ispinned(local_copy)

Deprecated: use `is_pinned`.
"""
function ispinned(local_copy::LocalCopy)
    Base.depwarn("`ispinned(copy)` is deprecated, use `is_pinned(copy)`.", :ispinned)
    return is_pinned(local_copy)
end

# `!` without a changed argument: the name is the package's API (ADR-0015).
"""
    unpin!(local_copy)

Make a pinned copy live: delete its `pin` file, so that the next `sync!` moves the copy.

A temporary copy from `as_of` stays temporary, and `close` still deletes it. Throws
`ArgumentError` for a copy that is not pinned.

Examples: test/test_local_copy_examples.jl
"""
function unpin!(local_copy::LocalCopy)
    check_open(local_copy)
    is_pinned(local_copy) || throw(
        ArgumentError(
            "unpin!(copy): the local copy at $(local_copy.path) is not pinned; it is " *
                "live already"
        )
    )
    rm(pin_path(local_copy))
    return nothing
end

"""
    close(local_copy)

Close the local copy: drop its loaded tables and its table views.

Every later call on the copy throws `ArgumentError`; a view already taken stays as it
was. The directory of a temporary copy is deleted. Closing twice does nothing.
"""
function Base.close(local_copy::LocalCopy)
    local_copy.closed && return nothing
    local_copy.closed = true
    empty!(local_copy.content)
    empty!(local_copy.loaded)
    empty!(local_copy.views)
    local_copy.temporary && rm(local_copy.path; recursive = true, force = true)
    return nothing
end

"""
    expected_chain_id(chain)

Return the chain id, as text, that `open(chain, path)` holds the head of a bound copy
against, or `nothing` when the chain does not know its id yet.

A chain type of your own may add a method. Without one nothing is checked at `open`,
and the first `sync!` checks the binding against the records it fetches.
"""
expected_chain_id(chain) = nothing

function write_layout(path)
    ispath(path) && !isdir(path) &&
        throw(NotALocalCopyError(; path, reason = :not_a_directory))
    is_empty_or_absent(path) && foreach(mkpath, (heads_dir(path), tables_dir(path)))
    isdir(heads_dir(path)) && isdir(tables_dir(path)) ||
        throw(NotALocalCopyError(; path, reason = :no_layout))
    return nothing
end

is_empty_or_absent(path) = !isdir(path) || isempty(readdir(path))

# Candidates in descending slot order (ADR-0023). A file that is not a head file, another
# layout and another chain throw at once. A damaged head and a missing table file fall
# through to the next lower head, and the crash window leaves at most two.
function read_highest_usable_head(path, expected)
    names = sort!(filter(contains(HEAD_NAME), readdir(heads_dir(path))); rev = true)
    faults = String[]
    for name in names
        try
            head_file = read_usable_head(path, name, expected)
            isempty(faults) || @debug "open chose a lower head" path name faults
            return head_file
        catch e
            e isa HeadRejected || rethrow()
            file = "heads/$name"
            e.kind === :not_ours &&
                throw(NotALocalCopyError(; path, file, reason = :foreign_head))
            detail = "the head file $(e.detail)"
            e.kind === :layout && throw(LayoutVersionError(; path, file, detail))
            push!(faults, "$file $(e.detail)")
        end
    end
    isempty(names) && return nothing
    file = "heads/$(first(names))"
    detail = join(faults, "; ")
    throw(LocalCopyInconsistentError(; path, file, reason = :no_usable_head, detail))
end

function read_usable_head(path, name, expected)
    head_file = decode_head(read(joinpath(heads_dir(path), name)))
    slot = parse(Int64, name)
    head_file.slot == slot || throw(
        HeadRejected(:damaged, "is named for slot $slot but says slot $(head_file.slot)")
    )
    expected === nothing || head_file.chain_id == expected || throw(
        WrongChainError(;
            path, bound = head_file.chain_id, opened = String(expected),
            detail = "the head is at slot $slot",
        )
    )
    absent = findfirst(entry -> !isfile(table_path(path, last(entry))), head_file.tables)
    absent === nothing ||
        throw(HeadRejected(:damaged, names_missing_file(head_file.tables[absent])))
    return head_file
end

function names_missing_file(entry)
    name, hash = entry
    return "names table file tables/$(bytes2hex(hash)) (table $(repr(name))), which " *
        "is missing"
end

# Deletes every head file but the copy's, every table file that its head does not name,
# and every `.tmp`. Everything deleted is derived (ADR-0023).
function sweep_orphans(local_copy::LocalCopy)
    path = local_copy.path
    kept_tables = map(bytes2hex, collect(values(local_copy.tables)))
    orphans = vcat(
        read_orphans(heads_dir(path), HEAD_NAME, kept_head_names(local_copy.head)),
        read_orphans(tables_dir(path), TABLE_NAME, kept_tables),
    )
    foreach(file -> rm(file; force = true), orphans)
    return nothing
end

kept_head_names(::Nothing) = String[]
kept_head_names(head_file::Head) = [head_filename(head_file.slot)]

function read_orphans(dir, pattern, kept)
    return [joinpath(dir, file) for file in readdir(dir) if is_orphan(file, pattern, kept)]
end

function is_orphan(file, pattern, kept)
    return endswith(file, ".tmp") || (occursin(pattern, file) && file ∉ kept)
end

function check_open(local_copy::LocalCopy)
    local_copy.closed && throw(
        ArgumentError(
            "the local copy at $(local_copy.path) is closed; open(chain, path) again"
        )
    )
    return nothing
end

function bound_head(local_copy::LocalCopy)
    head_file = local_copy.head
    head_file === nothing && throw(
        ArgumentError(
            "the local copy at $(local_copy.path) has no head yet; sync!(copy) binds it"
        )
    )
    return head_file
end

heads_dir(path::AbstractString) = joinpath(path, "heads")
tables_dir(path::AbstractString) = joinpath(path, "tables")
tables_dir(local_copy::LocalCopy) = tables_dir(local_copy.path)
function head_path(local_copy::LocalCopy, slot)
    return joinpath(heads_dir(local_copy.path), head_filename(slot))
end


table_path(path::AbstractString, hash) = joinpath(tables_dir(path), bytes2hex(hash))
table_path(local_copy::LocalCopy, hash) = table_path(local_copy.path, hash)
pin_path(local_copy::LocalCopy) = joinpath(local_copy.path, "pin")

write_pin(local_copy::LocalCopy) = touch(pin_path(local_copy))
