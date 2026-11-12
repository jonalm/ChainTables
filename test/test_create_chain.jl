using Test
using ChainTables: ChainTables, AbstractObjectStore, Chain, LostRaceError, PutOutcome,
    TransactionHash, create_chain, put_object_if_absent, try_create_chain
using ChainTables.Testing: InMemoryObjectStore
using TestConventions: check_inferred

include("fixtures/chains.jl")

const CT = ChainTables

const READ_BACK = [(:put_object_if_absent, slotkey(0)), (:fetch_object, slotkey(0))]

# A store that refuses a put with a status the port does not allow.
struct CreateTestBadOutcome <: AbstractObjectStore end
ChainTables.cache_namespace(::CreateTestBadOutcome) = "bad"
function ChainTables.put_object_if_absent(::CreateTestBadOutcome, key, bytes)
    return PutOutcome(false, 200)
end

function with_chain(f; kw...)
    mktempdir() do dir
        store = InMemoryObjectStore()
        cache_dir = joinpath(dir, "cache")
        chain = Chain(
            "bkt", "p"; store, cache_dir, record_host = false, record_user = false, kw...
        )
        f(chain, store)
    end
    return nothing
end

@testset "create_chain writes a zero-op genesis to slot 0 with one put" begin
    with_chain() do chain, store
        created = create_chain(chain)
        @test created.slot == 0 && occursin(r"^[A-Z2-7]{26}$", created.chain_id)
        @test created.transaction_hash isa TransactionHash
        @test collect(keys(store.objects)) == [slotkey(0)]
        @test store.calls == [(:put_object_if_absent, slotkey(0))]
        @test CT.Ops.transaction_hash(store.objects[slotkey(0)]) == created.transaction_hash
        @test isfile(CT.record_path(chain, slotkey(0)))
    end
end

@testset "create_chain's genesis names the chain and nothing else" begin
    with_chain() do chain, store
        created = create_chain(chain)
        genesis = CT.Ops.decode_record(store.objects[slotkey(0)]; slot = 0)
        @test isempty(genesis.ops) && genesis.prev_hash === nothing
        @test genesis.comment === nothing
        @test CT.chain_id_string(genesis.chain_id) == created.chain_id
        @test genesis.client.host === nothing && genesis.client.user === nothing
        @test genesis.state_fingerprint == CT.state_fingerprint(CT.Content())
    end
end

@testset "create_chain loses to a chain already there, with one put and a read-back" begin
    with_chain() do chain, store
        created = create_chain(chain)
        empty!(store.calls)
        msg = "already fills the slot"
        err = (@test_throws LostRaceError msg create_chain(chain)).value
        @test (err.location, err.chain_id, err.slot) == ("bkt/p", created.chain_id, 0)
        @test err.transaction_hash == created.transaction_hash
        @test store.calls == READ_BACK
        @test CT.Ops.transaction_hash(store.objects[slotkey(0)]) == created.transaction_hash
    end
end

@testset "create_chain loses to a malformed genesis, its chain id unknown" begin
    with_chain() do chain, store
        put_object_if_absent(store, slotkey(0), b"not a record")
        msg = "genesis record is malformed"
        err = (@test_throws LostRaceError msg create_chain(chain)).value
        @test err.chain_id === nothing && err.slot == 0
    end
end

@testset "try_create_chain returns nothing for a chain already there" begin
    with_chain() do chain, store
        created = try_create_chain(chain)
        @test keys(created) == (:chain_id, :slot, :transaction_hash) && created.slot == 0
        empty!(store.calls)
        @test try_create_chain(chain) === nothing
        @test store.calls == READ_BACK
        @test CT.Ops.transaction_hash(store.objects[slotkey(0)]) == created.transaction_hash
    end
end

@testset "try_create_chain lets every other failure through" begin
    mktempdir() do dir
        store = CreateTestBadOutcome()
        chain = Chain("bkt", "p"; store, cache_dir = dir, record_user = false)
        msg = "returned created = false with status 200"
        @test_throws ArgumentError msg try_create_chain(chain)
    end
end

@testset "create_chain and try_create_chain infer" begin
    with_chain() do chain, store
        other = Chain("bkt", "q"; store, cache_dir = chain.cache.dir)
        T = typeof(@inferred create_chain(other))
        check_inferred(Union{Nothing, T}, try_create_chain, chain)
    end
end
