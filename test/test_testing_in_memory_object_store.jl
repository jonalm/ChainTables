using Test
using ChainTables: ChainTables, AbstractObjectStore, AttachmentChangedError, ObjectMeta,
    PutOutcome, attachment, fetch_object, list_objects, put_attachment,
    put_object_if_absent, stat_object
using ChainTables.Testing: InMemoryObjectStore

include("fixtures/attachments.jl")
include("fixtures/chain_copies.jl")

const KEY = "p/000000000000"
const KEYS = ["p/" * lpad(i, 12, '0') for i in 0:39]
const LISTED = [KEYS; "p/_reserved"]

# A fault hook that throws `message` at `phase` of each request of `verb`.
function failing_at(verb, phase, message)
    return (v, key, p) -> (v === verb && p === phase) && throw(ErrorException(message))
end

function stored_with_keys(seed)
    store = InMemoryObjectStore(; seed)
    foreach(key -> put_object_if_absent(store, key, b""), [LISTED; "q/000000000000"])
    put_object_if_absent(store, "é/000000000000", b"")
    return store
end

function listed_keys(store, prefix; keywords...)
    return [meta.key for meta in list_objects(store, prefix; keywords...)]
end

@testset "Testing holds the in-memory store and nothing else" begin
    @test names(ChainTables.Testing) == [:InMemoryObjectStore, :Testing]
    @test Base.isexported(ChainTables.Testing, :InMemoryObjectStore) == false
    @test @inferred(InMemoryObjectStore()) isa AbstractObjectStore
end

@testset "put_object_if_absent on the in-memory store creates a key once" begin
    store = InMemoryObjectStore()
    @test put_object_if_absent(store, KEY, b"first") == PutOutcome(true, 200)
    @test fetch_object(store, KEY) == b"first"
    @test put_object_if_absent(store, KEY, b"second") == PutOutcome(false, 412)
    @test fetch_object(store, KEY) == b"first"
end

@testset "put_object_if_absent on the in-memory store keeps its own copy of the bytes" begin
    store = InMemoryObjectStore()
    input = UInt8[1, 2, 3]
    put_object_if_absent(store, KEY, input)
    input[1] = 9
    fetched = fetch_object(store, KEY)
    @test fetched == UInt8[1, 2, 3]
    fetched[2] = 9
    @test fetch_object(store, KEY) == UInt8[1, 2, 3]
end

@testset "fetch_object on the in-memory store tells absent from a failure" begin
    store = InMemoryObjectStore()
    @test fetch_object(store, KEY) === nothing
    @test stat_object(store, KEY) === nothing
    store.fault = failing_at(:fetch_object, :before, "simulated failure")
    @test_throws ErrorException "simulated failure" fetch_object(store, KEY)
    @test stat_object(store, KEY) === nothing
end

@testset "put_object_if_absent on the in-memory store lands before a lost answer" begin
    store = InMemoryObjectStore()
    store.fault = failing_at(:put_object_if_absent, :after, "answer lost")
    @test_throws ErrorException "answer lost" put_object_if_absent(store, KEY, b"landed")
    store.fault = (verb, key, phase) -> nothing
    @test fetch_object(store, KEY) == b"landed"
end

@testset "stat_object on the in-memory store gives the size and whole seconds" begin
    clock = Ref{Int64}(1_700_000_000)
    store = InMemoryObjectStore(; clock = () -> clock[])
    put_object_if_absent(store, "p/a", zeros(UInt8, 7))
    put_object_if_absent(store, "p/b", zeros(UInt8, 3))
    clock[] += 1
    put_object_if_absent(store, "p/c", UInt8[])
    @test stat_object(store, "p/a") == ObjectMeta("p/a", 7, 1_700_000_000)
    @test stat_object(store, "p/b") == ObjectMeta("p/b", 3, 1_700_000_000)
    @test stat_object(store, "p/c").modified == 1_700_000_001
end

@testset "InMemoryObjectStore's default clock is whole seconds since the epoch" begin
    store = InMemoryObjectStore()
    before = floor(Int64, time())
    put_object_if_absent(store, KEY, b"x")
    @test before <= stat_object(store, KEY).modified <= floor(Int64, time())
end

@testset "list_objects on the in-memory store lists a prefix, never in order" begin
    store = stored_with_keys(7)
    @test sort(listed_keys(store, "p/")) == LISTED
    @test listed_keys(store, "p/") != LISTED
    @test length(list_objects(store, "")) == 43
    @test isempty(list_objects(store, "z"))
end

@testset "list_objects on the in-memory store compares start_after by bytes" begin
    store = stored_with_keys(7)
    tail = sort(listed_keys(store, "p/"; start_after = "p/000000000037"))
    @test tail == ["p/000000000038", "p/000000000039", "p/_reserved"]
    @test isempty(list_objects(store, "p/"; start_after = "p/_reserved"))
end

@testset "list_objects on the in-memory store matches half of a code point" begin
    store = stored_with_keys(7)
    @test listed_keys(store, String([0xc3])) == ["é/000000000000"]
    @test isempty(list_objects(store, "e"))
end

@testset "list_objects on the in-memory store repeats an order for one seed" begin
    @test listed_keys(stored_with_keys(7), "p/") == listed_keys(stored_with_keys(7), "p/")
end

@testset "InMemoryObjectStore records every request in order" begin
    store = InMemoryObjectStore()
    put_object_if_absent(store, "a", b"")
    fetch_object(store, "a")
    stat_object(store, "b")
    list_objects(store, "")
    @test store.calls == [
        (:put_object_if_absent, "a"), (:fetch_object, "a"), (:stat_object, "b"),
        (:list_objects, ""),
    ]
end

@testset "put_attachment on the in-memory store stores the bytes once" begin
    mktempdir() do dir
        chain = chain_in(dir)
        h = put_attachment(chain, IOBuffer(b"an attachment"))
        put_attachment(chain, IOBuffer(b"an attachment"))
        @test chain.store.objects["p/_attachments/$h"] == b"an attachment"
        @test chain.store.calls == fill((:put_attachment, "p/_attachments/$h"), 2)
    end
end

@testset "put_attachment on the in-memory store refuses bytes that changed" begin
    mktempdir() do dir
        path = joinpath(dir, "a.bin")
        write(path, "the bytes hashed")
        fault = (verb, key, phase) -> verb === :put_attachment && write(path, "others!!")
        chain = chain_in(dir; store = InMemoryObjectStore(; fault))
        fragment = "the file changed between hashing and upload"
        err = @test_throws AttachmentChangedError fragment put_attachment(chain, path)
        @test err.value.key == "p/_attachments/$(sha256_hex(b"the bytes hashed"))"
        @test isempty(chain.store.objects)
    end
end

@testset "put_attachment on the in-memory store passes through the fault hook" begin
    mktempdir() do dir
        fault = failing_at(:put_attachment, :before, "injected")
        chain = chain_in(dir; store = InMemoryObjectStore(; fault))
        @test_throws ErrorException "injected" put_attachment(chain, IOBuffer(b"x"))
        @test isempty(chain.store.objects)
    end
end

@testset "attachment on the in-memory store fetches the bytes to a file" begin
    with_chain_copy() do local_copy
        h = put_attachment(local_copy.chain, IOBuffer(b"an attachment"))
        empty!(local_copy.chain.store.calls)
        @test read(attachment(local_copy, h)) == b"an attachment"
        @test local_copy.chain.store.calls == [(:fetch_object_to, "p/_attachments/$h")]
    end
end
