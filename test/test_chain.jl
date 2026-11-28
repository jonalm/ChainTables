using Test
using ChainTables: ChainTables, Chain, cache_namespace
using ChainTables.Testing: InMemoryObjectStore

include("fixtures/object_stores.jl")

const PORTABLE = "only a-z, 0-9, '.', '_' and '-' are portable to every filesystem"
const RESERVED = "which is reserved for a chain's attachments; a chain may not live " *
    "under one"
const REFUSED_PREFIXES = [
    (prefix = "/p", fragment = "prefix \"/p\" begins or ends with '/'"),
    (prefix = "p/", fragment = "prefix \"p/\" begins or ends with '/'"),
    (prefix = "a//b", fragment = "has the segment \"\", which is empty; each '/'-sep"),
    (prefix = "a"^101, fragment = "is 101 characters, over 100"),
    (prefix = "_attachments", fragment = "has the segment \"_attachments\", $RESERVED"),
    (prefix = "x/_attachments", fragment = "has the segment \"_attachments\", $RESERVED"),
    (prefix = "_attachments/y", fragment = "has the segment \"_attachments\", $RESERVED"),
    (prefix = "x/_attachments/y", fragment = "has the segment \"_attachments\", $RESERVED"),
    (prefix = ".", fragment = "the segment \".\", which names a directory relative to"),
    (prefix = "..", fragment = "the segment \"..\", which names a directory relative to"),
    (prefix = "a/./b", fragment = "the segment \".\", which names a directory relative to"),
    (prefix = "a/../b", fragment = "the segment \"..\", which names a directory relative"),
    (prefix = "a\\b", fragment = "segment \"a\\\\b\", which contains '\\\\'; $PORTABLE"),
    (prefix = "c:", fragment = "the segment \"c:\", which contains ':'; $PORTABLE"),
    (prefix = "a/c:x", fragment = "the segment \"c:x\", which contains ':'; $PORTABLE"),
    (prefix = "Exp", fragment = "the segment \"Exp\", which contains 'E'; $PORTABLE"),
    (prefix = "a b", fragment = "the segment \"a b\", which contains ' '; $PORTABLE"),
    (prefix = "a*", fragment = "the segment \"a*\", which contains '*'; $PORTABLE"),
    (prefix = "a?", fragment = "the segment \"a?\", which contains '?'; $PORTABLE"),
    (prefix = "a|b", fragment = "the segment \"a|b\", which contains '|'; $PORTABLE"),
    (prefix = "a<b>", fragment = "the segment \"a<b>\", which contains '<'; $PORTABLE"),
    (prefix = "a\"b", fragment = "the segment \"a\\\"b\", which contains '\"'; $PORTABLE"),
    (prefix = "é", fragment = "the segment \"é\", which contains 'é'; $PORTABLE"),
    (prefix = "a\0", fragment = "the segment \"a\\0\", which contains '\\0'; $PORTABLE"),
    (prefix = "a.", fragment = "the segment \"a.\", which ends with '.', which Windows"),
    (prefix = "a/b./c", fragment = "the segment \"b.\", which ends with '.', which"),
    (prefix = "...", fragment = "the segment \"...\", which ends with '.', which Windows"),
    (prefix = "con", fragment = "the segment \"con\", which is a Windows device name"),
    (prefix = "nul", fragment = "the segment \"nul\", which is a Windows device name"),
    (prefix = "a/aux/b", fragment = "the segment \"aux\", which is a Windows device name"),
    (prefix = "prn.txt", fragment = "\"prn.txt\", which is a Windows device name"),
    (prefix = "com1", fragment = "the segment \"com1\", which is a Windows device name"),
    (prefix = "lpt9.x.y", fragment = "\"lpt9.x.y\", which is a Windows device name"),
    (prefix = "com0", fragment = "the segment \"com0\", which is a Windows device name"),
]
const ACCEPTED_PREFIXES = [
    "", "a"^100, "a/.b/c..d/x-1_2", "console", "com10", "nul_", "con-x", ".hidden",
    "x/_attachments2/x_attachments",
]
const REFUSED_BUCKETS = [
    (bucket = "", fragment = "the bucket name is empty"),
    (bucket = "my.bucket", fragment = "bucket name \"my.bucket\" contains a dot"),
    (bucket = "Bkt", fragment = "bucket name \"Bkt\" contains 'B'; $PORTABLE"),
    (bucket = "nul", fragment = "bucket name \"nul\" is a Windows device name"),
]
const REFUSED_NAMESPACES = [
    (namespace = "Mem", fragment = "segment \"Mem\" of bucket \"bkt\", key"),
    (
        namespace = "n"^13,
        fragment = "of NamedStore is over 12 characters; its cache_namespace method " *
            "must return a shorter name",
    ),
    (
        namespace = "attachments",
        fragment = "the cache namespace \"attachments\" of NamedStore is the " *
            "attachment cache's directory; its cache_namespace method must return " *
            "another name",
    ),
]

