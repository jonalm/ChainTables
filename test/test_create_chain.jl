using Test
using ChainTables: ChainTables, Chain, LostRaceError, Model, Ops, RewrittenChainError,
    TransactionHash, create_chain, put_object_if_absent, try_create_chain
using ChainTables.Testing: InMemoryObjectStore

include("fixtures/chain_copies.jl")
include("fixtures/object_stores.jl")

const CHAIN_ID_TEXT = r"^[A-Z2-7]{26}$"

function with_chain(f; keywords...)
    mktempdir(dir -> f(chain_in(dir; keywords...)))
    return nothing
end

genesis(chain) = Ops.decode_record(chain.store.objects[slot_key(0)]; slot = 0)

@testset "create_chain writes the genesis record with one put" begin
    with_chain() do chain
        created = @inferred create_chain(chain)
        @test created.slot == 0
        @test occursin(CHAIN_ID_TEXT, created.chain_id)
        @test created.transaction_hash isa TransactionHash
        @test chain.store.calls == [(:put_object_if_absent, slot_key(0))]
        @test created.transaction_hash == stored_hash(chain.store, 0)
    end
end

@testset "create_chain writes a record with no ops, no parent and no comment" begin
    with_chain() do chain
        created = create_chain(chain)
        record = genesis(chain)
        @test isempty(record.ops)
        @test record.prev_hash === nothing
        @test record.comment === nothing
        @test ChainTables.chain_id_string(record.chain_id) == created.chain_id
        @test record.state_fingerprint == Model.state_fingerprint(Model.Content())
    end
end

@testset "create_chain names the host and the author unless the chain leaves them out" begin
    with_chain() do chain
        create_chain(chain)
        @test genesis(chain).client.host === nothing
        @test genesis(chain).client.user === nothing
    end
    with_chain(; record_host = true, record_user = true) do chain
        withenv(() -> create_chain(chain), "USER" => "ada")
        @test genesis(chain).client.host == gethostname()
        @test genesis(chain).client.user == "ada"
    end
end

@testset "create_chain puts slot 0 at the bucket root for an empty prefix" begin
    with_chain(; prefix = "") do chain
        create_chain(chain)
        @test collect(keys(chain.store.objects)) == ["000000000000"]
    end
end

@testset "create_chain caches the record that it wrote" begin
    with_chain() do chain
        create_chain(chain)
        cached = ChainTables.record_path(chain.cache, chain.store, "bkt", slot_key(0))
        @test read(cached) == chain.store.objects[slot_key(0)]
    end
end

@testset "create_chain loses the race to a chain that is there, and is not retried" begin
    with_chain() do chain
        created = create_chain(chain)
        n = length(chain.store.calls)
        exists = "A chain is at this bucket and prefix already"
        err = @test_throws LostRaceError exists create_chain(chain)
        e = err.value
        @test (e.bucket, e.prefix, e.chain_id, e.slot) == ("bkt", "p", created.chain_id, 0)
        @test e.transaction_hash == created.transaction_hash
        @test e.reason === :chain_exists
        # The read-back asks the store, never the record cache.
        @test chain.store.calls[(n + 1):end] ==
            [(:put_object_if_absent, slot_key(0)), (:fetch_object, slot_key(0))]
        @test created.transaction_hash == stored_hash(chain.store, 0)
    end
end

@testset "create_chain loses the race to a malformed record at slot 0" begin
    with_chain() do chain
        put_object_if_absent(chain.store, slot_key(0), b"not a record")
        err = @test_throws LostRaceError "its chain id is not known" create_chain(chain)
        @test err.value.chain_id === nothing
        @test err.value.slot == 0
        @test err.value.transaction_hash == Ops.transaction_hash(b"not a record")
    end
end

@testset "create_chain refuses a store that answers false without a 412" begin
    with_chain(; store = BadOutcomeStore()) do chain
        broken = "returned created = false with status 200; a store may answer false " *
            "only for a 412"
        @test_throws ArgumentError broken create_chain(chain)
    end
end

@testset "create_chain gives up on a 412 with nothing in the slot" begin
    with_chain(; store = Phantom412Store(InMemoryObjectStore())) do chain
        gave_up = "the put to p/000000000000 was refused as existing (412) and a fetch " *
            "found nothing there, 4 times over"
        err = @test_throws RewrittenChainError gave_up create_chain(chain)
        @test (err.value.bucket, err.value.prefix, err.value.slot) == ("bkt", "p", 0)
        @test n_requests(chain.store.inner, :fetch_object, slot_key(0)) == 4
    end
end

@testset "try_create_chain creates a chain" begin
    with_chain() do chain
        created = try_create_chain(chain)
        @test keys(created) == (:chain_id, :slot, :transaction_hash)
        @test created.transaction_hash == stored_hash(chain.store, 0)
        @test Base.infer_return_type(try_create_chain, (typeof(chain),)) ==
            Union{Nothing, typeof(created)}
    end
end

@testset "try_create_chain returns nothing for a chain that is there" begin
    with_chain() do chain
        genesis_bytes = (create_chain(chain); copy(chain.store.objects[slot_key(0)]))
        n = length(chain.store.calls)
        @test try_create_chain(chain) === nothing
        @test chain.store.calls[(n + 1):end] ==
            [(:put_object_if_absent, slot_key(0)), (:fetch_object, slot_key(0))]
        @test chain.store.objects[slot_key(0)] == genesis_bytes
    end
end

@testset "try_create_chain throws every other failure unchanged" begin
    with_chain(; store = BadOutcomeStore()) do chain
        @test_throws ArgumentError "returned created = false" try_create_chain(chain)
    end
end
