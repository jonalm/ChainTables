# #34 steps 6, 7 — ADR-0010, ADR-0012, ADR-0002: the port's contract, record cache, galloping, the retry loop.
using ChainTables: AbstractObjectStore, PutOutcome, ObjectMeta,
    fetch_object, put_object_if_absent, stat_object, list_objects,
    RecordCache, default_cache_dir, record_path, fetch_record
using ChainTables.Testing: InMemoryObjectStore

# A store that implements nothing: the port has no fallback, so every verb is a MethodError.
struct StoreTestBare <: AbstractObjectStore end

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
        # keyed by bucket and key; the key's slashes are directories
        cache = RecordCache(; dir = "/c")
        @test record_path(cache, "bkt", "p/000000000001") == joinpath("/c", "bkt", "p", "000000000001")
        @test_throws "empty segment" record_path(cache, "bkt", "p//1")
        @test_throws "empty segment" record_path(cache, "bkt", "/p")
        @test_throws "empty segment" record_path(cache, "", "p")
        @test_throws ".." record_path(cache, "bkt", "../p")
    end

    @testset "record cache: fetch to temp then rename; misses are never memoized" begin
        mktempdir() do dir
            cache = RecordCache(; dir)
            store = InMemoryObjectStore()
            key = "p/000000000001"
            # absent: nothing, no file, and the store is asked again next time
            @test fetch_record(cache, store, "bkt", key) === nothing
            @test !ispath(joinpath(dir, "bkt"))
            put_object_if_absent(store, key, b"record one")
            @test fetch_record(cache, store, "bkt", key) == b"record one"
            @test store.calls == [(:fetch_object, key), (:put_object_if_absent, key), (:fetch_object, key)]
            path = record_path(cache, "bkt", key)
            @test read(path) == b"record one"
            @test readdir(dirname(path)) == ["000000000001"]     # no temp file left behind
            # hit: served from disk, the store not consulted
            @test fetch_record(cache, store, "bkt", key) == b"record one"
            @test length(store.calls) == 3
            # the bucket is part of the key: another bucket is a miss
            @test fetch_record(cache, store, "other", key) == b"record one"
            @test length(store.calls) == 4
            @test isfile(record_path(cache, "other", key))
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
            @test !ispath(joinpath(dir, "bkt"))
            store.fault = (verb, k, phase) -> nothing
            # a write that dies part-way leaves neither the record nor its temp file
            interrupted = StoreTestInterrupted(store)
            @test_throws "write interrupted at byte 11" fetch_record(cache, interrupted, "bkt", "p/000000000009")
            @test isempty(readdir(joinpath(dir, "bkt", "p")))
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
            # the cache never re-validates against the store (ADR-0010), so a damaged file is
            # what the caller sees — and rehashes (ADR-0006): the cache holds no second copy
            write(record_path(cache, "bkt", key), b"damaged")
            @test fetch_record(cache, store, "bkt", key) == b"damaged"
            @test length(store.calls) == 2
            # returned bytes are the caller's: mutating them changes nothing on disk
            got = fetch_record(cache, store, "bkt", key)
            got[1] = 0x00
            @test read(record_path(cache, "bkt", key)) == b"damaged"
        end
    end
end
