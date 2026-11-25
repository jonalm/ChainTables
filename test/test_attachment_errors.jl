using Test
using ChainTables: AttachmentAbsentError, AttachmentCacheError, AttachmentChangedError,
    AttachmentDigestError, AttachmentURLExpiredError

include("fixtures/evidence.jl")

@testset "AttachmentChangedError shows what happened, the evidence and the next move" begin
    e = AttachmentChangedError(; key = ATTACHMENT_KEY)
    @test fieldnames(AttachmentChangedError) == (:key, :detail)
    @test sprint(showerror, e) ==
        "AttachmentChangedError: the file changed between hashing and upload, and " *
        "S3 refused its bytes.\n" *
        "  key = p/_attachments/$ZEROS_HEX\n" *
        "Nothing was stored. Stop whatever writes the file, then put the attachment " *
        "again."
end

@testset "AttachmentURLExpiredError shows what happened, the evidence, the next move" begin
    e = AttachmentURLExpiredError(; key = ATTACHMENT_KEY, expires = "2026-11-06T12:00:00Z")
    @test fieldnames(AttachmentURLExpiredError) == (:key, :expires, :detail)
    @test sprint(showerror, e) ==
        "AttachmentURLExpiredError: the URL that the gateway minted expired before " *
        "the upload was done.\n" *
        "  key = p/_attachments/$ZEROS_HEX\n" *
        "  expires = 2026-11-06T12:00:00Z\n" *
        "Nothing was stored. Put the attachment again, which mints a new URL."
end

@testset "AttachmentAbsentError shows what happened, the evidence and the next move" begin
    e = AttachmentAbsentError(; chain_id = CHAIN_ID, key = ATTACHMENT_KEY)
    @test sprint(showerror, e) ==
        "AttachmentAbsentError: the chain's object store does not hold the " *
        "attachment.\n" *
        "  chain_id = AAAAAAAAAAAAAAAAAAAAAAAAAA\n" *
        "  key = p/_attachments/$ZEROS_HEX\n" *
        "Whoever holds the file can put it again with `put_attachment(chain, file)`."
end

@testset "AttachmentDigestError shows what happened, the evidence and the next move" begin
    e = AttachmentDigestError(;
        chain_id = CHAIN_ID, key = ATTACHMENT_KEY, found = ONES_HEX, size = 12
    )
    @test sprint(showerror, e) ==
        "AttachmentDigestError: the object store's bytes for the attachment do not " *
        "fit the hash in its key.\n" *
        "  chain_id = AAAAAAAAAAAAAAAAAAAAAAAAAA\n" *
        "  key = p/_attachments/$ZEROS_HEX\n" *
        "  found = $ONES_HEX\n" *
        "  size = 12\n" *
        "The bucket was written from outside the protocol. Stop and report it."
end

@testset "AttachmentCacheError shows what happened, the evidence and the next move" begin
    e = AttachmentCacheError(;
        chain_id = CHAIN_ID, key = ATTACHMENT_KEY, path = "/c/attachments/ab"
    )
    @test sprint(showerror, e) ==
        "AttachmentCacheError: a file of the attachment cache does not hash to its " *
        "name.\n" *
        "  chain_id = AAAAAAAAAAAAAAAAAAAAAAAAAA\n" *
        "  key = p/_attachments/$ZEROS_HEX\n" *
        "  path = /c/attachments/ab\n" *
        "Delete the file and its `.meta`, which is always safe; the next read " *
        "fetches it again. `repair!(copy)` does that for every confirmed attachment."
end
