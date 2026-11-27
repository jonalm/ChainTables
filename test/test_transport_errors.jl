using Test
using ChainTables: TransportError

const URL = "https://bkt.s3.eu-north-1.amazonaws.com/p/000000000001"
const RETRY_LATER = "The failure may pass: run the call again later. `commit!` and " *
    "`create_chain` have retried it already."
const NO_RETRY = "A retry will not help. Check the credentials, the bucket and its " *
    "region, and that the endpoint is S3."
const STATUSES = [
    (status = nothing, next_move = RETRY_LATER),
    (status = 500, next_move = RETRY_LATER),
    (status = 503, next_move = RETRY_LATER),
    (status = 409, next_move = RETRY_LATER),
    (status = 429, next_move = RETRY_LATER),
    (status = 200, next_move = NO_RETRY),
    (status = 307, next_move = NO_RETRY),
    (status = 400, next_move = NO_RETRY),
    (status = 403, next_move = NO_RETRY),
    (status = 404, next_move = NO_RETRY),
]

@testset "TransportError shows what happened, the evidence and the next move" begin
    e = TransportError(;
        method = "GET", url = URL, status = 403, detail = "AccessDenied: Access Denied"
    )
    @test sprint(showerror, e) ==
        "TransportError: a request failed.\n" *
        "AccessDenied: Access Denied\n" *
        "  method = GET\n" *
        "  url = https://bkt.s3.eu-north-1.amazonaws.com/p/000000000001\n" *
        "  status = 403\n" *
        NO_RETRY
end

@testset "TransportError leaves out the status when no response came" begin
    e = TransportError(;
        method = "PUT", url = URL, status = nothing, detail = "no response"
    )
    @test !occursin("status", sprint(showerror, e))
end

@testset "TransportError takes its next move from the status" begin
    @testset "$(case.status)" for case in STATUSES
        e = TransportError(; method = "GET", url = URL, case.status)
        @test last(split(sprint(showerror, e), "\n")) == case.next_move
    end
end

@testset "TransportError needs the method, the URL and the status" begin
    @test_throws UndefKeywordError "status" TransportError(; method = "GET", url = URL)
end

@testset "TransportError(message; status) holds the message as detail" begin
    e = TransportError("PUT https://gw/: HTTP 503 busy"; status = 503)
    @test e.detail == "PUT https://gw/: HTTP 503 busy"
    @test e.status == 503
    @test TransportError("timed out").status === nothing
end
