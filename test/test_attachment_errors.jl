using Test
using ChainTables: AttachmentAbsentError, AttachmentCacheError, AttachmentChangedError,
    AttachmentDigestError, AttachmentURLExpiredError

include("fixtures/evidence.jl")

const EXPIRES = "2026-11-06T12:00:00Z"

const REASONS = [
    (
        reason = :expired_before_upload,
        next_move = "Put the attachment again, which mints a new URL.",
    ),
    (reason = :outlasted, next_move = "Put the attachment again over a faster link."),
    (
        reason = :expired_early,
        next_move = "Put the attachment again. If this recurs, report it to the " *
            "bucket's operator: the gateway's clock or S3's is off.",
    ),
    (reason = :unknown, next_move = "Put the attachment again, which mints a new URL."),
]

@testset "AttachmentChangedError shows what happened, the evidence and the next move" begin
    e = AttachmentChangedError(; bucket = "bkt", key = ATTACHMENT_KEY)
    @test fieldnames(AttachmentChangedError) == (:bucket, :key, :detail)
    @test sprint(showerror, e) ==
        "AttachmentChangedError: the file changed between hashing and upload, and " *
        "S3 refused its bytes.\n" *
        "  bucket = bkt\n" *
        "  key = p/_attachments/$ZEROS_HEX\n" *
        "Nothing was stored. Stop whatever writes the file, then put the attachment " *
        "again."
end

@testset "AttachmentURLExpiredError shows what happened, the evidence, the next move" begin
    e = AttachmentURLExpiredError(;
        key = ATTACHMENT_KEY, gateway = GATEWAY, expires = EXPIRES, reason = :outlasted
    )
    @test fieldnames(AttachmentURLExpiredError) ==
        (:key, :gateway, :expires, :reason, :detail)
    @test sprint(showerror, e) ==
        "AttachmentURLExpiredError: the URL that the gateway minted expired before " *
        "the upload was done.\n" *
        "  key = p/_attachments/$ZEROS_HEX\n" *
        "  gateway = https://gw\n" *
        "  expires = $EXPIRES\n" *
        "  reason = outlasted\n" *
        "Nothing was stored. Put the attachment again over a faster link."
end

@testset "AttachmentURLExpiredError's next move: $(case.reason)" for case in REASONS
    e = AttachmentURLExpiredError(; key = ATTACHMENT_KEY, case.reason)
    @test endswith(sprint(showerror, e), "Nothing was stored. " * case.next_move)
end

@testset "AttachmentAbsentError shows what happened, the evidence and the next move" begin
    e = AttachmentAbsentError(;
        bucket = "bkt", prefix = "p", chain_id = CHAIN_ID, key = ATTACHMENT_KEY
    )
    @test fieldnames(AttachmentAbsentError) ==
        (:bucket, :prefix, :chain_id, :key, :detail)
    @test sprint(showerror, e) ==
        "AttachmentAbsentError: the chain's object store does not hold the " *
        "attachment.\n" *
        "  bucket = bkt\n" *
        "  prefix = p\n" *
        "  chain_id = AAAAAAAAAAAAAAAAAAAAAAAAAA\n" *
        "  key = p/_attachments/$ZEROS_HEX\n" *
        "Whoever holds the file can put it again with `put_attachment(chain, file)`."
end

@testset "AttachmentDigestError shows what happened, the evidence and the next move" begin
    e = AttachmentDigestError(;
        bucket = "bkt", prefix = "p", chain_id = CHAIN_ID, key = ATTACHMENT_KEY,
        found = ONES_HEX, size = 12,
    )
    @test fieldnames(AttachmentDigestError) ==
        (:bucket, :prefix, :chain_id, :key, :found, :size, :detail)
    @test sprint(showerror, e) ==
        "AttachmentDigestError: the object store's bytes for the attachment do not " *
        "fit the hash in its key.\n" *
        "  bucket = bkt\n" *
        "  prefix = p\n" *
        "  chain_id = AAAAAAAAAAAAAAAAAAAAAAAAAA\n" *
        "  key = p/_attachments/$ZEROS_HEX\n" *
        "  found = $ONES_HEX\n" *
        "  size = 12\n" *
        "The bucket was written from outside the protocol. Stop and report it."
end

@testset "AttachmentCacheError shows what happened, the evidence and the next move" begin
    e = AttachmentCacheError(;
        bucket = "bkt", prefix = "p", chain_id = CHAIN_ID, key = ATTACHMENT_KEY,
        path = "/c/attachments/ab",
    )
    @test fieldnames(AttachmentCacheError) ==
        (:bucket, :prefix, :chain_id, :key, :path, :detail)
    @test sprint(showerror, e) ==
        "AttachmentCacheError: a file of the attachment cache does not hash to its " *
        "name.\n" *
        "  bucket = bkt\n" *
        "  prefix = p\n" *
        "  chain_id = AAAAAAAAAAAAAAAAAAAAAAAAAA\n" *
        "  key = p/_attachments/$ZEROS_HEX\n" *
        "  path = /c/attachments/ab\n" *
        "Delete the file and its `.meta`, which is always safe; the next read " *
        "fetches it again. `repair!(copy)` does that for every confirmed attachment."
end
