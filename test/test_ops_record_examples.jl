using Test
using ChainTables: Ops

@testset "Client example" begin
    # Written on host "box" by "carol", at one second past the Unix epoch.
    client = Ops.Client("box", "carol", "ChainTables 0.3.3", "1.13.2", 1000)
    @test client.user == "carol"

    # Host and user are each left out with `nothing`.
    @test Ops.Client(nothing, nothing, "ChainTables 0.3.3", "1.13.2", 1000).host === nothing
end

@testset "local_client example" begin
    # This machine's client map, for a record written now by "carol".
    client = Ops.local_client(; user = "carol")
    @test client.user == "carol"
    @test client.julia == string(VERSION)

    # The same without the host name.
    @test Ops.local_client(; record_host = false).host === nothing
end

@testset "Record example" begin
    chain_id = UInt8.(0:15)
    fingerprint = zeros(UInt8, 32)
    client = Ops.Client(nothing, nothing, "ChainTables 0.3.3", "1.13.2", 1000)

    # The genesis record of a chain: slot 0, no parent, no ops.
    genesis = Ops.Record(chain_id, 0, nothing, fingerprint, client, nothing, Ops.Op[])
    @test isempty(genesis.ops)

    # The record at slot 1 names its parent's transaction hash and carries its ops.
    parent = Ops.transaction_hash(Ops.encode_record(genesis))
    ops = [Ops.DropTable("samples")]
    record = Ops.Record(chain_id, 1, parent, fingerprint, client, "tidy up", ops)
    @test record.prev_hash == parent
end
