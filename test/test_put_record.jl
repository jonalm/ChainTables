using Test
using ChainTables: ChainTables, AbstractObjectStore, Chain, PutOutcome, RewrittenChainError,
    TransportError, fetch_object, put_object_if_absent, stat_object
using ChainTables.Testing: InMemoryObjectStore

include("fixtures/chains.jl")

# put_record! is internal; commit! and create_chain reach it, and test_commit.jl covers
# the outcomes there. Here its read-back and retry loop are driven directly.
const CT = ChainTables
const OURS, THEIRS = b"our record", b"their record"

# A store whose conditional put always says 412 while nothing is ever there.
struct PutTestPhantom412 <: AbstractObjectStore
    inner::InMemoryObjectStore
end
ChainTables.cache_namespace(s::PutTestPhantom412) = ChainTables.cache_namespace(s.inner)
ChainTables.put_object_if_absent(s::PutTestPhantom412, key, bytes) = PutOutcome(false, 412)
ChainTables.fetch_object(s::PutTestPhantom412, key) = fetch_object(s.inner, key)

# A store that refuses a put with a status the port does not allow.
struct PutTestBadOutcome <: AbstractObjectStore end
ChainTables.cache_namespace(::PutTestBadOutcome) = "bad"
ChainTables.put_object_if_absent(::PutTestBadOutcome, key, bytes) = PutOutcome(false, 200)

function with_put_chain(f; store = InMemoryObjectStore())
    mktempdir() do dir
        f(Chain("bkt", "p"; store, cache_dir = dir), store)
    end
    return nothing
end

puts(store, key) = count(==((:put_object_if_absent, key)), store.calls)

# `n` failures with `status` before the put goes through; the count is shared state.
function failing_puts(n, status)
    left = Ref(n)
    return function (verb, key, phase)
        verb === :put_object_if_absent && phase === :before && left[] > 0 || return nothing
        left[] -= 1
        throw(TransportError("refused"; status))
    end
end

@testset "put_record! creates the slot and caches the record" begin
    with_put_chain() do chain, store
        @test CT.put_record!(chain, slotkey(1), OURS) === nothing
        @test read(CT.record_path(chain, slotkey(1))) == OURS
        @test (:fetch_object, slotkey(1)) ∉ store.calls
    end
end

@testset "put_record! finds our own bytes after a lost acknowledgement" begin
    with_put_chain() do chain, store
        store.fault = (verb, key, phase) -> verb === :put_object_if_absent &&
            phase === :after && throw(TransportError("connection reset by peer"))
        @test CT.put_record!(chain, slotkey(1), OURS) === nothing
        @test puts(store, slotkey(1)) == 1
        @test store.objects[slotkey(1)] == OURS
    end
end

@testset "put_record! returns another record's bytes, cached as the slot's" begin
    with_put_chain() do chain, store
        put_object_if_absent(store, slotkey(2), THEIRS)
        @test CT.put_record!(chain, slotkey(2), OURS) == THEIRS
        @test read(CT.record_path(chain, slotkey(2))) == THEIRS
    end
end

const RETRY_CASES = [
    (name = "503 twice", failures = 2, status = 503, puts = 3),
    (name = "409 once", failures = 1, status = 409, puts = 2),
    (name = "429 three times", failures = 3, status = 429, puts = 4),
]

@testset "put_record! re-issues a retryable failure: $(case.name)" for case in RETRY_CASES
    with_put_chain() do chain, store
        store.fault = failing_puts(case.failures, case.status)
        @test CT.put_record!(chain, slotkey(1), OURS) === nothing
        @test puts(store, slotkey(1)) == case.puts
    end
end

@testset "put_record! throws a refusal at once" begin
    with_put_chain() do chain, store
        store.fault = failing_puts(1, 403)
        @test_throws TransportError "refused" CT.put_record!(chain, slotkey(1), OURS)
        @test puts(store, slotkey(1)) == 1
    end
end

@testset "put_record! throws the last failure after four attempts" begin
    with_put_chain() do chain, store
        store.fault = failing_puts(99, 503)
        @test_throws TransportError "refused" CT.put_record!(chain, slotkey(1), OURS)
        @test puts(store, slotkey(1)) == CT.PUT_ATTEMPTS
        @test !haskey(store.objects, slotkey(1))
    end
end

@testset "put_record! gives up on a 412 with nothing there" begin
    with_put_chain(; store = PutTestPhantom412(InMemoryObjectStore())) do chain, store
        msg = "refused as existing (412) and a fetch found nothing there, 4 times"
        @test_throws RewrittenChainError msg CT.put_record!(chain, slotkey(9), OURS)
    end
end

@testset "put_record! refuses a store that breaks the port's promise" begin
    with_put_chain(; store = PutTestBadOutcome()) do chain, store
        msg = "returned created = false with status 200"
        @test_throws ArgumentError msg CT.put_record!(chain, "k", OURS)
    end
end
