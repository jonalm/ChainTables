using Test
using ChainTables: ChainTables, Chain, RewrittenChainError, as_of, commit!, commit_log,
    create_chain, create_table!, column!, insert_rows!, primary_key!, sync!, write_builder
using ChainTables.Testing: InMemoryObjectStore

include("fixtures/chains.jl")
include("fixtures/seeded_chains.jl")

const CT = ChainTables

function insert_id!(copy, id; comment = nothing)
    w = write_builder(copy)
    insert_rows!(w, :t, [(; id)])
    return commit!(w; comment)
end

function create_chain_with_t!(chain, copy)
    create_chain(chain)
    sync!(copy)
    w = write_builder(copy)
    create_table!(w, :t) do t
        column!(t, :id, Int64)
        primary_key!(t, :id)
    end
    return commit!(w; comment = "make t")
end

# Alice creates the chain and table t; Bob inserts a row: slots 0, 1 and 2.
function with_logged(f)
    mktempdir() do dir
        store = InMemoryObjectStore()
        chain = Chain("bkt", "p"; store, cache_dir = joinpath(dir, "cache"))
        with_copy(chain, joinpath(dir, "one")) do copy
            withenv(() -> create_chain_with_t!(chain, copy), "USER" => "alice")
            r2 = withenv(() -> insert_id!(copy, 1), "USER" => "bob")
            f(dir, store, chain, copy, r2)
        end
    end
    return nothing
end

plant!(store, key, bytes) = (store.objects[key] = bytes; nothing)

cached(chain, s) = CT.record_path(chain, slotkey(s))

@testset "commit_log reads the copy's records newest first, genesis included" begin
    with_logged() do dir, store, chain, copy, r2
        log = commit_log(copy)
        @test [e.slot for e in log] == [2, 1, 0]
        @test [e.author for e in log] == ["bob", "alice", "alice"]
        @test [e.comment for e in log] == [nothing, "make t", nothing]
        @test log[1].transaction_hash == r2.transaction_hash
        @test [e.host for e in log] == fill(gethostname(), 3)
        @test issorted([e.time_ms for e in log]; rev = true) && log[end].time_ms > 0
    end
end

@testset "commit_log with last returns the newest records only" begin
    with_logged() do dir, store, chain, copy, r2
        log = commit_log(copy)
        @test commit_log(copy; last = 2) == log[1:2]
        @test commit_log(copy; last = 99) == log
    end
end

const BAD_LASTS = [(last = 0,), (last = 1.5,)]

@testset "commit_log refuses last = $(case.last)" for case in BAD_LASTS
    with_logged() do dir, store, chain, copy, r2
        msg = "last must be nothing or an Integer ≥ 1"
        @test_throws ArgumentError msg commit_log(copy; case.last)
    end
end

@testset "commit_log over a warm cache makes no request" begin
    with_logged() do dir, store, chain, copy, r2
        empty!(store.calls)
        commit_log(copy)
        @test isempty(store.calls)
    end
end

@testset "commit_log is the copy's history, not the chain's" begin
    with_logged() do dir, store, chain, copy, r2
        with_copy(chain, joinpath(dir, "two")) do other
            msg = "commit_log(copy): the local copy at $(other.path) has no head yet"
            @test_throws ArgumentError msg commit_log(other)
            sync!(other)
            insert_id!(other, 2; comment = "from two")
        end
        @test first(commit_log(copy)).slot == 2
        sync!(copy)
        @test first(commit_log(copy)).comment == "from two"
    end
end

@testset "commit_log of a pinned copy ends at its pin" begin
    with_logged() do dir, store, chain, copy, r2
        old = as_of(chain, 1)
        @test [e.slot for e in commit_log(old)] == [1, 0]
        close(old)
    end
end

@testset "commit_log fetches a missing or damaged cached record" begin
    with_logged() do dir, store, chain, copy, r2
        insert_id!(copy, 2)
        log = commit_log(copy)
        good = read(cached(chain, 2))
        rm(cached(chain, 3))
        write(cached(chain, 2), UInt8[0x00])
        @test commit_log(copy) == log
        @test isfile(cached(chain, 3)) && read(cached(chain, 2)) == good
    end
end

@testset "commit_log raises when the store's record does not hash as named" begin
    with_logged() do dir, store, chain, copy, r2
        plant!(store, slotkey(2), UInt8[0x00])
        write(cached(chain, 2), UInt8[0x00])
        err = (@test_throws RewrittenChainError "the store's record" commit_log(copy)).value
        @test err.slot == 2
        @test read(cached(chain, 2)) == UInt8[0x00]
    end
end

@testset "commit_log refuses a closed copy" begin
    with_logged() do dir, store, chain, copy, r2
        closed = CT.open(chain, copy.path)
        close(closed)
        @test_throws ArgumentError "is closed" commit_log(closed)
    end
end

@testset "commit_log infers" begin
    with_logged() do dir, store, chain, copy, r2
        @test @inferred(commit_log(copy)) isa Vector{CT.CommitLogEntry}
    end
end
