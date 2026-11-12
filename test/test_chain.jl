using Test
using ChainTables: ChainTables, Chain, cache_namespace, create_chain, put_object_if_absent
using ChainTables.Testing: InMemoryObjectStore

include("fixtures/chains.jl")

const CT = ChainTables

@testset "Chain holds location and configuration, and does no I/O" begin
    store = InMemoryObjectStore()
    chain = Chain("bkt", "exp/run-7"; store, cache_dir = "/c", region = "eu-north-1")
    @test chain isa Chain{InMemoryObjectStore}
    @test (chain.bucket, chain.prefix, chain.region) == ("bkt", "exp/run-7", "eu-north-1")
    @test chain.read_ahead == 8 && !chain.assume_first_writer_wins && !chain.path_style
    @test chain.endpoint === nothing && chain.credentials === nothing
    @test chain.record_host && chain.record_user
    @test chain.cache.dir == "/c"
    @test isempty(store.calls)
end

@testset "Chain reads the cache directory from the environment" begin
    withenv("CHAINTABLES_CACHE_DIR" => "/elsewhere") do
        @test Chain("bkt", "p"; store = InMemoryObjectStore()).cache.dir == "/elsewhere"
    end
end

@testset "Chain shows its location and store, never its credentials" begin
    chain = Chain("bkt", "exp/run-7"; store = InMemoryObjectStore())
    shown = "Chain(\"bkt\", \"exp/run-7\"; store = InMemoryObjectStore)"
    @test sprint(show, chain) == shown
end

@testset "slot_key is the prefix and 12 digits" begin
    store = InMemoryObjectStore()
    @test CT.slot_key(Chain("bkt", "exp/run-7"; store), 7) == "exp/run-7/000000000007"
    @test CT.slot_key(Chain("bkt", ""; store), 7) == "000000000007"
end

const BAD_BUCKETS = [
    (name = "dot", bucket = "my.bucket", msg = "bucket name \"my.bucket\" contains a dot"),
    (name = "empty", bucket = "", msg = "the bucket name is empty"),
    (name = "uppercase", bucket = "Bkt", msg = "bucket name \"Bkt\" contains 'B'"),
    (name = "device", bucket = "nul", msg = "bucket name \"nul\" is a Windows device name"),
]

@testset "Chain refuses a bucket name: $(case.name)" for case in BAD_BUCKETS
    store = InMemoryObjectStore()
    @test_throws ArgumentError case.msg Chain(case.bucket, "p"; store)
end

const PORTABLE = "only a-z, 0-9, '.', '_' and '-' are portable to every filesystem"
const RESERVED = "which is reserved for a chain's attachments"

const BAD_PREFIXES = [
    (prefix = "/p", msg = "prefix \"/p\" begins or ends with '/'"),
    (prefix = "p/", msg = "prefix \"p/\" begins or ends with '/'"),
    (prefix = "a//b", msg = "has the segment \"\", which is empty"),
    (prefix = "_attachments", msg = RESERVED),
    (prefix = "x/_attachments", msg = RESERVED),
    (prefix = "x/_attachments/y", msg = RESERVED),
    (
        prefix = ".",
        msg = "the segment \".\", which names a directory relative to its parent",
    ),
    (prefix = "a/../b", msg = "the segment \"..\", which names a directory relative"),
    (prefix = "a\\b", msg = "the segment \"a\\\\b\", which contains '\\\\'; $PORTABLE"),
    (prefix = "a/c:x", msg = "the segment \"c:x\", which contains ':'"),
    (prefix = "Exp", msg = "contains 'E'"),
    (prefix = "a b", msg = "contains ' '"),
    (prefix = "a*", msg = "contains '*'"),
    (prefix = "a<b>", msg = "contains '<'"),
    (prefix = "é", msg = "contains 'é'"),
    (prefix = "a\0", msg = "contains '\\0'"),
    (
        prefix = "a/b./c",
        msg = "the segment \"b.\", which ends with '.', which Windows strips",
    ),
    (prefix = "...", msg = "ends with '.'"),
    (prefix = "con", msg = "the segment \"con\", which is a Windows device name"),
    (prefix = "a/aux/b", msg = "is a Windows device name"),
    (prefix = "prn.txt", msg = "is a Windows device name"),
    (prefix = "lpt9.x.y", msg = "is a Windows device name"),
    (prefix = "com0", msg = "is a Windows device name"),
    (prefix = "a"^101, msg = "is 101 characters, over 100"),
]

@testset "Chain refuses the prefix $(repr(case.prefix))" for case in BAD_PREFIXES
    store = InMemoryObjectStore()
    @test_throws ArgumentError case.msg Chain("bkt", case.prefix; store)
end

const GOOD_PREFIXES = [
    "a/.b/c..d/x-1_2", "console", "com10", "nul_", "con-x", ".hidden",
    "x/_attachments2/x_attachments", "a"^100, "",
]

