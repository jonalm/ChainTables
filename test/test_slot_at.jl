using Test
using ChainTables: ChainTables, ChainNotFoundError, Ops, RewrittenChainError,
    put_object_if_absent, slot_at
using ChainTables.Model: Column, Shape
using ChainTables.Ops: Client, CreateTable, Insert, Record
using StableRNGs: StableRNG

include("fixtures/chain_copies.jl")
include("fixtures/object_stores.jl")

# The time of the record of slot `s` is `TIMES[s + 1]`: not monotone, as the clocks of
# several committers are not.
const TIMES = [10, 100, 50, 200, 150]

const SLOTS_AT = [
    (time_ms = 10, slot = 0), (time_ms = 49, slot = 0), (time_ms = 50, slot = 2),
    (time_ms = 99, slot = 2), (time_ms = 100, slot = 2), (time_ms = 149, slot = 2),
    (time_ms = 150, slot = 4), (time_ms = 200, slot = 4), (time_ms = 10^12, slot = 4),
]

const SAMPLE_SHAPE = Shape([Column("id", "int64", false)], ["id"])

# A chain whose records carry the times `TIMES`, forged by hand: no API name sets the
# time of a record. Their state fingerprints are never checked by a scan.
function chain_with_times(dir)
    chain = chain_in(dir)
    chain_id = rand(StableRNG(1), UInt8, 16)
    parent = nothing
    for (i, time_ms) in enumerate(TIMES)
        slot = i - 1
        client = Client(nothing, nothing, "L", "J", time_ms)
        fingerprint = zeros(UInt8, 32)
        record = Record(chain_id, slot, parent, fingerprint, client, nothing, ops_at(slot))
        bytes = Ops.encode_record(record)
        put_object_if_absent(chain.store, slot_key(slot), bytes)
        parent = Ops.transaction_hash(bytes)
    end
    return chain
end

function ops_at(slot)
    slot == 0 && return Ops.Op[]
    slot == 1 && return [CreateTable("samples", SAMPLE_SHAPE)]
    return [Insert("samples", [Any[slot]])]
end

@testset "slot_at at $(case.time_ms) ms is slot $(case.slot)" for case in SLOTS_AT
    mktempdir() do dir
        chain = chain_with_times(dir)
        @test @inferred(slot_at(chain, case.time_ms)) == case.slot
    end
end

@testset "slot_at throws ArgumentError for a time before the genesis record" begin
    mktempdir() do dir
        before = "9 is before the genesis record's client.time_ms, 10; there is no " *
            "state before slot 0"
        @test_throws ArgumentError before slot_at(chain_with_times(dir), 9)
    end
end

@testset "slot_at throws ArgumentError for a time that is not an Integer" begin
    mktempdir() do dir
        not_integer = "time_ms is a Float64, not an Integer of milliseconds"
        @test_throws ArgumentError not_integer slot_at(chain_with_times(dir), 1.5)
    end
end

@testset "slot_at throws ChainNotFoundError where there is no slot 0" begin
    mktempdir() do dir
        chain = chain_in(dir)
        err = @test_throws ChainNotFoundError "the call was `slot_at`" slot_at(chain, 5)
        @test (err.value.bucket, err.value.prefix) == ("bkt", "p")
    end
end

@testset "slot_at throws RewrittenChainError for a slot that vanishes during the scan" begin
    mktempdir() do dir
        chain = chain_with_times(dir)
        store = chain.store
        vanish = () -> delete!(store.objects, slot_key(3))
        store.fault = FaultAt(:fetch_object, slot_key(3), :before, vanish)
        vanished = "the slot was there when head discovery probed it and is absent now"
        err = @test_throws RewrittenChainError vanished slot_at(chain, 10^12)
        @test (err.value.slot, err.value.found) == (3, nothing)
    end
end
