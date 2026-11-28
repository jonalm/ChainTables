# `ChainTables.read_attachment` is `attachment` with a `hasher`: the one way to change a
# cached file while it is hashed.
using Test
using ChainTables: ChainTables, AttachmentAbsentError, AttachmentCacheError,
    AttachmentDigestError, attachment, put_attachment, sync!, verify
using ChainTables.Testing: InMemoryObjectStore

include("fixtures/attachments.jl")
include("fixtures/chain_copies.jl")

const BYTES = attachment_bytes(5000)
const H = sha256_hex(BYTES)
const KEY = "p/_attachments/$H"

# A synced local copy of a chain whose store holds the attachment `BYTES`.
function with_attachment_copy(f; keywords...)
    with_chain_copy(; keywords...) do local_copy
        put_attachment(local_copy.chain, IOBuffer(BYTES))
        empty!(local_copy.chain.store.calls)
        f(local_copy)
    end
    return nothing
end

# Another synced local copy beside `local_copy`, of the same chain or of `chain`.
function with_synced_beside(f, local_copy, name; chain = local_copy.chain)
    with_copy_beside(local_copy, name; chain) do other
        sync!(other)
        empty!(chain.store.calls)
        f(other)
    end
    return nothing
end

# A hasher that hashes the file, then renames another file with the same bytes onto its
# path. Linux stamps mtime from a clock that ticks every 1 to 10 ms, so the other file
# is touched until its mtime differs from the hashed file's.
function renaming_hasher(path, bytes)
    return function (io)
        found = ChainTables.hash_file(io)
        other = path * ".other"
        write(other, bytes)
        while mtime(other) == mtime(io)
            sleep(0.001)
            touch(other)
        end
        ChainTables.replace_file(other, path)
        return found
    end
end

@testset "attachment of a hash not cached fetches it into the cache" begin
    with_attachment_copy() do local_copy
        path = @inferred attachment(local_copy, H)
        @test path == cached_file(local_copy, H)
        @test read(path) == BYTES
        @test local_copy.chain.store.calls == [(:fetch_object_to, KEY)]
    end
end

@testset "attachment leaves a read-only file, its sidecar and the copy's marker" begin
    with_attachment_copy() do local_copy
        path = attachment(local_copy, H)
        @test filemode(path) & 0o222 == 0
        @test sidecar_of(path) == stat_text(path)
        @test is_confirmed(local_copy, H)
        @test sort(readdir(dirname(path))) == [H, H * ".meta"]
    end
end

@testset "attachment of a hash that the copy confirmed makes no request" begin
    with_attachment_copy() do local_copy
        path = attachment(local_copy, H)
        empty!(local_copy.chain.store.calls)
        @test attachment(local_copy, H) == path
        @test isempty(local_copy.chain.store.calls)
    end
end

@testset "attachment through a copy reopened makes no request" begin
    with_attachment_copy() do local_copy
        attachment(local_copy, H)
        with_copy(local_copy.chain, local_copy.path) do reopened
            empty!(reopened.chain.store.calls)
            @test read(attachment(reopened, H)) == BYTES
            @test isempty(reopened.chain.store.calls)
        end
    end
end

@testset "attachment cached through another copy asks the store once" begin
    with_attachment_copy() do local_copy
        path = attachment(local_copy, H)
        with_synced_beside(local_copy, "two") do two
            @test attachment(two, H) == path
            @test attachment(two, H) == path
            @test two.chain.store.calls == [(:stat_object, KEY)]
        end
    end
end

@testset "attachment cached from another chain, which lacks it, is absent" begin
    with_attachment_copy() do local_copy
        attachment(local_copy, H)
        store = local_copy.chain.store
        other = chain_in(dirname(local_copy.path); store, prefix = "q")
        ChainTables.create_chain(other)
        with_synced_beside(local_copy, "other"; chain = other) do other_copy
            fragment = "whatever this machine has cached"
            err = @test_throws AttachmentAbsentError fragment attachment(other_copy, H)
            @test (err.value.prefix, err.value.key) == ("q", "q/_attachments/$H")
            @test err.value.chain_id == other_copy.head.chain_id
            @test !is_confirmed(other_copy, H)
        end
    end
