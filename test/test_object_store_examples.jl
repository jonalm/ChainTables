using Test
using ChainTables: ObjectMeta, PutOutcome, cache_namespace, fetch_object, list_objects,
    put_object_if_absent, record_author, stat_object
using ChainTables.Testing: InMemoryObjectStore

@testset "put_object_if_absent example" begin
    store = InMemoryObjectStore()

    # A put creates the key only when it is absent. A second put changes nothing.
    @test put_object_if_absent(store, "p/000000000000", b"first").created
    @test !put_object_if_absent(store, "p/000000000000", b"second").created
    @test fetch_object(store, "p/000000000000") == b"first"
end

@testset "PutOutcome example" begin
    # What a store of your own returns from `put_object_if_absent`: `created`, and the
    # HTTP status that it saw. `false` goes with a 412 only.
    refused = PutOutcome(false, 412)
    @test !refused.created
    @test refused.status == 412
end

@testset "fetch_object example" begin
    store = InMemoryObjectStore()
    put_object_if_absent(store, "p/000000000000", b"record")

    # The whole object, or `nothing` for a key that does not exist.
    @test fetch_object(store, "p/000000000000") == b"record"
    @test fetch_object(store, "p/000000000001") === nothing
end

@testset "stat_object example" begin
    store = InMemoryObjectStore(; clock = () -> 1_700_000_000)
    put_object_if_absent(store, "p/000000000000", b"record")

    # Key, size in bytes and time of the last change, without the bytes.
    @test stat_object(store, "p/000000000000") ==
        ObjectMeta("p/000000000000", 6, 1_700_000_000)
    @test stat_object(store, "p/000000000001") === nothing
end

@testset "ObjectMeta example" begin
    # What a store of your own returns from `stat_object` and `list_objects`.
    meta = ObjectMeta("p/000000000000", 6, 1_700_000_000)
    @test meta.size == 6
end

@testset "list_objects example" begin
    store = InMemoryObjectStore()
    put_object_if_absent(store, "p/000000000000", b"a")
    put_object_if_absent(store, "p/000000000001", b"b")
    put_object_if_absent(store, "q/000000000000", b"c")

    # Every object under a prefix, in no promised order.
    keys = sort([meta.key for meta in list_objects(store, "p/")])
    @test keys == ["p/000000000000", "p/000000000001"]

    # `start_after` leaves out the keys up to and including it.
    after = list_objects(store, "p/"; start_after = "p/000000000000")
    @test [meta.key for meta in after] == ["p/000000000001"]
end

@testset "cache_namespace example" begin
    # The record cache keeps what is read through two stores in two directories.
    a, b = InMemoryObjectStore(), InMemoryObjectStore()
    @test startswith(cache_namespace(a), "mem-")
    @test cache_namespace(a) != cache_namespace(b)
end

@testset "record_author example" begin
    # On a plain bucket the author of a record is the user of this machine.
    withenv("USER" => "ada") do
        @test record_author(InMemoryObjectStore()) == "ada"
    end
end
