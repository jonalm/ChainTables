using Test
using ChainTables: CBOR, MalformedRecordError, Ops, WriteBuilderError
using ChainTables.Ops: Client, CreateTable, DropTable, Insert, Op, Record
using SHA: sha256

include("fixtures/records.jl")

const SLOT_1 = record_at(1, [DropTable("t")])
const SLOT_1_BYTES = Ops.encode_record(SLOT_1)
const SLOT_1_WIRE = Ops.wire(SLOT_1)
const GOOD_CLIENT = Dict{String, Any}("lib" => "L", "julia" => "J", "time_ms" => 1)
const RECORD_CAP = 64 * 1024 * 1024
const UNKNOWN_OP = Dict{String, Any}("op" => "nope", "table" => "t")
const BOOL_INSERT = Dict{String, Any}(
    "op" => "insert", "table" => "t", "rows" => Any[Any[true]]
)
const NEXT_MOVE = "the chain is dead beyond this slot; a new chain is the recovery"

# The wire form of the slot 1 record with fields replaced, added, or (`nothing`) removed.
function changed(; changes...)
    wire = copy(SLOT_1_WIRE)
    for (field, value) in changes
        value === nothing ? delete!(wire, string(field)) : (wire[string(field)] = value)
    end
    return wire
end

client_with(extra...) = merge(GOOD_CLIENT, Dict{String, Any}(extra...))
client_without(field) = delete!(copy(GOOD_CLIENT), field)

function with_second_column_named(name)
    wire = Ops.wire(record_at(2, [CreateTable("u", ID_V_SHAPE)]))
    wire["ops"][1]["shape"]["columns"][2][1] = name
    return wire
end

decoded(wire; slot = nothing) = Ops.decode_record(CBOR.encode(wire); slot)

const ENVELOPE_REFUSALS = [
    (
        wire = changed(; extra = 1), slot = nothing,
        fragment = "unknown envelope field \"extra\"",
    ),
    (
        wire = changed(; format_version = 2), slot = nothing,
        fragment = "format_version 2 is above this client's maximum, 1; " *
            "a newer client wrote it: upgrade ChainTables",
    ),
    (
        wire = changed(; format_version = 0), slot = nothing,
        fragment = "format_version 0 is not a version this client reads",
    ),
    (
        wire = changed(; format_version = "1"), slot = nothing,
        fragment = "format_version is not an integer",
    ),
    (
        wire = changed(; format_version = nothing), slot = nothing,
        fragment = "record has no \"format_version\"",
    ),
    (
        wire = changed(; client = nothing), slot = nothing,
        fragment = "record has no \"client\"",
    ),
    (wire = changed(; chain_id = "x"), slot = nothing, fragment = "chain_id is not bytes"),
    (
        wire = changed(; chain_id = UInt8[1, 2]), slot = nothing,
        fragment = "chain_id is 2 bytes; a chain id is 16",
    ),
    (wire = changed(; slot = 1.0), slot = nothing, fragment = "slot is not an integer"),
    (wire = changed(; slot = 0), slot = nothing, fragment = "slot 0 carries a prev_hash"),
    (wire = changed(; comment = 1), slot = nothing, fragment = "comment is not text"),
    (wire = changed(; ops = 1), slot = nothing, fragment = "ops is not an array"),
    (wire = changed(; ops = Any[]), slot = 1, fragment = "record has no ops"),
    (
        wire = changed(; slot = 0, prev_hash = nothing), slot = 0,
        fragment = "malformed record at slot 0: slot 0 carries 1 op; genesis carries none",
    ),
    (wire = changed(; ops = Any[1]), slot = nothing, fragment = "op 1: op is not a map"),
    (
        wire = changed(; ops = Any[SLOT_1_WIRE["ops"][1], UNKNOWN_OP]),
        slot = nothing, fragment = "op 2: unknown op \"nope\"",
    ),
    (wire = changed(; client = 1), slot = nothing, fragment = "client is not a map"),
    (
        wire = changed(; client = client_with("pid" => 1)), slot = nothing,
        fragment = "unknown client field \"pid\"",
    ),
    (
        wire = changed(; client = client_without("lib")), slot = nothing,
        fragment = "client has no \"lib\"",
    ),
    (
        wire = changed(; client = client_without("time_ms")), slot = nothing,
        fragment = "client has no \"time_ms\"",
    ),
    (
        wire = changed(; client = client_with("time_ms" => 1.0)), slot = nothing,
        fragment = "client.time_ms is not an integer",
    ),
    (
        wire = changed(; client = client_with("host" => 1)), slot = nothing,
        fragment = "client.host is not text",
    ),
    # The slot the bytes were fetched from must be the slot the record names (ADR-0002).
    (
        wire = SLOT_1_WIRE, slot = 3,
        fragment = "malformed record at slot 3: the record names slot 1",
    ),
    # A column name starting with `_` (ADR-0032), or ending in a newline, is refused
    # when the shape of a create_table is read.
    (
        wire = with_second_column_named("_v"), slot = 2,
        fragment = "malformed record at slot 2: op 1: " *
            "column name \"_v\" is not an identifier",
    ),
    (
        wire = with_second_column_named("v\n"), slot = 2,
        fragment = "malformed record at slot 2: op 1: " *
            "column name \"v\\n\" is not an identifier",
    ),
    # A cell is a typed value or null, whatever its column: a bool is neither.
    (
        wire = changed(; ops = Any[BOOL_INSERT]),
        slot = 1,
        fragment = "malformed record at slot 1: op 1: \"rows\" of an insert op holds " *
            "a value of type Bool, which is not a typed value",
    ),
]

