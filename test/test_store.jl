using Test
using ChainTables: ChainTables, AbstractObjectStore, Chain, ObjectMeta, PutOutcome,
    TransportError, cache_namespace, fetch_object, list_objects, put_object_if_absent,
    record_author, stat_object
using ChainTables.Testing: InMemoryObjectStore
using TestConventions: check_inferred

# A store that implements nothing: the port has no fallback.
struct StoreTestBare <: AbstractObjectStore end

@testset "PutOutcome and ObjectMeta hold what the store reported" begin
    @test PutOutcome(true, 200).created
    @test PutOutcome(false, 412).status == 412
    m = ObjectMeta("k", 3, 1_700_000_000)
    @test (m.key, m.size, m.modified) == ("k", 3, 1_700_000_000)
end

const PORT_CALLS = [
    (name = "fetch_object", call = () -> fetch_object(StoreTestBare(), "k")),
    (
        name = "put_object_if_absent",
        call = () -> put_object_if_absent(StoreTestBare(), "k", b""),
    ),
    (name = "stat_object", call = () -> stat_object(StoreTestBare(), "k")),
    (name = "list_objects", call = () -> list_objects(StoreTestBare(), "")),
]

@testset "the port has no fallback: $(case.name) on a bare store" for case in PORT_CALLS
    @test_throws MethodError "no method matching $(case.name)" case.call()
end

@testset "the port has no delete" begin
    @test !isdefined(ChainTables, :delete_object)
end

@testset "cache_namespace refuses a store that does not define it" begin
    msg = "StoreTestBare does not define ChainTables.cache_namespace"
    @test_throws ArgumentError msg cache_namespace(StoreTestBare())
    store = StoreTestBare()
    @test_throws ArgumentError msg Chain("bkt", "p"; store, cache_dir = "/c")
end

@testset "cache_namespace gives every in-memory store its own" begin
    a, b = InMemoryObjectStore(), InMemoryObjectStore()
    @test occursin(r"^mem-[0-9a-f]{8}$", cache_namespace(a))
    @test cache_namespace(a) != cache_namespace(b)
    @test length(cache_namespace(a)) <= ChainTables.MAX_NAMESPACE_LENGTH
end

const AUTHOR_CASES = [
    (name = "USER", env = ("USER" => "alice", "USERNAME" => "bob"), author = "alice"),
    (name = "USERNAME", env = ("USER" => nothing, "USERNAME" => "bob"), author = "bob"),
    (name = "neither", env = ("USER" => nothing, "USERNAME" => nothing), author = nothing),
    (name = "empty", env = ("USER" => "", "USERNAME" => nothing), author = nothing),
]

@testset "record_author reads the environment: $(case.name)" for case in AUTHOR_CASES
    @test withenv(() -> record_author(InMemoryObjectStore()), case.env...) == case.author
end

const RETRYABLE_CASES = [
    (name = "no answer", status = nothing, retryable = true),
    (name = "500", status = 500, retryable = true),
    (name = "502", status = 502, retryable = true),
    (name = "503", status = 503, retryable = true),
    (name = "504", status = 504, retryable = true),
    (name = "409", status = 409, retryable = true),
    (name = "429", status = 429, retryable = true),
    (name = "400", status = 400, retryable = false),
    (name = "403", status = 403, retryable = false),
    (name = "404", status = 404, retryable = false),
    (name = "412", status = 412, retryable = false),
    (name = "413", status = 413, retryable = false),
]

@testset "retryable: a TransportError with $(case.name)" for case in RETRYABLE_CASES
    e = TransportError("PUT https://gw/?key=p: refused"; case.status)
    @test ChainTables.retryable(e) == case.retryable
end

@testset "retryable: never an exception that is not a TransportError" begin
    @test !ChainTables.retryable(ErrorException("not a transport failure"))
end

@testset "the put is attempted four times, with three pauses" begin
    @test ChainTables.PUT_ATTEMPTS == 4
    @test length(ChainTables.PUT_BACKOFF_S) == 3
end

@testset "the port's verbs infer" begin
    store = InMemoryObjectStore()
    @test @inferred(PutOutcome(true, 200)) isa PutOutcome
    @test @inferred(ObjectMeta("k", 1, 2)) isa ObjectMeta
    @test @inferred(put_object_if_absent(store, "k", UInt8[1])) == PutOutcome(true, 200)
    check_inferred(Union{Nothing, Vector{UInt8}}, fetch_object, store, "k")
    check_inferred(Union{Nothing, ObjectMeta}, stat_object, store, "k")
    @test @inferred(list_objects(store, "k")) isa Vector{ObjectMeta}
    check_inferred(Union{Nothing, String}, record_author, store)
    @test @inferred(cache_namespace(store)) isa String
end
