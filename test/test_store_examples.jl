using Test
using ChainTables: ChainTables, AbstractObjectStore, ObjectMeta, PutOutcome,
    cache_namespace, fetch_object, list_objects, put_object_if_absent, record_author,
    stat_object
using ChainTables.Testing: InMemoryObjectStore

# A store of your own subtypes AbstractObjectStore and forwards the four operations.
struct LoggingStore <: AbstractObjectStore
    inner::InMemoryObjectStore
end
ChainTables.cache_namespace(s::LoggingStore) = cache_namespace(s.inner)
ChainTables.fetch_object(s::LoggingStore, key) = fetch_object(s.inner, key)

@testset "AbstractObjectStore example" begin
    store = LoggingStore(InMemoryObjectStore())
    @test store isa AbstractObjectStore
    @test fetch_object(store, "p/000000000000") === nothing     # absent is nothing
end

@testset "PutOutcome example" begin
    outcome = put_object_if_absent(InMemoryObjectStore(), "k", b"bytes")
    @test outcome == PutOutcome(true, 200)                      # created
end

@testset "ObjectMeta example" begin
    store = InMemoryObjectStore()
    put_object_if_absent(store, "k", b"three")
    @test stat_object(store, "k") isa ObjectMeta
    @test stat_object(store, "k").size == 5
end

@testset "fetch_object example" begin
    store = InMemoryObjectStore()
    put_object_if_absent(store, "k", b"bytes")
    @test fetch_object(store, "k") == b"bytes"
    @test fetch_object(store, "missing") === nothing
end

@testset "put_object_if_absent example" begin
    store = InMemoryObjectStore()
    @test put_object_if_absent(store, "k", b"first").created
    # A second put to the same key is refused with a 412 and never overwrites.
    @test put_object_if_absent(store, "k", b"second") == PutOutcome(false, 412)
    @test fetch_object(store, "k") == b"first"
end

@testset "stat_object example" begin
    store = InMemoryObjectStore()
    put_object_if_absent(store, "k", b"bytes")
    @test stat_object(store, "k").key == "k"
    @test stat_object(store, "missing") === nothing
end

@testset "list_objects example" begin
    store = InMemoryObjectStore()
    put_object_if_absent(store, "p/1", b"a")
    put_object_if_absent(store, "p/2", b"b")
    put_object_if_absent(store, "q/1", b"c")
    # The order is not promised, so sort before comparing.
    @test sort([m.key for m in list_objects(store, "p/")]) == ["p/1", "p/2"]
    @test [m.key for m in list_objects(store, "p/"; start_after = "p/1")] == ["p/2"]
end

@testset "record_author example" begin
    # On a plain bucket the author is the environment's USER.
    @test withenv(() -> record_author(InMemoryObjectStore()), "USER" => "alice") == "alice"
end

@testset "cache_namespace example" begin
    # Every in-memory store is its own namespace in the record cache.
    @test startswith(cache_namespace(InMemoryObjectStore()), "mem-")
end
