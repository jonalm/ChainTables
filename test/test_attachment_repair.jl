using Test
using ChainTables: ChainTables, AttachmentAbsentError, AttachmentCacheError,
    AttachmentDigestError, attachment, put_attachment, repair!, verify
using SHA: sha256
using StableRNGs: StableRNG

include("fixtures/attachments.jl")

const A = rand(StableRNG(20), UInt8, 300)
const B = rand(StableRNG(21), UInt8, 400)
const HASH_A = bytes2hex(sha256(A))
const HASH_B = bytes2hex(sha256(B))

is_confirmed(copy, hash) = isfile(joinpath(copy.path, "confirmed", hash))
sidecar_of(path) = (st = stat(path); "$(st.size) $(st.mtime)")

"""
    with_two_attachments(f)

Call `f(t)` with `t = (; store, chain, copy, path_a, path_b, dir)`: a chain holding `A`
and `B`, both read once through a synced local copy, and a third attachment never read.
"""
function with_two_attachments(f)
    mktempdir() do dir
        (; store, chain, copy) = created_chain(dir)
        put_attachment(chain, IOBuffer(A))
        put_attachment(chain, IOBuffer(B))
        put_attachment(chain, IOBuffer(b"never read"))
        path_a = attachment(copy, HASH_A)
        path_b = attachment(copy, HASH_B)
        empty!(store.calls)
        f((; store, chain, copy, path_a, path_b, dir))
    end
    return nothing
end

"""
    damage!(t)

Give `A`'s cached file other bytes with a sidecar to match, and delete `B`'s entry.
"""
function damage!(t)
    rewrite_read_only(t.path_a, rand(StableRNG(22), UInt8, 300))
    write(t.path_a * ".meta", sidecar_of(t.path_a))
    remove_read_only(t.path_b)
    rm(t.path_b * ".meta")
    return nothing
end

@testset "verify and repair! pass over sound confirmed attachments" begin
    with_two_attachments() do t
        @test verify(t.copy; full = true) === nothing
        @test repair!(t.copy) == (; slot = 0, files_rewritten = 0, attachments_repaired = 0)
    end
end

@testset "verify without full does not check attachments" begin
    with_two_attachments() do t
        damage!(t)
        @test verify(t.copy) === nothing
    end
end

@testset "verify(copy; full = true) throws AttachmentCacheError naming a damaged file" begin
    with_two_attachments() do t
        damage!(t)
        e = thrown(() -> verify(t.copy; full = true))
        @test e isa AttachmentCacheError
        @test e.chain_id == t.copy.head.chain_id
        message = sprint(showerror, e)
        @test occursin("$(t.path_a) do not hash to their names", message)
        # A deleted entry is not damage: the next read fetches it.
        @test !occursin(t.path_b, message)
    end
end

@testset "repair! fetches a damaged and a deleted entry again" begin
    with_two_attachments() do t
        damage!(t)
        @test repair!(t.copy).attachments_repaired == 2
        @test read(t.path_a) == A
        @test read(t.path_b) == B
        @test filemode(t.path_a) & 0o222 == 0
        fetched = sort([call for call in t.store.calls if first(call) === :fetch_object_to])
        expected = sort([(:fetch_object_to, "p/_attachments/$h") for h in (HASH_A, HASH_B)])
        @test fetched == expected
        @test verify(t.copy; full = true) === nothing
    end
end

@testset "verify passes over a cleared attachment cache, and a read fetches again" begin
    with_two_attachments() do t
        rm(joinpath(t.dir, "cache", "attachments"); recursive = true)
        @test verify(t.copy; full = true) === nothing
        @test read(attachment(t.copy, HASH_A)) == A
    end
end

@testset "repair! rewrites a stale sidecar beside a sound file, fetching nothing" begin
    with_two_attachments() do t
        write(t.path_a * ".meta", "0 0.0")
        @test verify(t.copy; full = true) === nothing
        @test read(t.path_a * ".meta", String) == "0 0.0"
        @test repair!(t.copy).attachments_repaired == 1
        @test count_calls(t.store, :fetch_object_to) == 0
        @test read(t.path_a * ".meta", String) == sidecar_of(t.path_a)
    end