end

@testset "attachment of a hash that the store lacks caches nothing" begin
    with_attachment_copy() do local_copy
        fragment = "it was never put to this chain"
        err = @test_throws AttachmentAbsentError fragment attachment(local_copy, NEVER_PUT)
        @test err.value.key == "p/_attachments/$NEVER_PUT"
        @test !ispath(cached_file(local_copy, NEVER_PUT))
    end
end

@testset "attachment fetches again after a failure that may pass" begin
    fault = FailingRequests(:fetch_object_to, :before, 1, transport_failure(503))
    with_attachment_copy(; store = InMemoryObjectStore(; fault)) do local_copy
        @test read(attachment(local_copy, H)) == BYTES
        @test n_calls(local_copy.chain.store, :fetch_object_to) == 2
    end
end

@testset "attachment refuses a local copy with no head, before any request" begin
    with_attachment_copy() do local_copy
        with_copy_beside(local_copy, "fresh") do fresh
            fragment = "the local copy at $(fresh.path) has no head yet"
            @test_throws ArgumentError fragment attachment(fresh, H)
            @test isempty(local_copy.chain.store.calls)
        end
    end
end

@testset "attachment refuses a hash that is not 64 lowercase hex" begin
    with_attachment_copy() do local_copy
        fragment = "\"$(uppercase(H))\" is not an attachment hash"
        @test_throws ArgumentError fragment attachment(local_copy, uppercase(H))
        @test isempty(local_copy.chain.store.calls)
    end
end

@testset "attachment throws for a download that does not hash to its key" begin
    with_chain_copy() do local_copy
        store = local_copy.chain.store
        store.objects[KEY], store.modified[KEY] = b"other bytes", 0
        fragment = "the download does not hash to the key's hash"
        err = @test_throws AttachmentDigestError fragment attachment(local_copy, H)
        @test (err.value.key, err.value.size) == (KEY, 11)
        @test err.value.found == sha256_hex(b"other bytes")
        @test err.value.chain_id == local_copy.head.chain_id
        @test n_calls(store, :fetch_object_to) == 1
        @test isempty(readdir(dirname(cached_file(local_copy, H))))
        @test !is_confirmed(local_copy, H)
    end
end

@testset "attachment writes again a stale sidecar beside a file that hashes right" begin
    with_attachment_copy() do local_copy
        path = attachment(local_copy, H)
        write_stale_sidecar!(path)
        empty!(local_copy.chain.store.calls)
        @test attachment(local_copy, H) == path
        @test sidecar_of(path) == stat_text(path)
        @test isempty(local_copy.chain.store.calls)
        @test sort(readdir(dirname(path))) == [H, H * ".meta"]
    end
end

@testset "attachment heals a stale sidecar, then asks the store through a new copy" begin
    with_attachment_copy() do local_copy
        path = attachment(local_copy, H)
        with_synced_beside(local_copy, "two") do two
            write_stale_sidecar!(path)
            @test attachment(two, H) == path
            @test two.chain.store.calls == [(:stat_object, KEY)]
            @test is_confirmed(two, H)
            @test verify(two; full = true) === nothing
        end
    end
end

@testset "attachment throws for a cached file that was changed after it was cached" begin
    with_attachment_copy() do local_copy
        path = attachment(local_copy, H)
        overwrite_cached!(path, attachment_bytes(101; seed = 2))
        recorded = sidecar_of(path)
        empty!(local_copy.chain.store.calls)
        fragment = "its sidecar records $(repr(recorded)), so it was changed"
        err = @test_throws AttachmentCacheError fragment attachment(local_copy, H)
        @test (err.value.path, err.value.key) == (path, KEY)
        @test err.value.chain_id == local_copy.head.chain_id
        @test isempty(local_copy.chain.store.calls)
    end