# Keys sort bytewise on their encoded form, so by length first: ops, slot, client,
# chain_id, prev_hash, format_version, state_fingerprint. Inside client: lib, julia,
# time_ms. No comment.
@testset "encode_record writes the bytes written out by hand" begin
    op_hex = "a2 62 6f70 6a 64726f705f7461626c65 65 7461626c65 61 74"
    hex = "a7 63 6f7073 81 $op_hex 64 736c6f74 01 66 636c69656e74 a3 63 6c6962 61 4c " *
        "65 6a756c6961 61 4a 67 74696d655f6d73 01 68 636861696e5f6964 50 " *
        "000102030405060708090a0b0c0d0e0f 69 707265765f68617368 5820 " * "bb"^32 *
        " 6e 666f726d61745f76657273696f6e 01 71 73746174655f66696e6765727072696e74 5820 " *
        "aa"^32
    @test bytes2hex(@inferred(Ops.encode_record(SLOT_1))) == replace(hex, " " => "")
end

@testset "encode_record refuses a record over the cap, with the byte count" begin
    big = record_at(1, [Insert("t", [Any[1, zeros(UInt8, RECORD_CAP)]])])
    @test_throws(
        WriteBuilderError,
        "record is 67109077 bytes; the cap is 67108864 bytes (64 MiB): split the write",
        Ops.encode_record(big)
    )
end

@testset "transaction_hash is the SHA-256 of the separator and the stored bytes" begin
    expected = sha256(vcat(codeunits("chaintables/v1/txn"), SLOT_1_BYTES))
    @test @inferred(Ops.transaction_hash(SLOT_1_BYTES)) == expected
    @test length(Ops.transaction_hash(SLOT_1_BYTES)) == 32
end

@testset "decode_record reads back what encode_record wrote" begin
    @test @inferred(Ops.decode_record(SLOT_1_BYTES)) == SLOT_1
    @test Ops.decode_record(SLOT_1_BYTES; slot = 1) == SLOT_1
end

@testset "decode_record reads the genesis record: no ops, no prev_hash" begin
    genesis = record_at(0, Op[])
    @test Ops.decode_record(Ops.encode_record(genesis); slot = 0) == genesis
    @test isempty(decoded(changed(; slot = 0, prev_hash = nothing, ops = Any[])).ops)
end

@testset "decode_record reads every optional field: host, user and comment" begin
    client = Client("h", "u", "L", "J", 2)
    ops = [DropTable("t"), DropTable("u")]
    full = Record(RECORD_CHAIN_ID, 1, RECORD_PARENT, RECORD_FINGERPRINT, client, "why", ops)
    back = Ops.decode_record(Ops.encode_record(full); slot = 1)
    @test back == full
    @test back.prev_hash == RECORD_PARENT
    @test back.client.host == "h"
    @test back.comment == "why"
end

@testset "decode_record refuses an envelope that breaks a rule" begin
    @testset "$(case.fragment)" for case in ENVELOPE_REFUSALS
        @test_throws(
            MalformedRecordError, case.fragment, decoded(case.wire; slot = case.slot)
        )
    end
end

@testset "decode_record names the slot and the chain, and gives the next move" begin
    err = (
        @test_throws MalformedRecordError "malformed record at slot 1" decoded(
            changed(; extra = 1)
        )
    ).value
    @test err.slot == 1
    @test err.chain_id == "AAAQEAYEAUDAOCAJBIFQYDIOB4"
    @test err.op === nothing
    @test occursin(NEXT_MOVE, err.msg)
end

@testset "decode_record refuses bytes that are not the format's CBOR" begin
    @test_throws(
        MalformedRecordError,
        "malformed record at slot 5: not deterministic CBOR (byte 0: ",
        Ops.decode_record(UInt8[0xff]; slot = 5)
    )
end

@testset "decode_record refuses trailing bytes" begin
    @test_throws(
        MalformedRecordError, "trailing bytes", Ops.decode_record(vcat(SLOT_1_BYTES, 0x00))
    )
end

@testset "decode_record refuses an item that is not a map" begin
    @test_throws(
        MalformedRecordError, "record is not a map", Ops.decode_record(CBOR.encode(1))
    )
end

@testset "decode_record refuses bytes over the cap" begin
    @test_throws(
        MalformedRecordError,
        "malformed record at slot 0: record is 67108865 bytes; the cap is 67108864",
        Ops.decode_record(zeros(UInt8, RECORD_CAP + 1); slot = 0)
    )
end
