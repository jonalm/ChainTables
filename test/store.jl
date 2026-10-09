# #34 steps 6, 7 — ADR-0010, ADR-0012, ADR-0002: the port's contract, record cache, galloping, the retry loop.
using ChainTables: AbstractObjectStore, PutOutcome, ObjectMeta,
    fetch_object, put_object_if_absent, stat_object, list_objects,
    RecordCache, default_cache_dir, record_path, fetch_record, heal_record!, cache_namespace, MAX_NAMESPACE_LENGTH,
    S3ObjectStore, GatewayObjectStore, Credentials
using ChainTables.Testing: InMemoryObjectStore

# A store that implements nothing: the port has no fallback, so every verb is a MethodError.
struct StoreTestBare <: AbstractObjectStore end

# A store that names its own record-cache namespace (ADR-0040).
struct StoreTestNamed <: AbstractObjectStore
    namespace::String
end
ChainTables.cache_namespace(s::StoreTestNamed) = s.namespace

# Bytes whose write fails part-way, standing in for a crash mid-fetch.
struct StoreTestTruncated <: AbstractVector{UInt8}
    n::Int
    ok::Int
end
Base.size(v::StoreTestTruncated) = (v.n,)
Base.getindex(v::StoreTestTruncated, i::Int) = i <= v.ok ? UInt8(i) : error("write interrupted at byte $i")
struct StoreTestInterrupted <: AbstractObjectStore
    inner::InMemoryObjectStore
end
ChainTables.cache_namespace(::StoreTestInterrupted) = "cut"
ChainTables.fetch_object(s::StoreTestInterrupted, key) =
    key == "p/000000000009" ? StoreTestTruncated(20, 10) : fetch_object(s.inner, key)

