using Test
using ChainTables: ChainTables, AttachmentAbsentError, AttachmentCacheError,
    AttachmentDigestError, Chain, GatewayObjectStore, TransportError, attachment,
    put_attachment
using SHA: sha256
using StableRNGs: StableRNG

include("fixtures/attachments.jl")
include("fixtures/s3_server.jl")
include("fixtures/gateway_double.jl")

const BYTES = rand(StableRNG(5), UInt8, 5000)
const HASH = bytes2hex(sha256(BYTES))
const KEY = "p/_attachments/$HASH"

cache_path(dir, hash) = joinpath(dir, "cache", "attachments", hash[1:2], hash)
is_confirmed(copy, hash) = isfile(joinpath(copy.path, "confirmed", hash))

"""
    with_cached_attachment(f)

Call `f(t)` with `t = (; store, chain, copy, path, dir)`: a chain holding `BYTES` as an
attachment, a synced local copy that has read it once, and its file in the cache.
"""
function with_cached_attachment(f)
    mktempdir() do dir
        (; store, chain, copy) = created_chain(dir)
        put_attachment(chain, IOBuffer(BYTES))
        path = attachment(copy, HASH)
        empty!(store.calls)
        f((; store, chain, copy, path, dir))
    end
    return nothing
end

@testset "attachment refuses a copy with no head before any request" begin
    mktempdir() do dir
        (; store, chain) = created_chain(dir)
        fresh = ChainTables.open(chain, joinpath(dir, "fresh"))
        empty!(store.calls)
        @test_throws ArgumentError "has no head yet" attachment(fresh, HASH)
        @test isempty(store.calls)
    end
end

@testset "attachment refuses a hash that is not 64 lowercase hex before any request" begin
    mktempdir() do dir
        (; store, copy) = created_chain(dir)
        empty!(store.calls)
        message = "$(repr(uppercase(HASH))) is not an attachment hash"
        @test_throws ArgumentError message attachment(copy, uppercase(HASH))
        @test isempty(store.calls)
    end
end

@testset "attachment of a miss fetches into the cache once and confirms it" begin
    mktempdir() do dir
        (; store, chain, copy) = created_chain(dir)
        put_attachment(chain, IOBuffer(BYTES))
        empty!(store.calls)
        path = @inferred attachment(copy, HASH)
        @test path == cache_path(dir, HASH)
        @test read(path) == BYTES
        @test store.calls == [(:fetch_object_to, KEY)]
        @test is_confirmed(copy, HASH)
    end
end

@testset "attachment leaves a read-only file, its sidecar and no temporary file" begin
    with_cached_attachment() do t
        @test filemode(t.path) & 0o222 == 0
        st = stat(t.path)
        @test read(t.path * ".meta", String) == "$(st.size) $(st.mtime)"
        @test sort(readdir(dirname(t.path))) == [HASH, HASH * ".meta"]
    end
end

@testset "attachment of a confirmed hit makes no request, after a reopen too" begin
    with_cached_attachment() do t
        @test attachment(t.copy, HASH) == t.path
        close(t.copy)
        reopened = ChainTables.open(t.chain, t.copy.path)
        @test attachment(reopened, HASH) == t.path
        @test isempty(t.store.calls)
    end
end

@testset "attachment of a hit through another copy HEADs the key once" begin
    with_cached_attachment() do t
        two = synced_copy(t.chain, joinpath(t.dir, "two"))
        empty!(t.store.calls)
        @test attachment(two, HASH) == t.path
        @test t.store.calls == [(:stat_object, KEY)]
        @test attachment(two, HASH) == t.path
        @test length(t.store.calls) == 1
    end
end

@testset "attachment of a hit cached from another chain needs this chain's store" begin
    with_cached_attachment() do t
        other = memory_chain(t.dir, t.store; prefix = "q")
        ChainTables.create_chain(other)
        copy = synced_copy(other, joinpath(t.dir, "other"))
        e = thrown(() -> attachment(copy, HASH))
        @test e isa AttachmentAbsentError
        @test (e.key, e.chain_id) == ("q/_attachments/$HASH", copy.head.chain_id)
        message = "a cached file does not stand in for the chain's word"
        @test occursin(message, sprint(showerror, e))
        @test !is_confirmed(copy, HASH)
    end
end

@testset "attachment of a miss the store lacks throws, and caches nothing" begin
    mktempdir() do dir
        (; copy) = created_chain(dir)
        absent = bytes2hex(sha256(b"absent"))
        message = "the chain's store lacks it"
        @test_throws AttachmentAbsentError message attachment(copy, absent)
        @test !ispath(cache_path(dir, absent))
    end
end

