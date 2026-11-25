using ChainTables: ChainTables, Chain, column!, commit!, create_chain, create_table!,
    insert_rows!, primary_key!, sync!, write_builder
using ChainTables.Testing: InMemoryObjectStore

# A chain on an in-memory object store, with its genesis record, and a synced local
# copy of it. `local_copy.chain` is the chain and `local_copy.chain.store` the store.
function with_chain_copy(f)
    mktempdir() do dir
        chain = Chain(
            "bkt", "p";
            store = InMemoryObjectStore(), cache_dir = joinpath(dir, "cache"),
            record_host = false, record_user = false,
        )
        create_chain(chain)
        local_copy = ChainTables.open(chain, joinpath(dir, "copy"))
        try
            sync!(local_copy)
            f(local_copy)
        finally
            close(local_copy)
        end
    end
    return nothing
end

# One transaction record: `build` adds the ops to a write builder.
function commit_ops!(build, local_copy)
    w = write_builder(local_copy)
    build(w)
    return commit!(w)
end

function declare_samples!(w, name = :samples)
    return create_table!(w, name) do t
        column!(t, :id, Int64)
        column!(t, :label, String)
        column!(t, :mass, Float64; nullable = true)
        primary_key!(t, :id)
    end
end

const SAMPLE_ROWS = [
    (id = 2, label = "b", mass = missing), (id = 1, label = "a", mass = 1.5),
]

function seed_samples!(w)
    declare_samples!(w)
    insert_rows!(w, :samples, SAMPLE_ROWS)
    return nothing
end

# A local copy at slot 1, with the table `samples` and its two rows.
function with_samples_copy(f)
    with_chain_copy() do local_copy
        commit_ops!(seed_samples!, local_copy)
        f(local_copy)
    end
    return nothing
end

# A write builder over the local copy of `with_samples_copy`.
with_samples_builder(f) = with_samples_copy(local_copy -> f(write_builder(local_copy)))

# A write builder over a local copy with no table.
with_empty_builder(f) = with_chain_copy(local_copy -> f(write_builder(local_copy)))

function seed_three_tables!(w)
    seed_samples!(w)
    create_table!(w, :pairs) do t
        column!(t, :n, Float64)
        column!(t, :a, Int64)
        column!(t, :b, String)
        primary_key!(t, :a, :b)
    end
    pairs = [
        (a = 2, b = "y", n = 0.5), (a = 1, b = "x", n = 0.25), (a = 1, b = "w", n = 0.0),
    ]
    insert_rows!(w, :pairs, pairs)
    create_table!(w, :blobs) do t
        column!(t, :k, Vector{UInt8})
        column!(t, :v, Vector{UInt8}; nullable = true)
        primary_key!(t, :k)
    end
    insert_rows!(w, :blobs, [(k = UInt8[1, 2], v = UInt8[9]), (k = UInt8[1], v = missing)])
    return nothing
end

# A local copy at slot 1 with three tables: `samples`, keyed by `id`; `pairs`, keyed by
# `(a, b)`; and `blobs`, with a bytes key and a nullable bytes column.
function with_tables_copy(f)
    with_chain_copy() do local_copy
        commit_ops!(seed_three_tables!, local_copy)
        f(local_copy)
    end
    return nothing
end
