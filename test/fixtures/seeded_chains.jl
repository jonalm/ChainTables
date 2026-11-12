# Chains over an `InMemoryObjectStore` in a temporary directory, local copies of them,
# and the commits that seed them. Include after fixtures/chains.jl (`SAMPLE_ROWS`).
using ChainTables: ChainTables, Chain, column!, commit!, create_chain, create_table!,
    insert_rows!, primary_key!, sync!, update_rows!, write_builder
using ChainTables.Testing: InMemoryObjectStore

"""
    chain_over(store, cache_dir, prefix = "p"; kw...)

The chain `bkt`/`prefix` over `store`, recording no host or user, so records do not
depend on the machine.
"""
function chain_over(store, cache_dir, prefix = "p"; kw...)
    return Chain(
        "bkt", prefix; store, cache_dir, record_host = false, record_user = false, kw...
    )
end

"""
    with_chain(f; prefix = "p", kw...)

Call `f(dir, store, chain)` with a temporary directory, a fresh `InMemoryObjectStore` and
`chain_over` it (`kw` passed on), its cache in `dir`. Removes `dir` after.
"""
function with_chain(f; prefix = "p", kw...)
    mktempdir() do dir
        store = InMemoryObjectStore()
        f(dir, store, chain_over(store, joinpath(dir, "cache"), prefix; kw...))
    end
    return nothing
end

"""
    with_copy(f, chain, path)

Call `f(copy)` with the local copy of `chain` opened at `path`, closed after.
"""
function with_copy(f, chain, path)
    copy = ChainTables.open(chain, path)
    try
        f(copy)
    finally
        close(copy)
    end
    return nothing
end

"""
    with_seeded(f, seed!; kw...)

Call `f(dir, store, chain, copy, seeded)` for a created chain (`with_chain`, `kw` passed
on) and a synced copy at `dir/one`, after `seeded = seed!(copy)`.
"""
function with_seeded(f, seed!; kw...)
    with_chain(; kw...) do dir, store, chain
        create_chain(chain)
        with_copy(chain, joinpath(dir, "one")) do copy
            sync!(copy)
            f(dir, store, chain, copy, seed!(copy))
        end
    end
    return nothing
end

function declare_samples!(w)
    create_table!(w, :samples) do t
        column!(t, :id, Int64)
        column!(t, :label, String)
        column!(t, :mass, Float64; nullable = true)
        primary_key!(t, :id)
    end
    return nothing
end

"""
    commit_samples!(copy)

Commit the `samples` table holding `SAMPLE_ROWS`; return the commit's result.
"""
function commit_samples!(copy)
    w = write_builder(copy)
    declare_samples!(w)
    insert_rows!(w, :samples, SAMPLE_ROWS)
    return commit!(w; comment = "first samples")
end

"""
    commit_three!(copy)

Commit samples at slot 1; tags and its twin, sharing one table file, at slot 2; an update
of samples at slot 3. Return the three commits' results.
"""
function commit_three!(copy)
    r1 = commit_samples!(copy)
    w = write_builder(copy)
    foreach(name -> create_keyed!(w, name), (:tags, :twin))
    r2 = commit!(w)
    w = write_builder(copy)
    update_rows!(w, :samples, [(id = 2, mass = 2.5)])
    return [r1, r2, commit!(w)]
end

function create_keyed!(w, name)
    create_table!(w, name) do t
        column!(t, :k, Int64)
        primary_key!(t, :k)
    end
    insert_rows!(w, name, [(k = 1,), (k = 2,)])
    return nothing
end
