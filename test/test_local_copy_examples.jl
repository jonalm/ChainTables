using Test
using ChainTables: ChainTables, Chain, LocalCopy, column!, commit!, create_chain,
    create_table!, head, insert_rows!, is_pinned, pin!, primary_key!, sync!, tables, unpin!,
    write_builder
using ChainTables.Testing: InMemoryObjectStore

# A new chain in an in-memory store, and a directory for local copies.
function with_new_chain(f)
    return mktempdir() do dir
        store = InMemoryObjectStore()
        chain = Chain("bkt", "p"; store, cache_dir = joinpath(dir, "cache"))
        create_chain(chain)
        f(chain, dir)
    end
end

@testset "LocalCopy example" begin
    with_new_chain() do chain, dir
        # A local copy is the directory a client builds by replaying the chain.
        copy = ChainTables.open(chain, joinpath(dir, "copy"))
        @test copy isa LocalCopy
        close(copy)
    end
end

@testset "open example" begin
    with_new_chain() do chain, dir
        # `open` is qualified: it is not `Base.open`. A new path gives a fresh copy.
        copy = ChainTables.open(chain, joinpath(dir, "copy"))
        # Nothing is read from the chain until a sync.
        sync!(copy)
        @test head(copy).slot == 0
        close(copy)
    end
end

@testset "head example" begin
    with_new_chain() do chain, dir
        copy = ChainTables.open(chain, joinpath(dir, "copy"))
        sync!(copy)
        w = write_builder(copy)
        create_table!(w, :samples) do t
            column!(t, :id, Int64)
            primary_key!(t, :id)
        end
        committed = commit!(w)
        # The head is the slot and hashes of the last record the copy applied.
        @test head(copy).slot == 1
        @test head(copy).transaction_hash == committed.transaction_hash
        close(copy)
    end
end

@testset "tables example" begin
    with_new_chain() do chain, dir
        copy = ChainTables.open(chain, joinpath(dir, "copy"))
        sync!(copy)
        w = write_builder(copy)
        create_table!(w, :samples) do t
            column!(t, :id, Int64)
            primary_key!(t, :id)
        end
        insert_rows!(w, :samples, [(id = 1,)])
        commit!(w)
        @test tables(copy) == ["samples"]
        close(copy)
    end
end

@testset "is_pinned example" begin
    with_new_chain() do chain, dir
        copy = ChainTables.open(chain, joinpath(dir, "copy"))
        # A copy is live until it is pinned.
        @test !is_pinned(copy)
        close(copy)
    end
end

@testset "pin! example" begin
    with_new_chain() do chain, dir
        copy = ChainTables.open(chain, joinpath(dir, "copy"))
        sync!(copy)
        # A pinned copy stays at its head: `sync!` and `commit!` refuse it.
        pin!(copy)
        @test is_pinned(copy)
        close(copy)
    end
end

@testset "unpin! example" begin
    with_new_chain() do chain, dir
        copy = ChainTables.open(chain, joinpath(dir, "copy"))
        pin!(copy)
        # Unpinned, the copy is live again and the next `sync!` advances it.
        unpin!(copy)
        @test !is_pinned(copy)
        sync!(copy)
        @test head(copy).slot == 0
        close(copy)
    end
end
