using Test
using ChainTables: Ops

@testset "encode_record example" begin
    client = Ops.Client(nothing, "carol", "ChainTables 0.3.3", "1.13.2", 1000)
    fingerprint = zeros(UInt8, 32)
    genesis = Ops.Record(UInt8.(0:15), 0, nothing, fingerprint, client, nothing, Ops.Op[])

    # The bytes a store holds for this record: one CBOR map.
    bytes = Ops.encode_record(genesis)
    @test first(bytes) == 0xa6
end

@testset "transaction_hash example" begin
    # The hash of a record is the hash of its stored bytes, 32 bytes long.
    bytes = hex2bytes("a164736c6f7400")
    @test length(Ops.transaction_hash(bytes)) == 32
end

@testset "decode_record example" begin
    client = Ops.Client(nothing, "carol", "ChainTables 0.3.3", "1.13.2", 1000)
    fingerprint = zeros(UInt8, 32)
    genesis = Ops.Record(UInt8.(0:15), 0, nothing, fingerprint, client, nothing, Ops.Op[])
    bytes = Ops.encode_record(genesis)

    # Read the bytes fetched from slot 0. The record must name that slot.
    record = Ops.decode_record(bytes; slot = 0)
    @test record == genesis
end
