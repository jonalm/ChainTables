using Test
using ChainTables: ChainTables, sync!
using ChainTables.Testing: InMemoryObjectStore

# `fetch_top_slot` is internal. It is called here because its probes are the contract
# (ADR-0012), and a chain of a thousand records is not built by commits.
include("fixtures/chain_copies.jl")
include("fixtures/object_stores.jl")

# A chain whose prefix holds an object, of no bytes, at each of `slots`.
function chain_with_slots(slots)
    store = InMemoryObjectStore()
    foreach(slot -> plant!(store, slot_key(slot), UInt8[]), slots)
    return chain_in("/c"; store)
end

# The top slot that head discovery finds above `known`, and the requests it made.
function discovered(chain, known)
    n = length(chain.store.calls)
    top = ChainTables.fetch_top_slot(chain, known)
    return (; top, requests = chain.store.calls[(n + 1):end])
end


@testset "head discovery makes one probe of an empty prefix" begin
    found = discovered(chain_with_slots(Int[]), -1)
    @test found.top == -1
    @test found.requests == [(:stat_object, slot_key(0))]
end

@testset "head discovery from nothing takes about 2 log2 N stat probes" begin
    found = discovered(chain_with_slots(0:999), -1)
    @test found.top == 999
    @test length(found.requests) <= 2 * ceil(Int, log2(1001)) + 1
    @test unique(first.(found.requests)) == [:stat_object]
    @test found.requests[1:4] == [(:stat_object, slot_key(slot)) for slot in (0, 1, 3, 7)]
end

@testset "head discovery at the head makes one probe" begin
    found = discovered(chain_with_slots(0:999), 999)
    @test found.top == 999
    @test found.requests == [(:stat_object, slot_key(1000))]
end

@testset "head discovery a few slots behind makes a few probes" begin
    found = discovered(chain_with_slots(0:999), 990)
    @test found.top == 999
    @test length(found.requests) <= 2 * ceil(Int, log2(10)) + 1
end

@testset "head discovery finds the top from any known slot" begin
    chain = chain_with_slots(0:5)
    @testset "known = $known" for known in (-1, 2, 5)
        @test discovered(chain, known).top == 5
    end
end

@testset "head discovery finds a lone slot 0" begin
    @test discovered(chain_with_slots(0:0), -1).top == 0
end

@testset "a probe that misses caches nothing, and the slot is seen once it lands" begin
    with_samples_copy() do local_copy
        chain = local_copy.chain
        sync!(local_copy)
        @test !isfile(record_file(chain, 2))
        with_copy_beside(local_copy, "other") do other
            sync!(other)
            commit_sample!(other, 3)
        end
        @test sync!(local_copy).applied == 1
        @test isfile(record_file(chain, 2))
        # Slot 1 was fetched as the top of the other copy's sync, and as the head's own
        # slot by this copy's two syncs and by the other copy's commit. Nothing else
        # fetched it: this copy had committed and cached it.
        @test n_requests(chain.store, :fetch_object, slot_key(1)) == 4
    end
end