end

"""
    remove_from_store_and_cache!(t, hash)

Delete the attachment `hash` from the chain's store and from the attachment cache.
"""
function remove_from_store_and_cache!(t, hash)
    delete!(t.store.objects, "p/_attachments/$hash")
    remove_read_only(joinpath(t.dir, "cache", "attachments", hash[1:2], hash))
    return nothing
end

@testset "repair! of attachments gone from the store finishes, then throws once" begin
    with_two_attachments() do t
        c = rand(StableRNG(23), UInt8, 50)
        hash_c = put_attachment(t.chain, IOBuffer(c))
        attachment(t.copy, hash_c)
        remove_from_store_and_cache!(t, HASH_A)
        remove_from_store_and_cache!(t, hash_c)
        rewrite_read_only(t.path_b, rand(StableRNG(24), UInt8, 400))
        e = thrown(() -> repair!(t.copy))
        @test e isa AttachmentAbsentError
        @test (e.chain_id, e.key) == (t.copy.head.chain_id, nothing)
        keys = join(["p/_attachments/$h" for h in sort([HASH_A, hash_c])], ", ")
        detail = "2 confirmed attachment(s), whose markers were removed: $keys"
        @test occursin(detail, sprint(showerror, e))
        @test read(t.path_b) == B
        @test !is_confirmed(t.copy, HASH_A)
        @test !is_confirmed(t.copy, hash_c)
        @test repair!(t.copy).attachments_repaired == 0
        @test verify(t.copy; full = true) === nothing
        @test_throws AttachmentAbsentError "lacks it" attachment(t.copy, HASH_A)
    end
end

@testset "repair! of one attachment gone from the store names its key" begin
    with_two_attachments() do t
        remove_from_store_and_cache!(t, HASH_B)
        e = thrown(() -> repair!(t.copy))
        @test e isa AttachmentAbsentError
        @test e.key == "p/_attachments/$HASH_B"
    end
end

@testset "repair! removes no confirmed marker when the pass throws before its end" begin
    mktempdir() do dir
        (; store, chain, copy) = created_chain(dir)
        x = rand(StableRNG(25), UInt8, 30)
        y = rand(StableRNG(26), UInt8, 40)
        # Confirmed hashes are repaired in sorted order: the one gone from the store first.
        gone, bad = bytes2hex(sha256(x)) < bytes2hex(sha256(y)) ? (x, y) : (y, x)
        hash_gone = put_attachment(chain, IOBuffer(gone))
        hash_bad = put_attachment(chain, IOBuffer(bad))
        remove_read_only(attachment(copy, hash_gone))
        remove_read_only(attachment(copy, hash_bad))
        delete!(store.objects, "p/_attachments/$hash_gone")
        store.objects["p/_attachments/$hash_bad"] = rand(StableRNG(27), UInt8, 40)
        @test_throws AttachmentDigestError "nothing was cached" repair!(copy)
        @test is_confirmed(copy, hash_gone)
        store.objects["p/_attachments/$hash_bad"] = bad
        e = thrown(() -> repair!(copy))
        @test e isa AttachmentAbsentError
        @test e.key == "p/_attachments/$hash_gone"
        @test !is_confirmed(copy, hash_gone)
    end
end

@testset "repair! fetches again a file that changes while it is hashed" begin
    with_two_attachments() do t
        write(t.path_a * ".meta", "300 0.0")
        grow = function (io)
            digest = ChainTables.hash_file(io)
            chmod(t.path_a, 0o644)
            Base.open(f -> write(f, 0x00), t.path_a, "a")
            return digest
        end
        @test ChainTables.repair_attachments!(t.copy, t.chain; hasher = grow) == 1
        @test t.store.calls == [(:fetch_object_to, "p/_attachments/$HASH_A")]
        @test read(t.path_a) == A
        @test read(t.path_a * ".meta", String) == sidecar_of(t.path_a)
    end
end
