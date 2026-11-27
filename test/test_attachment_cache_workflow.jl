# `verify(copy; full = true)` and `repair!(copy)` over the attachments that a local copy
# confirmed. `ChainTables.repair_attachments!` is `repair!`'s pass with a `hasher`: the
# one way to change a cached file while it is hashed.
using Test
using ChainTables: ChainTables, AttachmentAbsentError, AttachmentCacheError,
    AttachmentDigestError, attachment, put_attachment, repair!, verify

include("fixtures/attachments.jl")
include("fixtures/chain_copies.jl")

const A = attachment_bytes(300; seed = 1)
const B = attachment_bytes(400; seed = 2)
const C = attachment_bytes(50; seed = 3)
const HA, HB, HC = sha256_hex(A), sha256_hex(B), sha256_hex(C)

# A synced local copy that confirmed the attachments `A` and `B`; `C` is stored and
# never read.
function with_confirmed_copy(f)
    with_chain_copy() do local_copy
        chain = local_copy.chain
        foreach(bytes -> put_attachment(chain, IOBuffer(bytes)), (A, B, C))
        attachment(local_copy, HA)
        attachment(local_copy, HB)
        f(local_copy)
    end
    return nothing
end

# Other bytes in a cached file, with a sidecar that records them, so that only a hash
# finds the damage.
function damage_unseen!(path)
    overwrite_cached!(path, attachment_bytes(filesize(path); seed = 9))
    write(path * ".meta", stat_text(path))
    return nothing
end

function forget_in_store!(local_copy, h)
    store = local_copy.chain.store
    delete!(store.objects, "p/_attachments/$h")
    delete!(store.modified, "p/_attachments/$h")
    return nothing
end

repaired(local_copy) = repair!(local_copy).attachments_repaired

@testset "verify with full checks only the confirmed attachments, and passes" begin
    with_confirmed_copy() do local_copy
        damage_unseen!(cached_file(local_copy, HA))
        @test verify(local_copy) === nothing
        @test_throws AttachmentCacheError "not hash to their names" verify(
            local_copy; full = true
        )
    end
end

@testset "verify with full names each damaged file, and passes over a gone one" begin
    with_confirmed_copy() do local_copy
        damaged = cached_file(local_copy, HA)
        damage_unseen!(damaged)
        remove_cached!(cached_file(local_copy, HB))
        fragment = "verify(copy; full = true) found cached files that do not hash to " *
            "their names: $damaged"
        err = @test_throws AttachmentCacheError fragment verify(local_copy; full = true)
        @test err.value.chain_id == local_copy.head.chain_id
        @test (err.value.bucket, err.value.prefix) == ("bkt", "p")
    end
end

@testset "verify with full passes over a stale sidecar, and writes nothing" begin
    with_confirmed_copy() do local_copy
        path = cached_file(local_copy, HA)
        write(path * ".meta", "0 0.0")
        @test verify(local_copy; full = true) === nothing
        @test sidecar_of(path) == "0 0.0"
    end
end

@testset "verify with full passes once the attachment cache is cleared" begin
    with_confirmed_copy() do local_copy
        rm(dirname(dirname(cached_file(local_copy, HA))); recursive = true)
        @test verify(local_copy; full = true) === nothing
        @test read(attachment(local_copy, HA)) == A
    end
end

@testset "repair! leaves sound attachments alone" begin
    with_confirmed_copy() do local_copy
        @test repaired(local_copy) == 0
    end
end

@testset "repair! fetches again what is damaged or gone from the cache" begin
    with_confirmed_copy() do local_copy
        damage_unseen!(cached_file(local_copy, HA))
        remove_cached!(cached_file(local_copy, HB))
        empty!(local_copy.chain.store.calls)
        @test repaired(local_copy) == 2
        @test read(cached_file(local_copy, HA)) == A
        @test read(cached_file(local_copy, HB)) == B
        @test filemode(cached_file(local_copy, HA)) & 0o222 == 0
        @test n_calls(local_copy.chain.store, :fetch_object_to) == 2
        @test verify(local_copy; full = true) === nothing
    end
end

@testset "repair! writes again a stale sidecar, and fetches nothing" begin
    with_confirmed_copy() do local_copy
        path = cached_file(local_copy, HA)
        write(path * ".meta", "0 0.0")
        empty!(local_copy.chain.store.calls)
        @test repaired(local_copy) == 1
        @test sidecar_of(path) == stat_text(path)
        @test n_calls(local_copy.chain.store, :fetch_object_to) == 0
    end
end

@testset "repair! finishes its pass, then names the attachments gone from the store" begin
    with_confirmed_copy() do local_copy
        attachment(local_copy, HC)
        foreach(h -> forget_in_store!(local_copy, h), (HA, HC))
        foreach(h -> remove_cached!(cached_file(local_copy, h)), (HA, HC))
        damage_unseen!(cached_file(local_copy, HB))
        gone = join(sort(["p/_attachments/$HA", "p/_attachments/$HC"]), ", ")
        fragment = "the store no longer holds these attachments that the copy had " *
            "confirmed: $gone"
        err = @test_throws AttachmentAbsentError fragment repair!(local_copy)
        @test err.value.chain_id == local_copy.head.chain_id
        @test err.value.key === nothing
        @test read(cached_file(local_copy, HB)) == B
        @test !is_confirmed(local_copy, HA)
        @test !is_confirmed(local_copy, HC)
        @test repaired(local_copy) == 0
        @test verify(local_copy; full = true) === nothing
    end
end

@testset "repair! names the one key of a single attachment gone from the store" begin
    with_confirmed_copy() do local_copy
        forget_in_store!(local_copy, HB)
        remove_cached!(cached_file(local_copy, HB))
        err = @test_throws AttachmentAbsentError "p/_attachments/$HB" repair!(local_copy)
        @test err.value.key == "p/_attachments/$HB"
    end
end

@testset "repair! removes no marker when its pass throws before its end" begin
    with_confirmed_copy() do local_copy
        # The pass goes in hash order, so the hash gone from the store comes first.
        gone, wrong = HA < HB ? (HA, HB) : (HB, HA)
        forget_in_store!(local_copy, gone)
        remove_cached!(cached_file(local_copy, gone))
        remove_cached!(cached_file(local_copy, wrong))
        store = local_copy.chain.store
        original = store.objects["p/_attachments/$wrong"]
        store.objects["p/_attachments/$wrong"] = attachment_bytes(40; seed = 8)
        fragment = "the download does not hash to the key's hash"
        @test_throws AttachmentDigestError fragment repair!(local_copy)
        @test is_confirmed(local_copy, gone)
        store.objects["p/_attachments/$wrong"] = original
        err = @test_throws AttachmentAbsentError "p/_attachments/$gone" repair!(local_copy)
        @test !is_confirmed(local_copy, gone)
        @test read(cached_file(local_copy, wrong)) == original
    end
end

@testset "repair_attachments! fetches again a file that changes while it is hashed" begin
    with_confirmed_copy() do local_copy
        path = cached_file(local_copy, HA)
        write(path * ".meta", "0 0.0")
        hasher = growing_hasher(path)
        empty!(local_copy.chain.store.calls)
        @test ChainTables.repair_attachments!(local_copy, local_copy.chain; hasher) == 1
        @test local_copy.chain.store.calls == [(:fetch_object_to, "p/_attachments/$HA")]
        @test read(path) == A
        @test sidecar_of(path) == stat_text(path)
    end
end