@testset "store" begin
    @testset "port value types" begin
        @test PutOutcome(true, 200).created
        @test PutOutcome(false, 412).status == 412
        m = ObjectMeta("k", 3, 1_700_000_000)
        @test (m.key, m.size, m.modified) == ("k", 3, 1_700_000_000)
    end

    @testset "the port has no fallback: an unimplemented store fails fast" begin
        @test_throws MethodError fetch_object(StoreTestBare(), "k")
        @test_throws MethodError put_object_if_absent(StoreTestBare(), "k", b"")
        @test_throws MethodError stat_object(StoreTestBare(), "k")
        @test_throws MethodError list_objects(StoreTestBare(), "")
        # and there is no delete verb to implement (ADR-0010)
        @test !isdefined(ChainTables, :delete_object)
    end

    @testset "retryable: no response, 5xx, 409 and 429; never another 4xx (ADR-0010, ADR-0028)" begin
        @test ChainTables.retryable(ChainTables.TransportError("no response"))
        for status in (500, 502, 503, 504, 409, 429)
            e = ChainTables.TransportError("PUT https://gw/?key=p%2F000000000001: HTTP $status"; status)
            @test ChainTables.retryable(e)
            @test sprint(showerror, e) == "TransportError: PUT https://gw/?key=p%2F000000000001: HTTP $status (HTTP $status)"
        end
        for status in (400, 403, 404, 412, 413)
            @test !ChainTables.retryable(ChainTables.TransportError("refused"; status))
        end
        @test !ChainTables.retryable(ErrorException("not a transport error"))
    end

    @testset "cache directory: CHAINTABLES_CACHE_DIR, else the depot (ADR-0019)" begin
        withenv("CHAINTABLES_CACHE_DIR" => nothing) do
            @test default_cache_dir() == joinpath(first(DEPOT_PATH), "chaintables", "records")
            @test RecordCache().dir == default_cache_dir()
        end
        withenv("CHAINTABLES_CACHE_DIR" => "/somewhere/else") do
            @test default_cache_dir() == "/somewhere/else"
            @test RecordCache().dir == "/somewhere/else"
        end
        # keyed by the store's namespace, bucket and key; the key's slashes are directories
        cache = RecordCache(; dir = "/c")
        bare = StoreTestNamed("other")
        @test record_path(cache, bare, "bkt", "p/000000000001") == joinpath("/c", "other", "bkt", "p", "000000000001")
        @test_throws "segment \"\" of bucket \"bkt\", key \"p//1\" is empty" record_path(cache, bare, "bkt", "p//1")
        @test_throws "segment \"\" of bucket \"bkt\", key \"/p\" is empty" record_path(cache, bare, "bkt", "/p")
        @test_throws "segment \"\" of bucket \"\", key \"p\" is empty" record_path(cache, bare, "", "p")
        @test_throws "segment \"..\" of bucket \"bkt\", key \"../p\" names a directory" record_path(cache, bare, "bkt", "../p")
        @test_throws "segment \"C:\" of bucket \"bkt\", key \"C:/p\" contains 'C'" record_path(cache, bare, "bkt", "C:/p")
        @test_throws "segment \"a\\\\b\" of bucket \"bkt\", key \"a\\\\b/1\" contains '\\\\'" record_path(cache, bare, "bkt", "a\\b/1")
        @test_throws "segment \"con\" of bucket \"bkt\", key \"con/1\" is a Windows device name" record_path(cache, bare, "bkt", "con/1")
        @test_throws "is 260 characters long with its temporary file" record_path(RecordCache(; dir = "/" * "c"^228), bare, "bkt", "000000000001")
        # the namespace is a segment like any other, and bounded, so the path budget holds (ADR-0034)
        @test_throws "segment \"Mem\" of bucket \"bkt\", key \"p\" contains 'M'" record_path(cache, StoreTestNamed("Mem"), "bkt", "p")
        @test_throws "StoreTestNamed is over 12 characters (ADR-0034, ADR-0040); its cache_namespace method must return a shorter name" record_path(cache, StoreTestNamed("n"^13), "bkt", "p")
    end

    @testset "record cache: one namespace per store that may hold other objects under one name (ADR-0040)" begin
        creds = Credentials("AKID", "SECRET", nothing)
        s3(; kw...) = S3ObjectStore("bkt"; region = "eu-north-1", credentials = creds, kw...)
        # AWS's own URL: one namespace per partition, whatever the region; bucket names are unique there
        @test cache_namespace(s3()) == "aws"
        @test cache_namespace(S3ObjectStore("bkt"; region = "us-east-1", credentials = creds)) == "aws"
        @test cache_namespace(S3ObjectStore("bkt"; region = "cn-north-1", credentials = creds)) == "aws-cn"
        @test cache_namespace(S3ObjectStore("bkt"; region = "us-gov-west-1", credentials = creds)) == "aws-us-gov"
        # an endpoint: hashed in canonical form, so spellings of one endpoint share a namespace and the path style does not matter
        minio = cache_namespace(s3(; endpoint = "http://localhost:9000"))
        @test occursin(r"^ep-[0-9a-f]{8}$", minio)
        @test cache_namespace(s3(; endpoint = "HTTP://LocalHost:9000/", path_style = true)) == minio
        @test cache_namespace(s3(; endpoint = "http://localhost:9001")) != minio
        @test cache_namespace(s3(; endpoint = "https://localhost:9000")) != minio
        @test cache_namespace(s3(; endpoint = "https://s3.eu-north-1.amazonaws.com:443")) ==
              cache_namespace(s3(; endpoint = "https://s3.eu-north-1.amazonaws.com"))
        # a gateway reads from S3 directly, so it shares S3's namespace for the same endpoint
        gw(; kw...) = GatewayObjectStore("bkt", "https://abc.lambda-url.eu-north-1.on.aws"; region = "eu-north-1",
                                         credentials = creds, kw...)
        @test cache_namespace(gw()) == "aws"
        @test cache_namespace(gw(; endpoint = "http://localhost:9000")) == minio
        # every in-memory store is its own; any other store must name its own, and a chain over one that does not is refused
        a, b = InMemoryObjectStore(), InMemoryObjectStore()
        @test occursin(r"^mem-[0-9a-f]{8}$", cache_namespace(a)) && cache_namespace(a) != cache_namespace(b)
        msg = "cache_namespace: StoreTestBare does not define ChainTables.cache_namespace, the record cache's directory " *
            "for objects read through it. Define ChainTables.cache_namespace(::StoreTestBare) to return a portable name " *
            "of at most 12 characters that no other store holding different objects under the same bucket and key " *
            "returns (ADR-0040)"
        @test_throws msg cache_namespace(StoreTestBare())
        @test_throws msg ChainTables.Chain("bkt", "p"; store = StoreTestBare(), cache_dir = "/c")
        @test all(length(cache_namespace(s)) <= MAX_NAMESPACE_LENGTH
                  for s in (a, s3(), s3(; endpoint = "http://localhost:9000"),
                            S3ObjectStore("bkt"; region = "us-gov-west-1", credentials = creds)))
        # so the same bucket and key through two stores are two files
        mktempdir() do dir
            cache = RecordCache(; dir)
            put_object_if_absent(a, "p/000000000001", b"from a")
            put_object_if_absent(b, "p/000000000001", b"from b")
            @test fetch_record(cache, a, "bkt", "p/000000000001") == b"from a"
            @test fetch_record(cache, b, "bkt", "p/000000000001") == b"from b"
            @test fetch_record(cache, a, "bkt", "p/000000000001") == b"from a"
            @test record_path(cache, a, "bkt", "p/000000000001") != record_path(cache, b, "bkt", "p/000000000001")
        end
    end

    @testset "record cache: fetch to temp then rename; misses are never memoized" begin
        mktempdir() do dir
            cache = RecordCache(; dir)
            store = InMemoryObjectStore()
            key = "p/000000000001"
            # absent: nothing, no file, and the store is asked again next time
            @test fetch_record(cache, store, "bkt", key) === nothing
            @test !ispath(joinpath(dir, cache_namespace(store), "bkt"))
            put_object_if_absent(store, key, b"record one")
            @test fetch_record(cache, store, "bkt", key) == b"record one"
            @test store.calls == [(:fetch_object, key), (:put_object_if_absent, key), (:fetch_object, key)]
            path = record_path(cache, store, "bkt", key)
            @test read(path) == b"record one"
            @test readdir(dirname(path)) == ["000000000001"]     # no temp file left behind
            # hit: served from disk, the store not consulted
            @test fetch_record(cache, store, "bkt", key) == b"record one"
            @test length(store.calls) == 3
            # the bucket is part of the key: another bucket is a miss
            @test fetch_record(cache, store, "other", key) == b"record one"
            @test length(store.calls) == 4
            @test isfile(record_path(cache, store, "other", key))
        end
    end

    @testset "record cache: a failed fetch caches nothing; a truncated write is not cached" begin
        mktempdir() do dir
            cache = RecordCache(; dir)
            store = InMemoryObjectStore()
            key = "p/000000000001"
            put_object_if_absent(store, key, b"record one")
            store.fault = (verb, k, phase) -> verb === :fetch_object && error("transport down")
            @test_throws "transport down" fetch_record(cache, store, "bkt", key)
            @test !ispath(joinpath(dir, cache_namespace(store), "bkt"))
            store.fault = (verb, k, phase) -> nothing
            # a write that dies part-way leaves neither the record nor its temp file
            interrupted = StoreTestInterrupted(store)
            @test_throws "write interrupted at byte 11" fetch_record(cache, interrupted, "bkt", "p/000000000009")
            @test isempty(readdir(joinpath(dir, "cut", "bkt", "p")))
            # the next fetch is a plain miss and lands
            @test fetch_record(cache, store, "bkt", key) == b"record one"
        end
    end

    @testset "record cache: every read is the file's bytes, never a memo (ADR-0006, ADR-0013)" begin
        mktempdir() do dir
            cache = RecordCache(; dir)
            store = InMemoryObjectStore()
            key = "p/000000000001"
            put_object_if_absent(store, key, b"record one")
            @test fetch_record(cache, store, "bkt", key) == b"record one"
            # a hit is never asked of the store (ADR-0010), so a damaged file is what the caller
            # sees — and rehashes (ADR-0006, ADR-0040): the cache holds no second copy
            write(record_path(cache, store, "bkt", key), b"damaged")
            @test fetch_record(cache, store, "bkt", key) == b"damaged"
            @test length(store.calls) == 2
            # returned bytes are the caller's: mutating them changes nothing on disk
            got = fetch_record(cache, store, "bkt", key)
            got[1] = 0x00
            @test read(record_path(cache, store, "bkt", key)) == b"damaged"
        end
    end

    # what a caller does with the store's bytes once they pass the chain's check (ADR-0040)
    @testset "record cache: heal_record! replaces what differs, and only what differs" begin
        mktempdir() do dir
            cache = RecordCache(; dir)
            store = InMemoryObjectStore()
            key = "p/000000000001"
            path = record_path(cache, store, "bkt", key)
            # absent from the cache: filled, silently, and the store is not asked
            @test (@test_logs heal_record!(cache, store, "bkt", key, b"record one")) === nothing
            @test read(path) == b"record one"
            # the same bytes: nothing written, nothing said
            mtime0 = mtime(path)
            @test (@test_logs heal_record!(cache, store, "bkt", key, b"record one")) === nothing
            @test mtime(path) == mtime0
            # other bytes on disk: replaced, with a warning naming the file
            write(path, b"damaged")
            @test (@test_logs (:warn, "record cache: the cached copy of $key in bucket bkt is not what the store holds; " *
                "replaced with the store's bytes (ADR-0040)") heal_record!(cache, store, "bkt", key, b"record one")) === nothing
            @test read(path) == b"record one" && readdir(dirname(path)) == ["000000000001"]
            @test isempty(store.calls)
        end
    end
end
