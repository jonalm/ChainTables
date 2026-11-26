using Test
using ChainTables: ChainTables, ChainNotFoundError, FingerprintMismatchError, LocalCopy,
    PinnedCopyError, RewrittenChainError, StateFingerprint, TransactionHash,
    TransportError, WrongChainError, as_of, create_chain, head, is_pinned, sync!, table,
    tables, write_builder

include("fixtures/chain_copies.jl")
include("fixtures/object_stores.jl")
include("fixtures/forged_records.jl")
include("fixtures/damaged_copies.jl")

const NO_HASH = TransactionHash(zeros(UInt8, 32))

# A local copy at slot 2: the table `samples`, then one more row.
function with_two_slots(f)
    with_samples_copy() do local_copy
        commit_sample!(local_copy, 3)
        f(local_copy)
    end
    return nothing
end

beside(local_copy, name) = joinpath(dirname(local_copy.path), name)

temporary_copies() = filter(startswith("chaintables-as_of-"), readdir(tempdir()))

# A record for slot 2 of the chain of `local_copy`, with the right parent and a state
# fingerprint that no client computes.
function record_with_wrong_fingerprint(local_copy)
    parent = stored_hash(local_copy.chain.store, 1)
    return forged_record(local_copy, 2, parent; fingerprint = fill(0xee, 32))
end

@testset "as_of returns a temporary pinned copy at a slot" begin
    with_two_slots() do local_copy
        chain = local_copy.chain
        pinned = @inferred as_of(chain, 1)
        @test pinned isa LocalCopy
        @test is_pinned(pinned)
        @test head(pinned).slot == 1
        @test head(pinned).transaction_hash == stored_hash(chain.store, 1)
        @test tables(pinned) == ["samples"]
        @test length(table(pinned, :samples)) == 2
        @test startswith(basename(pinned.path), "chaintables-as_of-")
        path = pinned.path
        close(pinned)
        @test !ispath(path)
        # The live copy was never touched.
        @test head(local_copy).slot == 2
        @test !is_pinned(local_copy)
    end
end

@testset "as_of finds the slot of a TransactionHash" begin
    with_two_slots() do local_copy
        target = TransactionHash(stored_hash(local_copy.chain.store, 1))
        pinned = @inferred as_of(local_copy.chain, target)
        @test head(pinned).slot == 1
        close(pinned)
    end
end

@testset "as_of returns a copy that sync! and write_builder refuse" begin
    with_two_slots() do local_copy
        pinned = as_of(local_copy.chain, 1)
        @test_throws PinnedCopyError "the call was `sync!`" sync!(pinned)
        @test_throws PinnedCopyError "pinned" write_builder(pinned)
        @test head(pinned).slot == 1
        close(pinned)
    end
end

const NOT_TARGETS = [
    (target = UInt8[1, 2], type = "Vector{UInt8}"),
    (target = StateFingerprint(zeros(UInt8, 32)), type = "ChainTables.StateFingerprint"),
    (target = 1.5, type = "Float64"),
]

@testset "as_of refuses a target that is a $(case.type)" for case in NOT_TARGETS
    with_samples_copy() do local_copy
        refused = "as_of takes a slot (an Integer) or a TransactionHash, got a $(case.type)"
        @test_throws ArgumentError refused as_of(local_copy.chain, case.target)
    end
end

@testset "as_of refuses a negative slot" begin
    with_samples_copy() do local_copy
        @test_throws ArgumentError "slot -1 is negative" as_of(local_copy.chain, -1)
    end
end

@testset "as_of refuses a slot above the chain's head" begin
    with_two_slots() do local_copy
        above = "the chain at bkt/p has no slot 9; its head is below it"
        @test_throws ArgumentError above as_of(local_copy.chain, 9)
    end
end

@testset "as_of refuses a TransactionHash that no record of the chain has" begin
    with_two_slots() do local_copy
        not_found = "no record of the chain at bkt/p has the transaction hash " *
            "$("0"^64); slots 0 to 2 were read"
        @test_throws ArgumentError not_found as_of(local_copy.chain, NO_HASH)
    end
end

const ABSENT_TARGETS = [
    (name = "slot 0", target = 0), (name = "slot 2", target = 2),
    (name = "a TransactionHash", target = NO_HASH),
]

@testset "as_of throws ChainNotFoundError for $(case.name)" for case in ABSENT_TARGETS
    mktempdir() do dir
        chain = chain_in(dir)
        not_found = "the call was `as_of`"
        err = @test_throws ChainNotFoundError not_found as_of(chain, case.target)
        @test (err.value.bucket, err.value.prefix) == ("bkt", "p")
    end
end

@testset "as_of removes the directory it made when the target is refused" begin
    with_two_slots() do local_copy
        path = beside(local_copy, "refused")
        @test_throws ArgumentError "no slot 9" as_of(local_copy.chain, 9; path)
        @test !ispath(path)
        # The path is fresh again.
        pinned = as_of(local_copy.chain, 1; path)
        @test head(pinned).slot == 1
        close(pinned)
    end
end

