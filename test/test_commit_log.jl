using Test
using ChainTables: ChainTables, Chain, RewrittenChainError, as_of, commit!, commit_log,
    create_chain, insert_rows!, sync!, write_builder
using ChainTables.Testing: InMemoryObjectStore

include("fixtures/chain_copies.jl")
include("fixtures/object_stores.jl")

const REPLACED = (:debug, "the record cache held other bytes than the store")
const DEBUG = Base.CoreLogging.Debug

# A chain whose records carry their author and host, and a local copy at slot 2:
# `alice` declares `samples` with the comment "make samples", `bob` inserts a row.
# Returns the result of `bob`'s commit too.
function with_authored_copy(f)
    mktempdir() do dir
        store = InMemoryObjectStore()
        chain = Chain("bkt", "p"; store, cache_dir = joinpath(dir, "cache"))
        withenv("USER" => "alice") do
            create_chain(chain)
        end
        with_copy(chain, joinpath(dir, "copy")) do local_copy
            sync!(local_copy)
            withenv(() -> commit_declaration!(local_copy), "USER" => "alice")
            second = withenv(() -> commit_sample!(local_copy, 3), "USER" => "bob")
            f(local_copy, second)
        end
    end
    return nothing
end

function commit_declaration!(local_copy)
    w = write_builder(local_copy)
    declare_samples!(w)
    return commit!(w; comment = "make samples")
end

@testset "commit_log lists the records newest first, down to the genesis record" begin
    with_authored_copy() do local_copy, second
        entries = @inferred commit_log(local_copy)
        @test [entry.slot for entry in entries] == [2, 1, 0]
        @test [entry.author for entry in entries] == ["bob", "alice", "alice"]
        @test [entry.comment for entry in entries] == [nothing, "make samples", nothing]
        @test entries[1].transaction_hash == second.transaction_hash
        @test [entry.host for entry in entries] == fill(gethostname(), 3)
        @test issorted([entry.time_ms for entry in entries]; rev = true)
    end
end

@testset "commit_log leaves out the author and host that a record does not carry" begin
    with_samples_copy() do local_copy
        entry = first(commit_log(local_copy))
        @test (entry.author, entry.host) == (nothing, nothing)
    end
end

@testset "commit_log returns the last newest records" begin
    with_authored_copy() do local_copy, _
        entries = commit_log(local_copy)
        @test commit_log(local_copy; last = 2) == entries[1:2]
        @test commit_log(local_copy; last = 99) == entries
    end
end

@testset "commit_log throws ArgumentError for a last below 1" begin
    with_samples_copy() do local_copy
        @test_throws ArgumentError "last is at least 1, got 0" commit_log(
            local_copy; last = 0
        )
    end
end

@testset "commit_log throws ArgumentError for a last that is not an Integer" begin
    with_samples_copy() do local_copy
        @test_throws ArgumentError "last is an Integer or nothing, got 1.5" commit_log(
            local_copy; last = 1.5
        )
    end
end

@testset "commit_log reads a warm record cache with no request" begin
    with_authored_copy() do local_copy, _
        store = local_copy.chain.store
        n = length(store.calls)
        commit_log(local_copy)
        @test length(store.calls) == n
    end
end

@testset "commit_log ends at the head of the local copy, not the chain's" begin
    with_authored_copy() do local_copy, _
        with_copy_beside(local_copy, "two") do second
            sync!(second)
            w = write_builder(second)
            insert_rows!(w, :samples, [(id = 4, label = "d", mass = 4.0)])
            commit!(w; comment = "from two")
            @test first(commit_log(local_copy)).slot == 2
            sync!(local_copy)
            @test first(commit_log(local_copy)).comment == "from two"
        end
    end
end

@testset "commit_log of a pinned copy ends at its slot" begin
    with_authored_copy() do local_copy, _
        pinned = as_of(local_copy.chain, 1)
        @test [entry.slot for entry in commit_log(pinned)] == [1, 0]
        close(pinned)
    end
end

@testset "commit_log fetches a record that the record cache lacks" begin
    with_authored_copy() do local_copy, _
        chain = local_copy.chain
        expected = commit_log(local_copy)
        rm(record_file(chain, 1))
        n = length(chain.store.calls)
        @test commit_log(local_copy) == expected
        @test chain.store.calls[(n + 1):end] == [(:fetch_object, slot_key(1))]
        @test isfile(record_file(chain, 1))
    end
end

@testset "commit_log replaces a cached record with other bytes" begin
    with_authored_copy() do local_copy, _
        chain = local_copy.chain
        expected = commit_log(local_copy)
        write(record_file(chain, 1), UInt8[0x00])
        @test (@test_logs REPLACED min_level = DEBUG commit_log(local_copy)) == expected
        @test read(record_file(chain, 1)) == chain.store.objects[slot_key(1)]
    end
end

@testset "commit_log throws RewrittenChainError when the store has other bytes" begin
    with_authored_copy() do local_copy, _
        chain = local_copy.chain
        named = stored_hash(chain.store, 1)
        plant!(chain.store, slot_key(1), UInt8[0x00])
        write(record_file(chain, 1), UInt8[0x00])
        above = "the store does not hold the record that the slot above names"
        err = @test_throws RewrittenChainError above commit_log(local_copy)
        e = err.value
        @test (e.path, e.slot, e.expected) == (local_copy.path, 1, named)
        # The cached file stays as it was.
        @test read(record_file(chain, 1)) == UInt8[0x00]
    end
end

@testset "commit_log throws ArgumentError for a copy with no head" begin
    with_chain_copy() do local_copy
        with_copy_beside(local_copy, "fresh") do fresh
            @test_throws ArgumentError "has no head yet" commit_log(fresh)
        end
    end
end

@testset "commit_log throws ArgumentError for a closed copy" begin
    with_samples_copy() do local_copy
        close(local_copy)
        @test_throws ArgumentError "is closed" commit_log(local_copy)
    end
end
