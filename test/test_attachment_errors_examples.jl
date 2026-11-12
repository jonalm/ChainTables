using Test
using ChainTables: AttachmentAbsentError, AttachmentCacheError, AttachmentChangedError,
    AttachmentDigestError, AttachmentURLExpiredError, GatewaySessionEndingError

const KEY = "lab/_attachments/" * "0"^64

@testset "AttachmentChangedError example" begin
    e = AttachmentChangedError(; key = KEY)
    @test occursin("Nothing was stored", sprint(showerror, e))
end

@testset "AttachmentURLExpiredError example" begin
    # `expires` is the time the gateway gave, ISO 8601 in UTC.
    e = AttachmentURLExpiredError(; key = KEY, expires = "2026-11-06T12:00:00Z")
    @test e.expires == "2026-11-06T12:00:00Z"
end

@testset "GatewaySessionEndingError example" begin
    e = GatewaySessionEndingError(; key = KEY, gateway = "https://gw.example")
    @test occursin("later", sprint(showerror, e))
end

@testset "AttachmentAbsentError example" begin
    e = AttachmentAbsentError(; key = KEY)
    @test occursin("put_attachment(chain, file)", sprint(showerror, e))
end

@testset "AttachmentDigestError example" begin
    # `found` is the hex SHA-256 of what was downloaded.
    e = AttachmentDigestError(; key = KEY, found = "ab"^32, size = 1024)
    @test e.size == 1024
end

@testset "AttachmentCacheError example" begin
    e = AttachmentCacheError(; key = KEY, path = "/cache/attachments/00/" * "0"^64)
    @test occursin(".meta", sprint(showerror, e))
end
