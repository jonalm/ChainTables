# #34 step 6 — ADR-0019, ADR-0010, ADR-0016: InMemoryObjectStore refuses a put to an
# existing key, keeps absent and failed distinct, shuffles listings, ties whole-second
# `modified` values, matches prefixes by bytes; and it is the submodule's only member.
using ChainTables: AbstractObjectStore, PutOutcome, ObjectMeta,
    fetch_object, put_object_if_absent, stat_object, list_objects
using ChainTables.Testing: InMemoryObjectStore

@testset "Testing" begin
    @testset "the submodule holds the store and nothing else" begin
        members = filter(names(ChainTables.Testing; all = true)) do n
            s = String(n)
            !startswith(s, "#") && !startswith(s, "_") && n ∉ (:Testing, :eval, :include)
        end
        @test members == [:InMemoryObjectStore]
        @test Base.isexported(ChainTables.Testing, :InMemoryObjectStore) == false
        @test InMemoryObjectStore <: AbstractObjectStore
    end

    @testset "put creates once and never overwrites (ADR-0016 rules 1, 2, 4)" begin
        store = InMemoryObjectStore()
        first = put_object_if_absent(store, "p/000000000000", b"first")
        @test first isa PutOutcome
        @test first.created
        @test first.status == 200
        # rule 4: a GET of a key a PUT has just created returns that object
        @test fetch_object(store, "p/000000000000") == b"first"
        # rules 1 and 2: the second put fails, as 412, and the bytes are untouched
        second = put_object_if_absent(store, "p/000000000000", b"second")
        @test !second.created
        @test second.status == 412
        @test fetch_object(store, "p/000000000000") == b"first"
        # the store keeps its own copy of the bytes: neither the input nor the output aliases it
        input = UInt8[1, 2, 3]
        put_object_if_absent(store, "p/000000000001", input)
        input[1] = 9
        got = fetch_object(store, "p/000000000001")
        @test got == UInt8[1, 2, 3]
        got[2] = 9
        @test fetch_object(store, "p/000000000001") == UInt8[1, 2, 3]
    end

    @testset "absent is nothing, failure raises, never conflated" begin
        store = InMemoryObjectStore()
        @test fetch_object(store, "p/000000000000") === nothing
        @test stat_object(store, "p/000000000000") === nothing
        # a fault on the request raises out of the verb; nothing is returned in its place
        store.fault = (verb, key, phase) -> (phase === :before && verb === :fetch_object) &&
            error("simulated transport failure on $key")
        @test_throws "simulated transport failure on p/000000000000" fetch_object(store, "p/000000000000")
        @test stat_object(store, "p/000000000000") === nothing
        # a lost acknowledgement: the put lands, then the response is lost (ADR-0002, ADR-0010)
        store.fault = (verb, key, phase) -> (phase === :after && verb === :put_object_if_absent) &&
            error("response dropped")
        @test_throws "response dropped" put_object_if_absent(store, "p/000000000000", b"landed")
        store.fault = (verb, key, phase) -> nothing
        @test fetch_object(store, "p/000000000000") == b"landed"
        @test !put_object_if_absent(store, "p/000000000000", b"again").created
    end

    @testset "stat reports size and a whole-second modified that can tie" begin
        clock = Ref{Int64}(1_700_000_000)
        store = InMemoryObjectStore(; clock = () -> clock[])
        put_object_if_absent(store, "p/000000000000", zeros(UInt8, 7))
        put_object_if_absent(store, "p/000000000001", zeros(UInt8, 3))
        a = stat_object(store, "p/000000000000")
        b = stat_object(store, "p/000000000001")
        @test a isa ObjectMeta && b isa ObjectMeta
        @test a.key == "p/000000000000" && a.size == 7
        @test b.key == "p/000000000001" && b.size == 3
        @test a.modified == b.modified == 1_700_000_000
        clock[] += 1
        put_object_if_absent(store, "p/000000000002", UInt8[])
        @test stat_object(store, "p/000000000002").modified == 1_700_000_001
        # the default clock is whole seconds since the epoch
        default = InMemoryObjectStore()
        before = floor(Int64, time())
        put_object_if_absent(default, "k", b"x")
        m = stat_object(default, "k").modified
        @test m isa Int64
        @test before <= m <= floor(Int64, time())
    end

    @testset "listings are shuffled, prefixes and start_after compare by bytes" begin
        store = InMemoryObjectStore(; seed = 7)
        keys = ["p/" * lpad(i, 12, '0') for i in 0:39]
        for k in keys
            put_object_if_absent(store, k, b"")
        end
        put_object_if_absent(store, "p/_reserved", b"")
        put_object_if_absent(store, "q/000000000000", b"")
        listed = list_objects(store, "p/")
        @test all(m -> m isa ObjectMeta, listed)
        @test sort([m.key for m in listed]) == vcat(keys, ["p/_reserved"])
        # never in order: one of many listings would otherwise pass by luck
        @test any(_ -> [m.key for m in list_objects(store, "p/")] != vcat(keys, ["p/_reserved"]), 1:8)
        @test [m.key for m in list_objects(store, "")] |> length == 42
        @test isempty(list_objects(store, "z"))
        # start_after is exclusive and byte-ordered: `_` (0x5F) sorts after every digit
        tail = sort([m.key for m in list_objects(store, "p/"; start_after = "p/000000000037")])
        @test tail == ["p/000000000038", "p/000000000039", "p/_reserved"]
        @test isempty(list_objects(store, "p/"; start_after = "p/_reserved"))
        # a prefix is bytes, not characters: half of a two-byte code point still matches
        put_object_if_absent(store, "é/000000000000", b"")
        half = String([0xc3])
        @test [m.key for m in list_objects(store, half)] == ["é/000000000000"]
        @test isempty(list_objects(store, "e"))
        # the same seed gives the same shuffle, so a test can pin an order it wants
        again = InMemoryObjectStore(; seed = 7)
        for k in keys
            put_object_if_absent(again, k, b"")
        end
        put_object_if_absent(again, "p/_reserved", b"")
        put_object_if_absent(again, "q/000000000000", b"")
        put_object_if_absent(again, "é/000000000000", b"")
        @test [m.key for m in list_objects(again, "p/")] != vcat(keys, ["p/_reserved"])
    end

    @testset "every request is logged" begin
        store = InMemoryObjectStore()
        put_object_if_absent(store, "a", b"")
        fetch_object(store, "a")
        stat_object(store, "b")
        list_objects(store, "")
        @test store.calls == [(:put_object_if_absent, "a"), (:fetch_object, "a"),
                              (:stat_object, "b"), (:list_objects, "")]
    end
end
