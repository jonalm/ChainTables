# Shared by the attachment tests: chains over an `InMemoryObjectStore`, a synced local
# copy, and the exception a call throws.
using ChainTables: ChainTables, Chain
using ChainTables.Testing: InMemoryObjectStore

"""
    thrown(f)

The exception `f()` throws, or `nothing` when it returns.
"""
function thrown(f)
    try
        f()
    catch e
        e isa Exception || rethrow()
        return e
    end
    return nothing
end

"""
    memory_chain(dir, store; prefix = "p")

A chain at `bkt/<prefix>` over `store`, its record and attachment caches in `dir`.
"""
function memory_chain(dir, store; prefix = "p")
    cache_dir = joinpath(dir, "cache")
    return Chain("bkt", prefix; store, cache_dir, record_host = false, record_user = false)
end

"""
    synced_copy(chain, path)

A local copy of `chain` at `path`, synced to the chain's head.
"""
function synced_copy(chain, path)
    copy = ChainTables.open(chain, path)
    ChainTables.sync!(copy)
    return copy
end

"""
    created_chain(dir; prefix = "p")

A new chain over a new `InMemoryObjectStore`, and a synced local copy of it at
`dir/one`: `(; store, chain, copy)`.
"""
function created_chain(dir; prefix = "p")
    store = InMemoryObjectStore()
    chain = memory_chain(dir, store; prefix)
    ChainTables.create_chain(chain)
    return (; store, chain, copy = synced_copy(chain, joinpath(dir, "one")))
end

"""
    count_calls(store, verb)

How many requests `store` logged for `verb`.
"""
count_calls(store, verb) = count(call -> first(call) === verb, store.calls)

"""
    rewrite_read_only(path, bytes)

Replace the bytes of the read-only file at `path`, keeping it read-only.
"""
function rewrite_read_only(path, bytes)
    chmod(path, 0o644)
    write(path, bytes)
    chmod(path, 0o444)
    return nothing
end

"""
    remove_read_only(path)

Remove the read-only file at `path`.
"""
function remove_read_only(path)
    chmod(path, 0o644)
    rm(path)
    return nothing
end