@testset "attachment retries a retryable failure of the download" begin
    mktempdir() do dir
        (; store, chain, copy) = created_chain(dir)
        hash = put_attachment(chain, IOBuffer(b"retried"))
        failed = Ref(0)
        fail_once = () -> (failed[] += 1; throw(TransportError("x"; status = 503)))
        store.fault = (verb, key, phase) ->
        verb === :fetch_object_to && failed[] < 1 && fail_once()
        @test read(attachment(copy, hash)) == b"retried"
        @test failed[] == 1
    end
end

@testset "attachment of a download that does not hash to its key throws" begin
    mktempdir() do dir
        (; store, copy) = created_chain(dir)
        hash = bytes2hex(sha256(b"what the key names"))
        key = "p/_attachments/$hash"
        store.objects[key] = b"other bytes"
        store.modified[key] = 0
        empty!(store.calls)
        e = thrown(() -> attachment(copy, hash))
        @test e isa AttachmentDigestError
        @test (e.key, e.found, e.size) == (key, bytes2hex(sha256(b"other bytes")), 11)
        @test e.chain_id == copy.head.chain_id
        @test occursin("nothing was cached", sprint(showerror, e))
        @test length(store.calls) == 1
        @test isempty(readdir(dirname(cache_path(dir, hash))))
        @test !is_confirmed(copy, hash)
    end
end

@testset "attachment rewrites a stale sidecar beside a file that hashes right" begin
    with_cached_attachment() do t
        write(t.path * ".meta", "5000 0.0")
        @test attachment(t.copy, HASH) == t.path
        @test isempty(t.store.calls)
        st = stat(t.path)
        @test read(t.path * ".meta", String) == "$(st.size) $(st.mtime)"
        @test isempty(filter(endswith(".tmp"), readdir(dirname(t.path))))
    end
end

@testset "attachment through an unconfirmed copy heals a stale sidecar, then HEADs" begin
    with_cached_attachment() do t
        two = synced_copy(t.chain, joinpath(t.dir, "two"))
        write(t.path * ".meta", "5000 0.0")
        empty!(t.store.calls)
        @test attachment(two, HASH) == t.path
        @test t.store.calls == [(:stat_object, KEY)]
        @test is_confirmed(two, HASH)
        @test ChainTables.verify(two; full = true) === nothing
    end
end

@testset "attachment throws AttachmentCacheError for a changed file that hashes wrong" begin
    with_cached_attachment() do t
        rewrite_read_only(t.path, rand(StableRNG(6), UInt8, 101))
        st = stat(t.path)
        found = bytes2hex(sha256(read(t.path)))
        e = thrown(() -> attachment(t.copy, HASH))
        @test e isa AttachmentCacheError
        @test (e.path, e.chain_id) == (t.path, t.copy.head.chain_id)
        detail = "the cached file is 101 bytes modified at $(st.mtime) and hashes to $found"
        @test occursin(detail, sprint(showerror, e))
        @test isempty(t.store.calls)
    end
end

@testset "attachment of a damaged entry through an unconfirmed copy throws too" begin
    with_cached_attachment() do t
        rewrite_read_only(t.path, rand(StableRNG(7), UInt8, 101))
        unconfirmed = synced_copy(t.chain, joinpath(t.dir, "unconfirmed"))
        e = thrown(() -> attachment(unconfirmed, HASH))
        @test e isa AttachmentCacheError
        @test (e.path, e.chain_id) == (t.path, unconfirmed.head.chain_id)
    end
end

@testset "attachment fetches again once a damaged entry is deleted, as its error says" begin
    with_cached_attachment() do t
        rewrite_read_only(t.path, rand(StableRNG(8), UInt8, 101))
        remove_read_only(t.path)
        rm(t.path * ".meta")
        @test read(attachment(t.copy, HASH)) == BYTES
    end
end

@testset "attachment of a file without its sidecar fetches it again over the file" begin
    with_cached_attachment() do t
        rewrite_read_only(t.path, rand(StableRNG(9), UInt8, 101))
        rm(t.path * ".meta")
        @test read(attachment(t.copy, HASH)) == BYTES
        @test t.store.calls == [(:fetch_object_to, KEY)]
    end
end

@testset "attachment of a sidecar without its file fetches it again" begin
    with_cached_attachment() do t
        remove_read_only(t.path)
        @test read(attachment(t.copy, HASH)) == BYTES
    end
end

@testset "attachment of a hit the store holds at another size blames the store" begin
    with_cached_attachment() do t
        t.store.objects[KEY] = rand(StableRNG(10), UInt8, 120)
        two = synced_copy(t.chain, joinpath(t.dir, "two"))
        empty!(t.store.calls)
        e = thrown(() -> attachment(two, HASH))
        @test e isa AttachmentDigestError
        @test (e.key, e.size, e.found, e.chain_id) == (KEY, 120, nothing, two.head.chain_id)
        detail = "the cached file, which hashes to the key's hash, is 5000 bytes"
        @test occursin(detail, sprint(showerror, e))
        @test t.store.calls == [(:stat_object, KEY)]
        @test !is_confirmed(two, HASH)
        @test read(t.path) == BYTES
    end
