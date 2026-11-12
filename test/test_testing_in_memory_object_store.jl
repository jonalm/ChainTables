using Test
using ChainTables: ChainTables, AbstractObjectStore, AttachmentChangedError, ObjectMeta,
    PutOutcome, fetch_object, list_objects, put_attachment, put_object_if_absent,
    stat_object
using ChainTables.Testing: InMemoryObjectStore
using SHA: sha256

const SLOT = "p/000000000000"
const ATTACHMENT_BYTES = Vector{UInt8}("an attachment")
const ATTACHMENT_KEY = "p/_attachments/" * bytes2hex(sha256(ATTACHMENT_BYTES))

@testset "InMemoryObjectStore infers its type and is an AbstractObjectStore" begin
    store = @inferred InMemoryObjectStore()
    @test store isa AbstractObjectStore
end

@testset "put_object_if_absent creates a key once, and fetch_object returns it" begin
    store = InMemoryObjectStore()
    first = put_object_if_absent(store, SLOT, b"first")
    @test first == PutOutcome(true, 200)
    @test fetch_object(store, SLOT) == b"first"
end

@testset "put_object_if_absent refuses an existing key with 412 and never overwrites" begin
    store = InMemoryObjectStore()
    put_object_if_absent(store, SLOT, b"first")
    @test put_object_if_absent(store, SLOT, b"second") == PutOutcome(false, 412)
    @test fetch_object(store, SLOT) == b"first"
end

@testset "put_object_if_absent and fetch_object never alias the store's bytes" begin
    store = InMemoryObjectStore()
    input = UInt8[1, 2, 3]
    put_object_if_absent(store, SLOT, input)
    input[1] = 9
    got = fetch_object(store, SLOT)
    @test got == UInt8[1, 2, 3]
    got[2] = 9
    @test fetch_object(store, SLOT) == UInt8[1, 2, 3]
end

@testset "fetch_object and stat_object of an absent key are nothing" begin
    store = InMemoryObjectStore()
    @test fetch_object(store, SLOT) === nothing
    @test stat_object(store, SLOT) === nothing
end

@testset "InMemoryObjectStore fault before a request throws out of the verb" begin
    store = InMemoryObjectStore()
    store.fault = (verb, key, phase) -> phase === :before && verb === :fetch_object &&
        error("simulated transport failure on $key")
    message = "simulated transport failure on $SLOT"
    @test_throws ErrorException message fetch_object(store, SLOT)
    @test stat_object(store, SLOT) === nothing
end

@testset "InMemoryObjectStore fault after a put loses the reply, and the put landed" begin
    store = InMemoryObjectStore()
    store.fault = (verb, key, phase) ->
    phase === :after && verb === :put_object_if_absent && error("response dropped")
    @test_throws ErrorException "response dropped" put_object_if_absent(
        store, SLOT, b"landed"
    )
    store.fault = (verb, key, phase) -> nothing
    @test fetch_object(store, SLOT) == b"landed"
    @test put_object_if_absent(store, SLOT, b"again").created == false
end

@testset "stat_object reports the size and a whole-second modified from the clock" begin
    clock = Ref{Int64}(1_700_000_000)
    store = InMemoryObjectStore(; clock = () -> clock[])
    put_object_if_absent(store, "p/000000000000", zeros(UInt8, 7))
    put_object_if_absent(store, "p/000000000001", zeros(UInt8, 3))
    at = 1_700_000_000
    @test stat_object(store, "p/000000000000") == ObjectMeta("p/000000000000", 7, at)
    @test stat_object(store, "p/000000000001") == ObjectMeta("p/000000000001", 3, at)
    clock[] += 1
    put_object_if_absent(store, "p/000000000002", UInt8[])
    @test stat_object(store, "p/000000000002").modified == 1_700_000_001
end

@testset "InMemoryObjectStore's default clock is whole seconds since the epoch" begin
    store = InMemoryObjectStore()
    before = floor(Int64, time())
    put_object_if_absent(store, "k", b"x")
    modified = stat_object(store, "k").modified
    @test modified isa Int64
    @test before <= modified <= floor(Int64, time())
end

const SLOTS = ["p/" * lpad(i, 12, '0') for i in 0:39]

"""
    seeded_store(seed)

A store holding the 40 `SLOTS`, `p/_reserved`, `q/000000000000` and `é/000000000000`.
"""
function seeded_store(seed)
    store = InMemoryObjectStore(; seed)
    foreach(key -> put_object_if_absent(store, key, b""), SLOTS)
    put_object_if_absent(store, "p/_reserved", b"")
    put_object_if_absent(store, "q/000000000000", b"")
    put_object_if_absent(store, "é/000000000000", b"")
    return store
end