# The longest name of a cache directory at the file system's root that still fits a
# record of the chain `bkt/` under it: Windows' 259, less the root, the namespace, the
# bucket, a separator and the 20 characters of a temporary file.
function longest_cache_name(store)
    below = "/$(cache_namespace(store))/bkt"
    return 259 - length(abspath("/")) - length(below) - 1 - 20
end

@testset "Chain holds location and configuration" begin
    store = InMemoryObjectStore()
    chain = @inferred Chain("bkt", "exp/run-7"; store, cache_dir = "/c")
    @test chain isa Chain{InMemoryObjectStore}
    @test (chain.bucket, chain.prefix) == ("bkt", "exp/run-7")
    @test chain.store === store
    @test chain.cache.dir == "/c"
    @test chain.read_ahead == 8
    @test !chain.assume_first_writer_wins
    @test chain.record_host
    @test chain.record_user
end

@testset "Chain performs no I/O" begin
    store = InMemoryObjectStore()
    Chain("bkt", "p"; store, cache_dir = "/c")
    @test isempty(store.calls)
end

@testset "Chain shows its location and the type of its store" begin
    chain = Chain("bkt", "exp/run-7"; store = InMemoryObjectStore(), cache_dir = "/c")
    @test sprint(show, chain) ==
        "Chain(\"bkt\", \"exp/run-7\"; store = InMemoryObjectStore)"
end

@testset "Chain takes its record cache from CHAINTABLES_CACHE_DIR, else the depot" begin
    store = InMemoryObjectStore()
    withenv("CHAINTABLES_CACHE_DIR" => "/elsewhere") do
        @test Chain("bkt", "p"; store).cache.dir == "/elsewhere"
    end
    withenv("CHAINTABLES_CACHE_DIR" => nothing) do
        @test Chain("bkt", "p"; store).cache.dir ==
            joinpath(first(DEPOT_PATH), "chaintables", "records")
    end
end

@testset "Chain accepts a portable prefix" begin
    store = InMemoryObjectStore()
    @testset "$(repr(prefix))" for prefix in ACCEPTED_PREFIXES
        @test Chain("bkt", prefix; store, cache_dir = "/c").prefix == prefix
    end
end

@testset "Chain refuses a prefix that is not portable" begin
    store = InMemoryObjectStore()
    @testset "$(repr(case.prefix))" for case in REFUSED_PREFIXES
        @test_throws ArgumentError case.fragment Chain("bkt", case.prefix; store)
    end
end

@testset "Chain refuses a bucket name that is not portable" begin
    store = InMemoryObjectStore()
    @testset "$(repr(case.bucket))" for case in REFUSED_BUCKETS
        @test_throws ArgumentError case.fragment Chain(case.bucket, "p"; store)
    end
end

@testset "Chain refuses a store whose cache namespace breaks a rule" begin
    @testset "$(case.namespace)" for case in REFUSED_NAMESPACES
        store = NamedStore(case.namespace)
        @test_throws ArgumentError case.fragment Chain("bkt", "p"; store)
    end
end

@testset "Chain keeps the longest record cache path within 259 UTF-16 code units" begin
    store = InMemoryObjectStore()
    root = abspath("/")
    n = longest_cache_name(store)
    @test Chain("bkt", ""; store, cache_dir = root * "c"^n).cache.dir == root * "c"^n
    too_long = "is 260 characters long with its temporary file, over the 259 Windows allows"
    one_more = root * "c"^(n + 1)
    @test_throws ArgumentError too_long Chain("bkt", ""; store, cache_dir = one_more)
    # One code point that is two UTF-16 code units.
    astral = root * "c"^(n - 1) * "😀"
    @test_throws ArgumentError too_long Chain("bkt", ""; store, cache_dir = astral)
    fits = root * "c"^n
    with_prefix = "is 261 characters long"
    @test_throws ArgumentError with_prefix Chain("bkt", "p"; store, cache_dir = fits)
end

@testset "Chain refuses to fetch no record ahead" begin
    store = InMemoryObjectStore()
    @test_throws ArgumentError "read_ahead is 0" Chain("bkt", "p"; store, read_ahead = 0)
end

@testset "Chain refuses a store that is no object store" begin
    @test_throws ArgumentError "store is a Int64, not an AbstractObjectStore" Chain(
        "bkt", "p"; store = 1
    )
end

@testset "Chain refuses a gateway together with a store" begin
    store = InMemoryObjectStore()
    both = "gateway and store were both given; a chain has one store"
    @test_throws ArgumentError both Chain("bkt", "p"; store, gateway = "https://gw")
end

@testset "Chain without a store needs credentials for the S3 client" begin
    withenv("AWS_ACCESS_KEY_ID" => nothing, "AWS_SECRET_ACCESS_KEY" => nothing) do
        unset = "AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY is not set"
        @test_throws ArgumentError unset Chain("bkt", "p"; region = "eu-north-1")
    end
end
