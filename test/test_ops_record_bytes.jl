using Test
using ChainTables: ChainTables, CBOR, MalformedRecordError, WriteBuilderError
using ChainTables.Ops: Client, DropTable, Insert, Op, Record, decode_record, encode_record,
    transaction_hash, wire
using SHA: sha256

const CHAIN_ID = UInt8.(0:15)
const FINGERPRINT = fill(0xaa, 32)
const PREV = fill(0xbb, 32)
const PREV0 = UInt8.(0:31)
const CLIENT = Client(nothing, nothing, "L", "J", 1)
const RECORD = Record(CHAIN_ID, 1, PREV0, FINGERPRINT, CLIENT, nothing, [DropTable("t")])
const GENESIS = Record(CHAIN_ID, 0, nothing, FINGERPRINT, CLIENT, nothing, Op[])

# Keys sort bytewise on their encoded form, so by length first: ops, slot, client,
# chain_id, prev_hash, format_version, state_fingerprint; inside client: lib, julia,
# time_ms. The comment is absent.
const OP_HEX = "a2 62 6f70 6a 64726f705f7461626c65 65 7461626c65 61 74"
const RECORD_HEX = "a7 63 6f7073 81 $OP_HEX 64 736c6f74 01 66 636c69656e74 " *
    "a3 63 6c6962 61 4c " *
    "65 6a756c6961 61 4a 67 74696d655f6d73 01 68 636861696e5f6964 50 " *
    "000102030405060708090a0b0c0d0e0f 69 707265765f68617368 5820 $(bytes2hex(PREV0)) " *
    "6e 666f726d61745f76657273696f6e 01 71 73746174655f66696e6765727072696e74 5820 " *
    "aa"^32

@testset "encode_record writes the record as written by hand" begin
    @test bytes2hex(encode_record(RECORD)) == replace(RECORD_HEX, " " => "")
end

@testset "transaction_hash hashes the separator and the stored bytes" begin
    bytes = encode_record(RECORD)
    @test transaction_hash(bytes) == sha256(vcat(codeunits("chaintables/v1/txn"), bytes))
    @test length(transaction_hash(bytes)) == 32
end

@testset "decode_record reads back what encode_record wrote" begin
    bytes = encode_record(RECORD)
    @test decode_record(bytes) == RECORD
    @test decode_record(bytes; slot = 1) == RECORD
    @test decode_record(encode_record(GENESIS); slot = 0) == GENESIS
end

@testset "decode_record reads every optional field" begin
    full = Record(
        CHAIN_ID, 1, PREV, FINGERPRINT, Client("h", "u", "L", "J", 2), "why",
        [DropTable("t"), DropTable("u")],
    )
    back = decode_record(encode_record(full); slot = 1)
    @test back == full
    @test back.prev_hash == PREV
    @test back.client.host == "h"
    @test back.comment == "why"
end

# A copy of the wire form `w` with fields set, or removed where the value is `nothing`.
function with_fields(w; changes...)
    d = copy(w)
    for (k, v) in changes
        v === nothing && delete!(d, string(k))
        v === nothing || (d[string(k)] = v)
    end
    return d
end

const W = wire(RECORD)
client_wire(pairs...) = Dict{String, Any}(pairs...)

const REFUSED_ENVELOPES = [
    (
        name = "an unknown field",
        wire = with_fields(W; extra = 1),
        message = "unknown envelope field \"extra\"",
    ),
    (
        name = "a newer format_version",
        wire = with_fields(W; format_version = 2),
        message = "format_version 2 is above this client's maximum, 1; a newer client " *
            "wrote it: upgrade ChainTables",
    ),
    (
        name = "format_version 0",
        wire = with_fields(W; format_version = 0),
        message = "format_version 0 is not a version this client reads",
    ),
    (
        name = "a text format_version",
        wire = with_fields(W; format_version = "1"),
        message = "format_version is not an integer",
    ),
    (
        name = "no format_version",
        wire = with_fields(W; format_version = nothing),
        message = "record has no \"format_version\"",
    ),
    (
        name = "no client",
        wire = with_fields(W; client = nothing),
        message = "record has no \"client\"",
    ),
    (
        name = "a text chain_id",
        wire = with_fields(W; chain_id = "x"),
        message = "chain_id is not bytes",
    ),
    (
        name = "a 2-byte chain_id",
        wire = with_fields(W; chain_id = UInt8[1, 2]),
        message = "chain_id is 2 bytes; a chain id is 16",
    ),
    (
        name = "a float slot",
        wire = with_fields(W; slot = 1.0),
        message = "slot is not an integer",
    ),
    (
        name = "a parent at slot 0",
        wire = with_fields(W; slot = 0),
        message = "slot 0 carries a prev_hash",
    ),
    (
        name = "a comment that is no text",
        wire = with_fields(W; comment = 1),
        message = "comment is not text",
    ),
    (
        name = "ops that are no array",
        wire = with_fields(W; ops = 1),
        message = "ops is not an array",
    ),
    (
        name = "an op that is no map",
        wire = with_fields(W; ops = Any[1]),
        message = "op 1: op is not a map",
    ),
    (
        name = "an unknown op",
        wire = with_fields(
            W; ops = Any[W["ops"][1], Dict{String, Any}("op" => "nope", "table" => "t")],
        ),
        message = "op 2: unknown op \"nope\"",
    ),
    (
        name = "a client that is no map",
        wire = with_fields(W; client = 1),
        message = "client is not a map",
    ),
    (
        name = "an unknown client field",
        wire = with_fields(
            W; client = client_wire(
                "lib" => "L", "julia" => "J", "time_ms" => 1, "pid" => 1,
            ),
        ),
        message = "unknown client field \"pid\"",
    ),
    (
        name = "a client without lib",
        wire = with_fields(W; client = client_wire("julia" => "J", "time_ms" => 1)),
        message = "client has no \"lib\"",
    ),
    (
        name = "a float time_ms",
        wire = with_fields(
            W; client = client_wire("lib" => "L", "julia" => "J", "time_ms" => 1.0),
        ),
        message = "client.time_ms is not an integer",
    ),
    (
        name = "a host that is no text",
        wire = with_fields(
            W; client = client_wire(
                "lib" => "L", "julia" => "J", "time_ms" => 1, "host" => 1,
            ),
        ),
        message = "client.host is not text",
    ),
]