end

@testset "attachment fetches again a damaged file once it is deleted" begin
    with_attachment_copy() do local_copy
        path = attachment(local_copy, H)
        overwrite_cached!(path, attachment_bytes(101; seed = 2))
        with_synced_beside(local_copy, "two") do two
            @test_throws AttachmentCacheError "not to its name" attachment(two, H)
            remove_cached!(path)
            rm(path * ".meta")
            @test read(attachment(two, H)) == BYTES
        end
    end
end

@testset "attachment fetches again a cached file with no sidecar" begin
    with_attachment_copy() do local_copy
        path = attachment(local_copy, H)
        overwrite_cached!(path, attachment_bytes(101; seed = 2))
        rm(path * ".meta")
        empty!(local_copy.chain.store.calls)
        @test read(attachment(local_copy, H)) == BYTES
        @test local_copy.chain.store.calls == [(:fetch_object_to, KEY)]
    end
end

@testset "attachment fetches again a sidecar with no file" begin
    with_attachment_copy() do local_copy
        path = attachment(local_copy, H)
        remove_cached!(path)
        @test read(attachment(local_copy, H)) == BYTES
    end
end

@testset "attachment throws when the store holds another size than a sound file" begin
    with_attachment_copy() do local_copy
        path = attachment(local_copy, H)
        store = local_copy.chain.store
        store.objects[KEY] = attachment_bytes(120; seed = 3)
        with_synced_beside(local_copy, "two") do two
            fragment = "the store's bytes cannot hash to it"
            err = @test_throws AttachmentDigestError fragment attachment(two, H)
            @test (err.value.key, err.value.size, err.value.found) == (KEY, 120, nothing)
            @test err.value.chain_id == two.head.chain_id
            @test store.calls == [(:stat_object, KEY)]
            @test !is_confirmed(two, H)
            @test read(path) == BYTES
        end
    end
end

@testset "attachment throws when another size is cached and does not hash right" begin
    with_attachment_copy() do local_copy
        path = attachment(local_copy, H)
        other = attachment_bytes(80; seed = 4)
        overwrite_cached!(path, other)
        write(path * ".meta", stat_text(path))
        with_synced_beside(local_copy, "two") do two
            fragment = "is 80 bytes and hashes to $(sha256_hex(other)), not to its name, " *
                "while the store holds 5000 bytes"
            err = @test_throws AttachmentCacheError fragment attachment(two, H)
            @test (err.value.path, err.value.key) == (path, KEY)
            @test !is_confirmed(two, H)
            remove_cached!(path)
            rm(path * ".meta")
            @test read(attachment(two, H)) == BYTES
        end
    end
end

@testset "read_attachment throws for a file that changes while it is hashed" begin
    with_attachment_copy() do local_copy
        path = attachment(local_copy, H)
        write_stale_sidecar!(path)
        recorded = sidecar_of(path)
        empty!(local_copy.chain.store.calls)
        hasher = growing_hasher(path)
        fragment = "the cached file changed while it was hashed"
        err = @test_throws AttachmentCacheError fragment ChainTables.read_attachment(
            local_copy, H; hasher
        )
        @test (err.value.path, err.value.key) == (path, KEY)
        @test sidecar_of(path) == recorded
        @test isempty(local_copy.chain.store.calls)
    end
end

@testset "read_attachment records the hashed file when another is renamed onto it" begin
    # Windows cannot replace a file that is open, so there the case cannot arise.
    if Sys.isunix()
        with_attachment_copy() do local_copy
            path = attachment(local_copy, H)
            write_stale_sidecar!(path)
            hashed = stat_text(path)
            hasher = renaming_hasher(path, BYTES)
            @test ChainTables.read_attachment(local_copy, H; hasher) == path
            @test sidecar_of(path) == hashed
            @test stat_text(path) != hashed
        end
    end
end
