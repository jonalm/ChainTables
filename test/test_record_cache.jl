using Test
using ChainTables: ChainTables, AbstractObjectStore, Chain, cache_namespace, fetch_object,
    put_object_if_absent
using ChainTables.Testing: InMemoryObjectStore

# The record cache is internal; its tests call its functions, with a chain as the reader.
const CT = ChainTables
const KEY = "p/000000000001"

# A store that names its own namespace.
struct CacheTestNamed <: AbstractObjectStore
    namespace::String
end
ChainTables.cache_namespace(s::CacheTestNamed) = s.namespace

# Bytes whose write fails part-way, standing in for a crash mid-fetch.
struct CacheTestTruncated <: AbstractVector{UInt8}
    n::Int
    ok::Int
end
Base.size(v::CacheTestTruncated) = (v.n,)
function Base.getindex(v::CacheTestTruncated, i::Int)
    return i <= v.ok ? UInt8(i) : error("write interrupted at byte $i")
end

struct CacheTestInterrupted <: AbstractObjectStore end
ChainTables.cache_namespace(::CacheTestInterrupted) = "cut"
ChainTables.fetch_object(::CacheTestInterrupted, key) = CacheTestTruncated(20, 10)

function with_cached_chain(f; bucket = "bkt", store = InMemoryObjectStore())
    mktempdir() do dir
        f(Chain(bucket, "p"; store, cache_dir = dir), store, dir)
    end
    return nothing
end

@testset "default_cache_dir reads CHAINTABLES_CACHE_DIR, else the depot" begin
    withenv("CHAINTABLES_CACHE_DIR" => nothing) do
        depot = joinpath(first(DEPOT_PATH), "chaintables", "records")
        @test CT.default_cache_dir() == depot
        @test CT.RecordCache().dir == depot
    end
    withenv("CHAINTABLES_CACHE_DIR" => "/somewhere/else") do
        @test CT.RecordCache().dir == "/somewhere/else"
    end
end

@testset "record_path is namespace, bucket and the key's segments" begin
    path = CT.record_path(CT.RecordCache(; dir = "/c"), CacheTestNamed("other"), "bkt", KEY)
    @test path == joinpath("/c", "other", "bkt", "p", "000000000001")
end

const SEGMENT_CASES = [
    (name = "empty segment", bucket = "bkt", key = "p//1", msg = "segment \"\" of"),
    (name = "leading slash", bucket = "bkt", key = "/p", msg = "segment \"\" of"),
    (name = "empty bucket", bucket = "", key = "p", msg = "segment \"\" of bucket \"\""),
    (name = "parent", bucket = "bkt", key = "../p", msg = "names a directory relative"),
    (
        name = "drive",
        bucket = "bkt",
        key = "C:/p",
        msg = "\"C:\" of bucket \"bkt\", key \"C:/p\" contains 'C'",
    ),
    (name = "backslash", bucket = "bkt", key = "a\\b/1", msg = "contains '\\\\'"),
    (name = "device", bucket = "bkt", key = "con/1", msg = "is a Windows device name"),
]

@testset "record_path refuses a key: $(case.name)" for case in SEGMENT_CASES
    cache = CT.RecordCache(; dir = "/c")
    store = CacheTestNamed("other")
    @test_throws ArgumentError case.msg CT.record_path(cache, store, case.bucket, case.key)
end

const NAMESPACE_CASES = [
    (
        name = "uppercase",
        namespace = "Mem",
        msg = "segment \"Mem\" of bucket \"bkt\", key \"p\" contains 'M'",
    ),
    (name = "too long", namespace = "n"^13, msg = "of $CacheTestNamed is too long"),
    (
        name = "the attachment cache",
        namespace = "attachments",
        msg = "names the attachment cache",
    ),
]

@testset "record_path refuses a namespace: $(case.name)" for case in NAMESPACE_CASES
    cache = CT.RecordCache(; dir = "/c")
    store = CacheTestNamed(case.namespace)
    @test_throws ArgumentError case.msg CT.record_path(cache, store, "bkt", "p")
end

@testset "record_path refuses a path longer than Windows allows" begin
    cache = CT.RecordCache(; dir = "/" * "c"^228)
    msg = "is 260 characters long with its temporary file, over the 259 Windows allows"
    store = CacheTestNamed("other")
    @test_throws ArgumentError msg CT.record_path(cache, store, "bkt", "1")
