using Test
using ChainTables: ChainTables, AttachmentAbsentError, AttachmentCacheError,
    AttachmentChangedError, AttachmentDigestError, AttachmentURLExpiredError,
    ChainTablesError, GatewaySessionEndingError

const CHAIN = "A"^26
const KEY = "p/_attachments/" * "0"^64

# Each error built with Evidence and a detail, and the four parts its showerror writes.
const ERRORS = [
    (
        name = "AttachmentChangedError",
        error = AttachmentChangedError(;
            chain_id = CHAIN, key = KEY, detail = "S3 answered BadDigest",
        ),
        summary = "the file changed between hashing and upload",
        evidence = "key = $KEY",
        next_move = "Stop whatever writes the file, and put it again.",
    ),
    (
        name = "AttachmentURLExpiredError",
        error = AttachmentURLExpiredError(;
            chain_id = CHAIN, key = KEY, expires = "2026-11-06T12:00:00Z",
            detail = "S3 answered AccessDenied",
        ),
        summary = "the minted upload URL expired",
        evidence = "expires = 2026-11-06T12:00:00Z",
        next_move = "Put the attachment again, which mints a new URL",
    ),
    (
        name = "GatewaySessionEndingError",
        error = GatewaySessionEndingError(;
            chain_id = CHAIN, key = KEY, gateway = "https://gw",
            detail = "503 session_ending",
        ),
        summary = "the gateway's session is ending, so it signs no URL",
        evidence = "gateway = https://gw",
        next_move = "Put the attachment again later",
    ),
    (
        name = "AttachmentAbsentError",
        error = AttachmentAbsentError(;
            chain_id = CHAIN, key = KEY, detail = "HEAD answered 404",
        ),
        summary = "the store holds no such attachment",
        evidence = "chain_id = $CHAIN",
        next_move = "`put_attachment(chain, file)`",
    ),
    (
        name = "AttachmentDigestError",
        error = AttachmentDigestError(;
            chain_id = CHAIN, key = KEY, found = "ab"^32, size = 10,
            detail = "the download hashes elsewhere",
        ),
        summary = "the stored attachment does not hash to its key",
        evidence = "size = 10",
        next_move = "stop and report it",
    ),
    (
        name = "AttachmentCacheError",
        error = AttachmentCacheError(;
            chain_id = CHAIN, key = KEY, path = "/cache/ab/ab",
            detail = "the file hashes elsewhere",
        ),
        summary = "the attachment cache's file does not hash to its name",
        evidence = "path = /cache/ab/ab",
        next_move = "Delete the file and its `.meta`",
    ),
]

@testset "$(case.name) is a ChainTablesError" for case in ERRORS
    @test case.error isa ChainTablesError
end

@testset "$(case.name) shows its summary and detail first" for case in ERRORS
    text = sprint(showerror, case.error)
    @test startswith(text, "$(case.name): $(case.summary): $(case.error.detail).")
end

@testset "$(case.name) shows its Evidence" for case in ERRORS
    @test occursin("\n  $(case.evidence)", sprint(showerror, case.error))
end

@testset "$(case.name) shows its next move" for case in ERRORS
    @test occursin(case.next_move, sprint(showerror, case.error))
end

@testset "$(case.name) leaves out unknown Evidence" for case in ERRORS
    bare = typeof(case.error)(; detail = "x")
    @test !occursin(" = nothing", sprint(showerror, bare))
end

@testset "error constructors infer" begin
    @test @inferred(AttachmentChangedError(; key = KEY)).key == KEY
    @test @inferred(AttachmentURLExpiredError(; expires = "e")).expires == "e"
    @test @inferred(GatewaySessionEndingError(; gateway = "g")).gateway == "g"
    @test @inferred(AttachmentAbsentError(; key = KEY)).key == KEY
    @test @inferred(AttachmentDigestError(; size = 1)).size == 1
    @test @inferred(AttachmentCacheError(; path = "p")).path == "p"
end