@testset "decode_record refuses $(case.name)" for case in REFUSED_ENVELOPES
    @test_throws MalformedRecordError case.message decode_record(CBOR.encode(case.wire))
end

function malformed(bytes; slot = nothing)
    try
        decode_record(bytes; slot)
    catch e
        e isa MalformedRecordError || rethrow()
        return e
    end
    return nothing
end

@testset "decode_record names the slot and chain id as Evidence" begin
    e = malformed(CBOR.encode(with_fields(W; extra = 1)))
    @test e.slot == 1
    @test e.chain_id == "AAAQEAYEAUDAOCAJBIFQYDIOB4"
    @test occursin("slot = 1", sprint(showerror, e))
end

@testset "decode_record requires the slot it was fetched from" begin
    e = malformed(CBOR.encode(W); slot = 3)
    @test e.slot == 3
    @test e.detail == "the record names slot 1"
end

@testset "decode_record reads a genesis and refuses an empty record after it" begin
    genesis_wire = with_fields(W; slot = 0, prev_hash = nothing, ops = Any[])
    @test isempty(decode_record(CBOR.encode(genesis_wire)).ops)
    @test_throws(
        MalformedRecordError, "record has no ops",
        decode_record(CBOR.encode(with_fields(W; ops = Any[])); slot = 1),
    )
    e = malformed(CBOR.encode(with_fields(W; slot = 0, prev_hash = nothing)); slot = 0)
    @test e.slot == 0
    @test startswith(e.detail, "slot 0 carries 1 op; genesis carries none")
end

@testset "decode_record refuses bytes that are not the format's CBOR" begin
    e = malformed(UInt8[0xff]; slot = 5)
    @test e.slot == 5
    @test startswith(e.detail, "not deterministic CBOR (byte 0: ")
    @test_throws(
        MalformedRecordError, "trailing bytes",
        decode_record(vcat(encode_record(RECORD), 0x00)),
    )
    @test_throws MalformedRecordError "record is not a map" decode_record(CBOR.encode(1))
end

@testset "MalformedRecordError ends with its next move" begin
    @test_throws "The chain cannot be read beyond this slot" decode_record(
        CBOR.encode(with_fields(W; extra = 1)),
    )
end

# A column name starting with _ (ADR-0032), or ending in a newline, is refused when a
# create_table's shape is read.
const BAD_COLUMN_NAMES = [
    (name = "_v", message = "op 1: column name \"_v\" is not an identifier"),
    (name = "v\n", message = "op 1: column name \"v\\n\" is not an identifier"),
]

@testset "decode_record refuses column $(repr(case.name))" for case in BAD_COLUMN_NAMES
    shape = Dict{String, Any}(
        "columns" => Any[Any["id", "int64", false], Any[case.name, "text", true]],
        "key" => Any["id"],
    )
    op = Dict{String, Any}("op" => "create_table", "table" => "u", "shape" => shape)
    @test_throws MalformedRecordError case.message decode_record(
        CBOR.encode(with_fields(W; slot = 2, ops = Any[op])); slot = 2,
    )
end

const BIG = Record(
    CHAIN_ID, 1, PREV, FINGERPRINT, CLIENT, nothing,
    [Insert("t", [Any[1, zeros(UInt8, 64 * 1024 * 1024)]])],
)

@testset "encode_record refuses a record over the 64 MiB cap" begin
    @test_throws(
        WriteBuilderError,
        "record is 67109077 bytes; the cap is 67108864 bytes (64 MiB): split the " *
            "write",
        encode_record(BIG),
    )
end

@testset "decode_record refuses bytes over the 64 MiB cap" begin
    @test_throws(
        MalformedRecordError, "record is 67108865 bytes; the cap is 67108864",
        decode_record(zeros(UInt8, 64 * 1024 * 1024 + 1); slot = 0),
    )
end

@testset "encode_record and decode_record infer" begin
    bytes = @inferred encode_record(RECORD)
    @test @inferred(decode_record(bytes)) == RECORD
end