@testset "as_of removes the directory it made when the replay fails at once" begin
    with_two_slots() do local_copy
        store = local_copy.chain.store
        dir = dirname(local_copy.path)
        cold = chain_in(dir; store, cache = "cold")
        reset = () -> throw(TransportError("connection reset by peer"))
        store.fault = FaultAt(:fetch_object, slot_key(0), :before, reset)
        path = beside(local_copy, "cut")
        @test_throws TransportError "connection reset by peer" as_of(cold, 1; path)
        @test !ispath(path)
    end
end

@testset "as_of removes a temporary copy whose record does not reproduce" begin
    with_two_slots() do local_copy
        chain = local_copy.chain
        lie = record_with_wrong_fingerprint(local_copy)
        plant!(chain.store, slot_key(2), lie)
        write(record_file(chain, 2), lie)
        before = temporary_copies()
        err = @test_throws FingerprintMismatchError "fingerprint" as_of(chain, 2)
        @test err.value.slot == 2
        @test temporary_copies() == before
    end
end

@testset "as_of keeps a given path and opens it again at the same slot" begin
    with_two_slots() do local_copy
        chain = local_copy.chain
        path = beside(local_copy, "pinned")
        pinned = as_of(chain, 1; path)
        @test pinned.path == abspath(path)
        close(pinned)
        @test isdir(path)
        head_bytes = read(joinpath(path, "heads", "000000000001"))
        n = length(chain.store.calls)
        pinned = as_of(chain, 1; path)
        @test head(pinned).slot == 1
        @test read(joinpath(path, "heads", "000000000001")) == head_bytes
        # The record of the head's slot is asked of the store (ADR-0041).
        @test chain.store.calls[(n + 1):end] == [(:fetch_object, slot_key(1))]
        close(pinned)
    end
end

@testset "as_of replays a copy pinned below the target forward" begin
    with_two_slots() do local_copy
        path = beside(local_copy, "pinned")
        close(as_of(local_copy.chain, 1; path))
        pinned = as_of(local_copy.chain, 2; path)
        @test head(pinned).slot == 2
        @test is_pinned(pinned)
        @test table(pinned, :samples)[3].mass == 3.0
        close(pinned)
    end
end

@testset "as_of refuses a copy pinned above the target" begin
    with_two_slots() do local_copy
        path = beside(local_copy, "pinned")
        close(as_of(local_copy.chain, 2; path))
        above = "is pinned at slot 2, above 1; a local copy never moves backwards"
        @test_throws ArgumentError above as_of(local_copy.chain, 1; path)
        pinned = as_of(local_copy.chain, 2; path)
        @test head(pinned).slot == 2
        close(pinned)
    end
end

@testset "as_of refuses a live copy" begin
    with_two_slots() do local_copy
        live = "the local copy at $(local_copy.path) is live; as_of never touches a live " *
            "copy"
        @test_throws ArgumentError live as_of(local_copy.chain, 1; local_copy.path)
        @test !is_pinned(local_copy)
        @test head(local_copy).slot == 2
    end
end

@testset "as_of finds a rewritten chain under a copy pinned at the target" begin
    with_two_slots() do local_copy
        chain = local_copy.chain
        path = beside(local_copy, "pinned")
        close(as_of(chain, 2; path))
        plant!(chain.store, slot_key(2), record_with_wrong_fingerprint(local_copy))
        other = "the slot of the local copy's head holds another record"
        @test_throws RewrittenChainError other as_of(chain, 2; path)
        @test isdir(path)
    end
end

@testset "as_of holds a copy pinned at the target against its record" begin
    with_two_slots() do local_copy
        chain = local_copy.chain
        path = beside(local_copy, "pinned")
        close(as_of(chain, 2; path))
        lie = record_with_wrong_fingerprint(local_copy)
        plant!(chain.store, slot_key(2), lie)
        # The head names the record, as a head built on it would.
        rewrite_head_file!(path, 2, ChainTables.Ops.transaction_hash(lie))
        differs = "the pinned copy's head is not the result of the record in its slot"
        err = @test_throws FingerprintMismatchError differs as_of(chain, 2; path)
        e = err.value
        @test (e.path, e.chain_id, e.slot) == (abspath(path), bound_chain_id(local_copy), 2)
        @test e.expected == fill(0xee, 32)
        # A given path is never deleted.
        @test isdir(path)
    end
end

@testset "as_of throws RewrittenChainError for a slot that vanishes during the scan" begin
    with_two_slots() do local_copy
        store = local_copy.chain.store
        cold = chain_in(dirname(local_copy.path); store, cache = "cold")
        vanish = () -> delete!(store.objects, slot_key(1))
        store.fault = FaultAt(:fetch_object, slot_key(1), :before, vanish)
        vanished = "the slot was there when head discovery probed it and is absent now"
        err = @test_throws RewrittenChainError vanished as_of(cold, NO_HASH)
        @test (err.value.slot, err.value.found) == (1, nothing)
    end
end

@testset "as_of throws WrongChainError for a path bound to another chain" begin
    with_two_slots() do local_copy
        other = chain_in(dirname(local_copy.path); prefix = "q", cache = "q_cache")
        create_chain(other)
        @test_throws WrongChainError "chain" as_of(other, 0; local_copy.path)
        pinned_path = beside(local_copy, "pinned")
        close(as_of(local_copy.chain, 1; path = pinned_path))
        @test_throws WrongChainError "chain" as_of(other, 0; path = pinned_path)
    end
end
