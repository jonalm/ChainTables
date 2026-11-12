using Test
using ChainTables: ChainNotFoundError, ChainTablesError, CommitOutcomeUnknownError,
    GatewayMismatchError, LostRaceError, MalformedRecordError, RewrittenChainError,
    StaleHeadError, TransportError, UnsupportedStoreError, WriteBuilderError,
    WriteRefusedError, CredentialsError

@testset "ChainTablesError example" begin
    # Catch ChainTablesError to handle any operational failure of the package.
    caught = try
        throw(WriteBuilderError(; detail = "the row set is empty"))
    catch e
        e isa ChainTablesError || rethrow()
        e
    end
    @test caught isa WriteBuilderError
end

@testset "StaleHeadError example" begin
    e = StaleHeadError(; path = "/data/copy", slot = 3, chain_slot = 5)
    # The message ends with the next move: sync, then build again.
    @test occursin("Run `sync!(copy)`", sprint(showerror, e))
end

@testset "LostRaceError example" begin
    # The winner's transaction hash is carried as a TransactionHash.
    e = LostRaceError(; slot = 4, transaction_hash = zeros(UInt8, 32))
    @test bytes2hex(e.transaction_hash) == "00"^32
end

@testset "CommitOutcomeUnknownError example" begin
    # The failure that made the outcome unknown is kept as `cause`.
    e = CommitOutcomeUnknownError(; slot = 4, cause = ErrorException("network down"))
    @test e.cause.msg == "network down"
end

@testset "UnsupportedStoreError example" begin
    e = UnsupportedStoreError(; endpoint = "https://minio.local")
    @test occursin("assume_first_writer_wins", sprint(showerror, e))
end

@testset "WriteBuilderError example" begin
    e = WriteBuilderError(; call = "insert_rows!(w, :t)", detail = "the row set is empty")
    @test occursin("the row set is empty", sprint(showerror, e))
end

@testset "ChainNotFoundError example" begin
    e = ChainNotFoundError(; bucket = "my-bucket", prefix = "lab/samples")
    @test occursin("create_chain(chain)", sprint(showerror, e))
end

@testset "RewrittenChainError example" begin
    # `found` is nothing when the slot was absent.
    e = RewrittenChainError(; slot = 2, expected = zeros(UInt8, 32))
    @test e.found === nothing
end

@testset "MalformedRecordError example" begin
    e = MalformedRecordError(;
        slot = 7, op = 2, detail = "insert on \"t\": unknown table \"t\"",
    )
    @test e.op == 2
end

@testset "WriteRefusedError example" begin
    # The reason says who must act.
    e = WriteRefusedError(; reason = "forbidden", caller = "alice@example.com")
    @test occursin("permission set", sprint(showerror, e))
end

@testset "GatewayMismatchError example" begin
    e = GatewayMismatchError(; bucket = "my-bucket", gateway = "https://gw.example")
    @test occursin("its own gateway", sprint(showerror, e))
end

@testset "TransportError example" begin
    # `status` is the HTTP status, `nothing` when there was no answer.
    e = TransportError("GET lab/000000000001: HTTP 503 SlowDown"; status = 503)
    @test e.status == 503
end

@testset "CredentialsError example" begin
    # Thrown when no AWS credentials can be had; the profile is evidence.
    e = CredentialsError(; profile = "team", detail = "the AWS CLI (aws) is not on PATH")
    @test e.profile == "team"
    @test occursin("sso_login", sprint(showerror, e))
end