end

@testset "fetch_record caches a hit and never a miss" begin
    with_cached_chain() do chain, store, dir
        @test CT.fetch_record(chain, KEY) == (nothing, false)
        @test !ispath(joinpath(dir, cache_namespace(store), "bkt"))
        put_object_if_absent(store, KEY, b"record one")
        @test CT.fetch_record(chain, KEY) == (b"record one", false)
        @test CT.fetch_record(chain, KEY) == (b"record one", true)
        @test store.calls ==
            [(:fetch_object, KEY), (:put_object_if_absent, KEY), (:fetch_object, KEY)]
        path = CT.record_path(chain, KEY)
        @test readdir(dirname(path)) == ["000000000001"]       # no temporary file left
    end
end

@testset "fetch_record keys the cache by bucket" begin
    store = InMemoryObjectStore()
    put_object_if_absent(store, KEY, b"record one")
    with_cached_chain(; store) do chain, store, dir
        other = Chain("other", "p"; store, cache_dir = dir)
        CT.fetch_record(chain, KEY)
        @test CT.fetch_record(other, KEY) == (b"record one", false)
        @test CT.record_path(chain, KEY) != CT.record_path(other, KEY)
    end
end

@testset "fetch_record keys the cache by store" begin
    a, b = InMemoryObjectStore(), InMemoryObjectStore()
    put_object_if_absent(a, KEY, b"from a")
    put_object_if_absent(b, KEY, b"from b")
    with_cached_chain(; store = a) do chain_a, a, dir
        chain_b = Chain("bkt", "p"; store = b, cache_dir = dir)
        @test first(CT.fetch_record(chain_a, KEY)) == b"from a"
        @test first(CT.fetch_record(chain_b, KEY)) == b"from b"
        @test CT.fetch_record(chain_a, KEY) == (b"from a", true)
    end
end

@testset "fetch_record caches nothing when the fetch fails" begin
    with_cached_chain() do chain, store, dir
        put_object_if_absent(store, KEY, b"record one")
        store.fault = (verb, k, phase) -> verb === :fetch_object && error("transport down")
        @test_throws ErrorException "transport down" CT.fetch_record(chain, KEY)
        @test !ispath(joinpath(dir, cache_namespace(store), "bkt"))
    end
end

@testset "fetch_record leaves nothing of a write that dies part-way" begin
    with_cached_chain(; store = CacheTestInterrupted()) do chain, store, dir
        msg = "write interrupted at byte 11"
        @test_throws ErrorException msg CT.fetch_record(chain, KEY)
        @test isempty(readdir(joinpath(dir, "cut", "bkt", "p")))
    end
end

@testset "fetch_record returns the file's bytes, which the caller owns" begin
    with_cached_chain() do chain, store, dir
        put_object_if_absent(store, KEY, b"record one")
        CT.fetch_record(chain, KEY)
        write(CT.record_path(chain, KEY), b"damaged")
        # a hit is not asked of the store
        @test CT.fetch_record(chain, KEY) == (b"damaged", true)
        got = first(CT.fetch_record(chain, KEY))
        got[1] = 0x00
        @test read(CT.record_path(chain, KEY)) == b"damaged"
    end
end

@testset "heal_record! fills an absent file and replaces one that differs" begin
    with_cached_chain() do chain, store, dir
        path = CT.record_path(chain, KEY)
        @test (@test_logs CT.heal_record!(chain, KEY, b"record one")) === nothing
        @test read(path) == b"record one"
        write(path, b"damaged")
        @test (@test_logs CT.heal_record!(chain, KEY, b"record one")) === nothing
        @test read(path) == b"record one"
        @test readdir(dirname(path)) == ["000000000001"]
        @test isempty(store.calls)
    end
end

@testset "heal_record! leaves a file that holds the same bytes" begin
    with_cached_chain() do chain, store, dir
        path = CT.record_path(chain, KEY)
        CT.heal_record!(chain, KEY, b"record one")
        mtime0 = mtime(path)
        sleep(0.01)
        CT.heal_record!(chain, KEY, b"record one")
        @test mtime(path) == mtime0
    end
end