listed_keys(store, prefix; start_after = nothing) =
    [meta.key for meta in list_objects(store, prefix; start_after)]

@testset "list_objects lists every key under a prefix, shuffled" begin
    store = seeded_store(7)
    listed = list_objects(store, "p/")
    @test listed isa Vector{ObjectMeta}
    in_order = vcat(SLOTS, ["p/_reserved"])
    @test sort([meta.key for meta in listed]) == in_order
    @test [meta.key for meta in listed] != in_order
    @test length(list_objects(store, "")) == 43
    @test isempty(list_objects(store, "z"))
end

@testset "list_objects with one seed gives one order" begin
    @test listed_keys(seeded_store(7), "p/") == listed_keys(seeded_store(7), "p/")
end

@testset "list_objects start_after is exclusive and compares bytes" begin
    store = seeded_store(7)
    # `_` (0x5F) sorts after every digit.
    tail = sort(listed_keys(store, "p/"; start_after = "p/000000000037"))
    @test tail == ["p/000000000038", "p/000000000039", "p/_reserved"]
    @test isempty(list_objects(store, "p/"; start_after = "p/_reserved"))
end

@testset "list_objects matches a prefix by bytes, half a code point too" begin
    store = seeded_store(7)
    @test listed_keys(store, String([0xc3])) == ["é/000000000000"]
    @test isempty(list_objects(store, "e"))
end

@testset "InMemoryObjectStore logs every request in order" begin
    store = InMemoryObjectStore()
    put_object_if_absent(store, "a", b"")
    fetch_object(store, "a")
    stat_object(store, "b")
    list_objects(store, "")
    expected = [
        (:put_object_if_absent, "a"), (:fetch_object, "a"), (:stat_object, "b"),
        (:list_objects, ""),
    ]
    @test store.calls == expected
end

@testset "put_attachment to an InMemoryObjectStore stores the bytes once" begin
    store = InMemoryObjectStore()
    io = IOBuffer(ATTACHMENT_BYTES)
    @test @inferred(put_attachment(store, ATTACHMENT_KEY, io)) == true
    @test store.objects[ATTACHMENT_KEY] == ATTACHMENT_BYTES
    @test put_attachment(store, ATTACHMENT_KEY, IOBuffer(ATTACHMENT_BYTES)) == false
end

@testset "put_attachment to an InMemoryObjectStore refuses bytes of another hash" begin
    store = InMemoryObjectStore()
    other = "p/_attachments/" * "0"^64
    message = "an InMemoryObjectStore answered BadDigest"
    @test_throws AttachmentChangedError message put_attachment(
        store, other, IOBuffer(ATTACHMENT_BYTES)
    )
    @test !haskey(store.objects, other)
end

@testset "put_attachment to an InMemoryObjectStore refuses a slot key" begin
    store = InMemoryObjectStore()
    message = "\"p/000000000001\" is not an attachment key"
    @test_throws ArgumentError message put_attachment(
        store, "p/000000000001", IOBuffer(ATTACHMENT_BYTES)
    )
end

@testset "put_attachment to an InMemoryObjectStore refuses an IO not at its start" begin
    store = InMemoryObjectStore()
    io = IOBuffer(ATTACHMENT_BYTES)
    read(io, UInt8)
    message = "an attachment's IO must stand at its start, not at byte 1"
    @test_throws ArgumentError message put_attachment(store, ATTACHMENT_KEY, io)
end

@testset "fetch_object_to from an InMemoryObjectStore writes a file, or nothing" begin
    store = InMemoryObjectStore()
    put_attachment(store, ATTACHMENT_KEY, IOBuffer(ATTACHMENT_BYTES))
    mktempdir() do dir
        path = joinpath(dir, "a")
        size = ChainTables.fetch_object_to(store, ATTACHMENT_KEY, path)
        @test size == length(ATTACHMENT_BYTES)
        @test read(path) == ATTACHMENT_BYTES
        absent = "p/_attachments/" * "0"^64
        @test ChainTables.fetch_object_to(store, absent, joinpath(dir, "b")) === nothing
        @test !ispath(joinpath(dir, "b"))
    end
    absent = "p/_attachments/" * "0"^64
    expected = [(:fetch_object_to, ATTACHMENT_KEY), (:fetch_object_to, absent)]
    @test store.calls[2:3] == expected
end

@testset "InMemoryObjectStore fault fires around put_attachment" begin
    store = InMemoryObjectStore()
    store.fault = (verb, key, phase) -> verb === :put_attachment && phase === :before &&
        error("injected")
    @test_throws ErrorException "injected" put_attachment(
        store, ATTACHMENT_KEY, IOBuffer(ATTACHMENT_BYTES)
    )
    @test !haskey(store.objects, ATTACHMENT_KEY)
end
