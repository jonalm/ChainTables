using Test
using ExplicitImports: check_all_explicit_imports_are_public,
    check_all_qualified_accesses_are_public
using ChainTables: Ops

const CLIENT = Ops.Client(
    nothing, "alice", "ChainTables 0.3.3", "1.13.2", 1_700_000_000_000,
)
const GENESIS = Ops.Record(fill(0x01, 16), 0, nothing, fill(0x02, 32), CLIENT, nothing, [])

@testset "encode_record example" begin
    # A record's stored bytes: one deterministic CBOR map.
    bytes = Ops.encode_record(GENESIS)
    @test first(bytes) == 0xa6 # a map of six fields: no prev_hash, no comment at genesis
end

@testset "decode_record example" begin
    bytes = Ops.encode_record(GENESIS)
    # Pass the slot the bytes were fetched from; the record must name it.
    @test Ops.decode_record(bytes; slot = 0) == GENESIS
end

@testset "the examples use only public names" begin
    @test check_all_explicit_imports_are_public(@__MODULE__, @__FILE__) === nothing
    @test check_all_qualified_accesses_are_public(@__MODULE__, @__FILE__) === nothing
end
