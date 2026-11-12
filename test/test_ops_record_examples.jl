using Test
using ExplicitImports: check_all_explicit_imports_are_public,
    check_all_qualified_accesses_are_public
using ChainTables: Ops

@testset "Client example" begin
    # The client map of a record: host and author may be left out as `nothing`.
    client = Ops.Client("laptop", "alice", "ChainTables 0.3.3", "1.13.2", 1_700_000_000_000)
    @test client.user == "alice"
    @test Ops.Client(nothing, nothing, "ChainTables 0.3.3", "1.13.2", 0).host === nothing
end

@testset "Record example" begin
    client = Ops.Client(nothing, "alice", "ChainTables 0.3.3", "1.13.2", 1_700_000_000_000)
    # The genesis record at slot 0 has no parent and no op.
    chain_id = fill(0x01, 16)
    genesis = Ops.Record(chain_id, 0, nothing, fill(0x02, 32), client, nothing, [])
    @test genesis.slot == 0
    @test isempty(genesis.ops)
end

@testset "the examples use only public names" begin
    @test check_all_explicit_imports_are_public(@__MODULE__, @__FILE__) === nothing
    @test check_all_qualified_accesses_are_public(@__MODULE__, @__FILE__) === nothing
end