end

@testset "attachment of a hit swapped with its sidecar to match blames the cache" begin
    with_cached_attachment() do t
        other = rand(StableRNG(11), UInt8, 80)
        rewrite_read_only(t.path, other)
        st = stat(t.path)
        write(t.path * ".meta", "$(st.size) $(st.mtime)")
        three = synced_copy(t.chain, joinpath(t.dir, "three"))
        e = thrown(() -> attachment(three, HASH))
        @test e isa AttachmentCacheError
        @test (e.path, e.key, e.chain_id) == (t.path, KEY, three.head.chain_id)
        detail = "the cached file is 80 bytes and hashes to $(bytes2hex(sha256(other))), " *
            "where the store holds 5000"
        @test occursin(detail, sprint(showerror, e))
        @test !is_confirmed(three, HASH)
        remove_read_only(t.path)
        rm(t.path * ".meta")
        @test read(attachment(three, HASH)) == BYTES
    end
end

"""
    reset_stale!(path)

Put `BYTES` back at the cached `path` with a sidecar that does not match it, so the next
read hashes the file.
"""
function reset_stale!(path)
    rewrite_read_only(path, BYTES)
    write(path * ".meta", "5000 0.0")
    return nothing
end

"""
    growing_hasher(path)

A hasher that hashes the file, then appends a byte to the file at `path`.
"""
function growing_hasher(path)
    return function (io)
        digest = ChainTables.hash_file(io)
        chmod(path, 0o644)
        Base.open(f -> write(f, 0x00), path, "a")
        return digest
    end
end

@testset "attachment throws AttachmentCacheError for a file that changes while hashed" begin
    with_cached_attachment() do t
        reset_stale!(t.path)
        hasher = growing_hasher(t.path)
        e = thrown(() -> ChainTables.read_attachment(t.copy, HASH; hasher))
        @test e isa AttachmentCacheError
        @test (e.path, e.key, e.chain_id) == (t.path, KEY, t.copy.head.chain_id)
        @test occursin("changed while it was hashed", sprint(showerror, e))
        @test read(t.path * ".meta", String) == "5000 0.0"
        @test isempty(t.store.calls)
    end
end

@testset "attachment records the hashed file's stat when another is renamed onto it" begin
    with_cached_attachment() do t
        reset_stale!(t.path)
        hashed = let st = stat(t.path)
            "$(st.size) $(st.mtime)"
        end
        swap = function (io)
            digest = ChainTables.hash_file(io)
            write(t.path * ".other", BYTES)
            ChainTables.replace_file(t.path * ".other", t.path)
            return digest
        end
        @test ChainTables.read_attachment(t.copy, HASH; hasher = swap) == t.path
        st = stat(t.path)
        @test read(t.path * ".meta", String) == hashed
        @test hashed != "$(st.size) $(st.mtime)"
    end
end

@testset "attachment on a gateway chain reads the bucket and never the gateway" begin
    s3 = S3TestServer(; bucket = "bkt", credentials = GWTEST_CREDS)
    policy = ["exp" => ["alice@example.com"]]
    alice = "alice@example.com"
    double = GatewayDouble(s3, GWTEST_CREDS, "eu-north-1", alice, policy, _ -> nothing)
    gw = LoopbackServer(double)
    sts = LoopbackServer(gwtest_sts(GWTEST_CREDS, "eu-north-1", GWTEST_ARN))
    try
        mktempdir() do dir
            store = GatewayObjectStore(
                "bkt", loopback_url(gw); region = "eu-north-1", credentials = GWTEST_CREDS,
                endpoint = s3test_endpoint(s3), path_style = true,
                sts_endpoint = loopback_url(sts)
            )
            cache_dir = joinpath(dir, "cache")
            assume_first_writer_wins = true
            chain = Chain("bkt", "exp/run-1"; store, cache_dir, assume_first_writer_wins)
            ChainTables.create_chain(chain)
            hash = put_attachment(chain, IOBuffer(BYTES))
            key = "exp/run-1/_attachments/$hash"
            copy = synced_copy(chain, joinpath(dir, "one"))
            empty!(gw.requests)
            empty!(s3.requests)
            path = attachment(copy, hash)
            @test read(path) == BYTES
            @test [(r.method, r.path) for r in s3.requests] == [("GET", "/bkt/$key")]
            two = synced_copy(chain, joinpath(dir, "two"))
            empty!(s3.requests)
            @test attachment(two, hash) == path
            @test [(r.method, r.path) for r in s3.requests] == [("HEAD", "/bkt/$key")]
            @test ChainTables.verify(two; full = true) === nothing
            absent = bytes2hex(sha256(b"absent"))
            @test_throws AttachmentAbsentError "lacks it" attachment(copy, absent)
            @test isempty(gw.requests)
        end
    finally
        close(gw)
        close(sts)
        close(s3)
    end
end