@testset "Chain takes the prefix $(repr(prefix))" for prefix in GOOD_PREFIXES
    @test Chain("bkt", prefix; store = InMemoryObjectStore()).prefix == prefix
end

@testset "Chain holds the longest cache path to 259 UTF-16 code units" begin
    store = InMemoryObjectStore()
    root = abspath("/")
    # The longest cache_dir name for prefix "": the 12-digit name loses to the temp file.
    fits = 259 - length(root) - length("/$(cache_namespace(store))/bkt") - 1 - 20
    @test Chain("bkt", ""; store, cache_dir = root * "c"^fits).cache.dir == root * "c"^fits
    over = root * "c"^(fits + 1)
    msg = "is 260 characters long"
    @test_throws ArgumentError msg Chain("bkt", ""; store, cache_dir = over)
    wide = root * "c"^(fits - 1) * "😀"
    msg = "is 260 characters long"
    @test_throws ArgumentError msg Chain("bkt", ""; store, cache_dir = wide)
    long = root * "c"^fits
    msg = "is 261 characters long"
    @test_throws ArgumentError msg Chain("bkt", "p"; store, cache_dir = long)
end

@testset "Chain refuses a bad read_ahead, store, or store combination" begin
    store = InMemoryObjectStore()
    msg = "read_ahead must be ≥ 1, got 0"
    @test_throws ArgumentError msg Chain("bkt", "p"; store, read_ahead = 0)
    msg = "store is a Int64, not an AbstractObjectStore"
    @test_throws ArgumentError msg Chain("bkt", "p"; store = 1)
    gateway = "https://abc.lambda-url.eu-north-1.on.aws"
    msg = "give gateway or store, not both"
    @test_throws ArgumentError msg Chain("bkt", "p"; store, gateway)
    msg = "record_user = false with a gateway"
    @test_throws ArgumentError msg Chain("bkt", "p"; gateway, record_user = false)
end

@testset "Chain with no store needs credentials for the S3 client" begin
    withenv("AWS_ACCESS_KEY_ID" => nothing, "AWS_SECRET_ACCESS_KEY" => nothing) do
        msg = "AWS_ACCESS_KEY_ID"
        @test_throws ArgumentError msg Chain("bkt", "p"; region = "eu-north-1")
    end
end

@testset "Chain infers" begin
    store = InMemoryObjectStore()
    chain = @inferred Chain("bkt", "p"; store, cache_dir = "/c")
    @test chain isa Chain{InMemoryObjectStore}
end

# gallop's probes are visible only on the store's calls; sync! adds its own fetches.
@testset "gallop finds the head in a logarithmic number of stat probes" begin
    store = InMemoryObjectStore()
    chain = Chain("bkt", "p"; store, cache_dir = "/c")
    @test CT.gallop(chain, -1) == -1 && store.calls == [(:stat_object, slotkey(0))]
    foreach(s -> put_object_if_absent(store, slotkey(s), UInt8[]), 0:999)
    empty!(store.calls)
    @test CT.gallop(chain, -1) == 999
    @test length(store.calls) <= 2 * ceil(Int, log2(1001)) + 1
    @test unique(first.(store.calls)) == [:stat_object]
    @test store.calls[1:4] == [(:stat_object, slotkey(s)) for s in (0, 1, 3, 7)]
    empty!(store.calls)
    @test CT.gallop(chain, 999) == 999 && store.calls == [(:stat_object, slotkey(1000))]
    empty!(store.calls)
    @test CT.gallop(chain, 990) == 999
    @test length(store.calls) <= 2 * ceil(Int, log2(10)) + 1
end

const GALLOP_CASES = [
    (name = "from nothing", top = 5, lo = -1),
    (name = "from the middle", top = 5, lo = 2),
    (name = "from the head", top = 5, lo = 5),
    (name = "a lone slot 0", top = 0, lo = -1),
]

@testset "gallop finds the head exactly: $(case.name)" for case in GALLOP_CASES
    store = InMemoryObjectStore()
    foreach(s -> put_object_if_absent(store, slotkey(s), UInt8[]), 0:case.top)
    @test CT.gallop(Chain("bkt", "p"; store, cache_dir = "/c"), case.lo) == case.top
end

@testset "expected_chain_id is slot 0's chain id, from the record cache only" begin
    mktempdir() do dir
        store = InMemoryObjectStore()
        chain = Chain("bkt", "p"; store, cache_dir = joinpath(dir, "cache"))
        created = create_chain(chain)
        @test CT.expected_chain_id(chain) == created.chain_id
        cold = Chain("bkt", "p"; store, cache_dir = joinpath(dir, "cold"))
        @test CT.expected_chain_id(cold) === nothing
        write(CT.record_path(chain, slotkey(0)), b"not a record")
        @test CT.expected_chain_id(chain) === nothing
    end
end
