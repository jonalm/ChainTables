using Test
using ChainTables: ChainTables, ModelError
using ChainTables.Ops: Client, DropTable, Op, Record, local_client, wire

const CHAIN_ID = UInt8.(0:15)
const FINGERPRINT = fill(0xaa, 32)
const PREV = fill(0xbb, 32)
const CLIENT = Client(nothing, nothing, "L", "J", 1)
const ONE_OP = [DropTable("t")]

@testset "Record holds the genesis: slot 0, no parent, no op" begin
    genesis = Record(CHAIN_ID, 0, nothing, FINGERPRINT, CLIENT, nothing, Op[])
    @test genesis.slot == 0
    @test genesis.prev_hash === nothing
    @test isempty(genesis.ops)
end

@testset "Record holds its own copy of the bytes" begin
    chain_id = copy(CHAIN_ID)
    r = Record(chain_id, 1, PREV, FINGERPRINT, CLIENT, nothing, ONE_OP)
    chain_id[1] = 0xff
    @test r.chain_id == CHAIN_ID
end

# Zero ops exactly at slot 0 and at least one everywhere else (ADR-0019, ADR-0032): so
# every row slot is at least 1.
const REFUSED_RECORDS = [
    (
        name = "a 15-byte chain id",
        args = (CHAIN_ID[1:15], 1, PREV, FINGERPRINT, CLIENT, nothing, ONE_OP),
        message = "chain_id is 15 bytes; a chain id is 16",
    ),
    (
        name = "a 31-byte fingerprint",
        args = (CHAIN_ID, 1, PREV, FINGERPRINT[1:31], CLIENT, nothing, ONE_OP),
        message = "state_fingerprint is 31 bytes; a SHA-256 is 32",
    ),
    (
        name = "a 1-byte prev_hash",
        args = (CHAIN_ID, 1, UInt8[0], FINGERPRINT, CLIENT, nothing, ONE_OP),
        message = "prev_hash is 1 bytes; a SHA-256 is 32",
    ),
    (
        name = "a parent at slot 0",
        args = (CHAIN_ID, 0, PREV, FINGERPRINT, CLIENT, nothing, ONE_OP),
        message = "slot 0 carries a prev_hash; genesis has no parent",
    ),
    (
        name = "no parent after slot 0",
        args = (CHAIN_ID, 1, nothing, FINGERPRINT, CLIENT, nothing, ONE_OP),
        message = "slot 1 has no prev_hash; every slot after genesis names its parent",
    ),
    (
        name = "a negative slot",
        args = (CHAIN_ID, -1, nothing, FINGERPRINT, CLIENT, nothing, ONE_OP),
        message = "slot -1 is negative",
    ),
    (
        name = "no op after genesis",
        args = (CHAIN_ID, 1, PREV, FINGERPRINT, CLIENT, nothing, Op[]),
        message = "record has no ops; a record after genesis carries at least one",
    ),
    (
        name = "an op at genesis",
        args = (CHAIN_ID, 0, nothing, FINGERPRINT, CLIENT, nothing, ONE_OP),
        message = "slot 0 carries 1 op; genesis carries none",
    ),
    (
        name = "two ops at genesis",
        args = (
            CHAIN_ID, 0, nothing, FINGERPRINT, CLIENT, nothing,
            [DropTable("t"), DropTable("u")],
        ),
        message = "slot 0 carries 2 ops; genesis carries none",
    ),
    (
        name = "U+0000 in the comment",
        args = (CHAIN_ID, 1, PREV, FINGERPRINT, CLIENT, "a\0b", ONE_OP),
        message = "comment contains U+0000",
    ),
    (
        name = "invalid UTF-8 in the comment",
        args = (CHAIN_ID, 1, PREV, FINGERPRINT, CLIENT, "\xff", ONE_OP),
        message = "comment is not well-formed UTF-8",
    ),
]

@testset "Record refuses $(case.name)" for case in REFUSED_RECORDS
    @test_throws ModelError case.message Record(case.args...)
end

@testset "Client refuses U+0000 in the host" begin
    @test_throws ModelError "client.host contains U+0000" Client("\0", nothing, "L", "J", 1)
end

@testset "Record equals its copy and round-trips through a Set" begin
    a = Record(CHAIN_ID, 1, PREV, FINGERPRINT, Client("h", "u", "L", "J", 2), "why", ONE_OP)
    b = Record(
        copy(CHAIN_ID), 1, copy(PREV), copy(FINGERPRINT), Client("h", "u", "L", "J", 2),
        "why", [DropTable("t")],
    )
    @test a == b
    @test hash(a) == hash(b)
    @test b in Set([a])
    @test (a == b) isa Bool
    @test a != Record(CHAIN_ID, 2, PREV, FINGERPRINT, CLIENT, nothing, ONE_OP)
end

@testset "Client equals its copy and round-trips through a Set" begin
    @test Client("h", nothing, "L", "J", 1) == Client("h", nothing, "L", "J", 1)
    @test Client("h", nothing, "L", "J", 1) in Set([Client("h", nothing, "L", "J", 1)])
end

@testset "wire of a record leaves out what is absent" begin
    genesis = Record(CHAIN_ID, 0, nothing, FINGERPRINT, CLIENT, nothing, Op[])
    @test sort(collect(keys(wire(genesis)))) == [
        "chain_id", "client", "format_version", "ops", "slot", "state_fingerprint",
    ]
    @test sort(collect(keys(wire(genesis)["client"]))) == ["julia", "lib", "time_ms"]
end

@testset "wire of a record carries every optional field present" begin
    w = wire(
        Record(
            CHAIN_ID, 1, PREV, FINGERPRINT, Client("h", "u", "L", "J", 2), "why", ONE_OP,
        ),
    )
    @test w["format_version"] == 1
    @test w["prev_hash"] == PREV
    @test w["comment"] == "why"
    @test w["client"]["time_ms"] == 2
    @test w["client"]["host"] == "h"
end

@testset "local_client describes this machine" begin
    c = local_client(; user = "carol", at = 1.5)
    @test startswith(c.lib, "ChainTables 0.")
    @test c.julia == string(VERSION)
    @test c.host isa String
    @test !isempty(c.host)
    @test c.user == "carol"
    @test c.time_ms == 1500
end

@testset "local_client reads the clock by default" begin
    @test abs(local_client().time_ms - round(Int64, time() * 1000)) < 60_000
end

@testset "local_client leaves out an empty user and, on request, the host" begin
    @test local_client(; user = "").user === nothing
    c = local_client(; record_host = false)
    @test c.host === nothing
    @test c.user === nothing
end

@testset "Client and Record constructors infer" begin
    client = @inferred Client("h", nothing, "L", "J", 1)
    @test client.host == "h"
    record = @inferred Record(CHAIN_ID, 1, PREV, FINGERPRINT, client, nothing, ONE_OP)
    @test record.slot == 1
end
