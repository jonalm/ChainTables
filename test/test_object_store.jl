using Test
using ChainTables: ChainTables, Chain, Credentials, GatewayObjectStore, ObjectMeta,
    PutOutcome, S3ObjectStore, TransportError, cache_namespace, fetch_object,
    list_objects, put_object_if_absent, record_author, stat_object
using ChainTables.Testing: InMemoryObjectStore

include("fixtures/object_stores.jl")

const CREDENTIALS = Credentials("AKID", "SECRET", nothing)
const VERBS_WITHOUT_FALLBACK = [
    (name = "fetch_object", call = () -> fetch_object(BareStore(), "k")),
    (
        name = "put_object_if_absent",
        call = () -> put_object_if_absent(BareStore(), "k", b""),
    ),
    (name = "stat_object", call = () -> stat_object(BareStore(), "k")),
    (name = "list_objects", call = () -> list_objects(BareStore(), "")),
]
const AWS_PARTITIONS = [
    (region = "eu-north-1", namespace = "aws"),
    (region = "us-east-1", namespace = "aws"),
    (region = "cn-north-1", namespace = "aws-cn"),
    (region = "us-gov-west-1", namespace = "aws-us-gov"),
]

s3_store(; region = "eu-north-1", keywords...) =
    S3ObjectStore("bkt"; region, credentials = CREDENTIALS, keywords...)

function gateway_store(; keywords...)
    url = "https://abc.lambda-url.eu-north-1.on.aws"
    return GatewayObjectStore(
        "bkt", url; region = "eu-north-1", credentials = CREDENTIALS, keywords...
    )
end

@testset "PutOutcome holds what a put reported" begin
    outcome = @inferred PutOutcome(false, 412)
    @test !outcome.created
    @test outcome.status == 412
end

@testset "ObjectMeta holds key, size and time" begin
    meta = @inferred ObjectMeta("k", 3, 1_700_000_000)
    @test (meta.key, meta.size, meta.modified) == ("k", 3, 1_700_000_000)
end

@testset "a verb has no fallback" begin
    @testset "$(verb.name)" for verb in VERBS_WITHOUT_FALLBACK
        @test_throws MethodError "no method matching $(verb.name)" verb.call()
    end
end

@testset "the interface has no delete" begin
    @test !isdefined(ChainTables, :delete_object)
end

@testset "the verbs infer on the in-memory store" begin
    store = InMemoryObjectStore()
    Bytes, Text = Vector{UInt8}, String
    @test @inferred(put_object_if_absent(store, "k", b"x")) == PutOutcome(true, 200)
    @test Base.infer_return_type(fetch_object, (typeof(store), Text)) ==
        Union{Nothing, Bytes}
    @test Base.infer_return_type(stat_object, (typeof(store), Text)) ==
        Union{Nothing, ObjectMeta}
    @test @inferred(list_objects(store, "")) isa Vector{ObjectMeta}
end

@testset "cache_namespace must be defined by a store of your own" begin
    message = "BareStore does not define ChainTables.cache_namespace, the record " *
        "cache's directory for objects read through it. Define " *
        "ChainTables.cache_namespace(::BareStore) to return a portable name of at " *
        "most 12 characters that no other store holding different objects under the " *
        "same bucket and key returns"
    @test_throws ArgumentError message cache_namespace(BareStore())
    @test_throws ArgumentError message Chain("bkt", "p"; store = BareStore())
end

@testset "cache_namespace is one per AWS partition" begin
    @testset "$(case.region)" for case in AWS_PARTITIONS
        @test cache_namespace(s3_store(; case.region)) == case.namespace
    end
end

@testset "cache_namespace of an endpoint is a hash of its canonical form" begin
    minio = @inferred cache_namespace(s3_store(; endpoint = "http://localhost:9000"))
    @test occursin(r"^ep-[0-9a-f]{8}$", minio)
    other_spelling = s3_store(; endpoint = "HTTP://LocalHost:9000/", path_style = true)
    @test cache_namespace(other_spelling) == minio
    @test cache_namespace(s3_store(; endpoint = "http://localhost:9001")) != minio
    @test cache_namespace(s3_store(; endpoint = "https://localhost:9000")) != minio
    aws_url = "https://s3.eu-north-1.amazonaws.com"
    @test cache_namespace(s3_store(; endpoint = aws_url * ":443")) ==
        cache_namespace(s3_store(; endpoint = aws_url))
end

@testset "cache_namespace of a gateway store is that of its S3 client" begin
    @test cache_namespace(gateway_store()) == "aws"
    @test cache_namespace(gateway_store(; endpoint = "http://localhost:9000")) ==
        cache_namespace(s3_store(; endpoint = "http://localhost:9000"))
end

@testset "cache_namespace differs between two in-memory stores" begin
    a, b = InMemoryObjectStore(), InMemoryObjectStore()
    @test occursin(r"^mem-[0-9a-f]{8}$", @inferred cache_namespace(a))
    @test cache_namespace(a) != cache_namespace(b)
end

@testset "record_author reads USER, then USERNAME" begin
    store = InMemoryObjectStore()
    withenv("USER" => "ada", "USERNAME" => "grace") do
        @test record_author(store) == "ada"
    end
    withenv("USER" => nothing, "USERNAME" => "grace") do
        @test record_author(store) == "grace"
    end
    withenv("USER" => nothing, "USERNAME" => nothing) do
        @test record_author(store) === nothing
    end
    @test Base.infer_return_type(record_author, (typeof(store),)) == Union{Nothing, String}
end

@testset "TransportError shows its message and its status" begin
    @test sprint(showerror, TransportError("down"; status = 503)) ==
        "TransportError: down (HTTP 503)"
    @test sprint(showerror, TransportError("timeout")) == "TransportError: timeout"
end
