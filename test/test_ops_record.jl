using Test
using ChainTables: Ops
# The rules of the envelope are the format's spec. `commit!` and `decode_record` report
# them through two public errors, so they are tested once here, where they live.
using ChainTables.Model: ModelError
using ChainTables.Ops: Client, DropTable, Op, Record

include("fixtures/internal_errors.jl")
include("fixtures/records.jl")

const ONE_OP = [DropTable("t")]
const NO_OPS = Op[]

# Each case is the constructor's arguments after the chain id: slot, prev_hash,
# state_fingerprint, comment, ops.
const RECORD_REFUSALS = [
    (
        chain_id = RECORD_CHAIN_ID[1:15], slot = 1, parent = RECORD_PARENT,
        fingerprint = RECORD_FINGERPRINT, comment = nothing, ops = ONE_OP,
        fragment = "chain_id is 15 bytes; a chain id is 16",
    ),
    (
        chain_id = RECORD_CHAIN_ID, slot = 1, parent = RECORD_PARENT,
        fingerprint = RECORD_FINGERPRINT[1:31], comment = nothing, ops = ONE_OP,
        fragment = "state_fingerprint is 31 bytes; a SHA-256 is 32",
    ),
    (
        chain_id = RECORD_CHAIN_ID, slot = 1, parent = UInt8[0],
        fingerprint = RECORD_FINGERPRINT, comment = nothing, ops = ONE_OP,
        fragment = "prev_hash is 1 bytes; a SHA-256 is 32",
    ),
    (
        chain_id = RECORD_CHAIN_ID, slot = 0, parent = RECORD_PARENT,
        fingerprint = RECORD_FINGERPRINT, comment = nothing, ops = ONE_OP,
        fragment = "slot 0 carries a prev_hash; genesis has no parent",
    ),
    (
        chain_id = RECORD_CHAIN_ID, slot = 1, parent = nothing,
        fingerprint = RECORD_FINGERPRINT, comment = nothing, ops = ONE_OP,
        fragment = "slot 1 has no prev_hash; every slot after genesis names its parent",
    ),
    (
        chain_id = RECORD_CHAIN_ID, slot = -1, parent = nothing,
        fingerprint = RECORD_FINGERPRINT, comment = nothing, ops = ONE_OP,
        fragment = "slot -1 is negative",
    ),
    # At least one op everywhere but slot 0, so every row slot is at least 1.
    (
        chain_id = RECORD_CHAIN_ID, slot = 1, parent = RECORD_PARENT,
        fingerprint = RECORD_FINGERPRINT, comment = nothing, ops = NO_OPS,
        fragment = "record has no ops; a record after genesis carries at least one",
    ),
    (
        chain_id = RECORD_CHAIN_ID, slot = 0, parent = nothing,
        fingerprint = RECORD_FINGERPRINT, comment = nothing, ops = ONE_OP,
        fragment = "slot 0 carries 1 op; genesis carries none",
    ),
    (
        chain_id = RECORD_CHAIN_ID, slot = 1, parent = RECORD_PARENT,
        fingerprint = RECORD_FINGERPRINT, comment = "a\0b", ops = ONE_OP,
        fragment = "comment contains U+0000",
    ),
    (
        chain_id = RECORD_CHAIN_ID, slot = 1, parent = RECORD_PARENT,
        fingerprint = RECORD_FINGERPRINT, comment = "\xff", ops = ONE_OP,
        fragment = "comment is not well-formed UTF-8",
    ),
]

function record_of(case)
    return Record(
        case.chain_id, case.slot, case.parent, case.fingerprint, RECORD_CLIENT,
        case.comment, case.ops
    )
end

@testset "Client holds who wrote a record, with what, and when" begin
    client = @inferred Client("h", "u", "L", "J", 2)
    @test (client.host, client.user, client.lib, client.julia) == ("h", "u", "L", "J")
    @test client.time_ms === Int64(2)
end

@testset "Client refuses text holding U+0000" begin
    @test_throws ModelError "client.host contains U+0000" Client("\0", nothing, "L", "J", 1)
end

@testset "Record holds the envelope of a record after genesis" begin
    record = @inferred Record(
        RECORD_CHAIN_ID, 1, RECORD_PARENT, RECORD_FINGERPRINT, RECORD_CLIENT, "why", ONE_OP
    )
    @test record.slot == 1
    @test record.prev_hash == RECORD_PARENT
    @test record.comment == "why"
    @test record.ops == ONE_OP
end

@testset "Record at slot 0 is the genesis: no parent and no ops" begin
    genesis = record_at(0, NO_OPS)
    @test genesis.prev_hash === nothing
    @test isempty(genesis.ops)
end

@testset "Record refuses an envelope that breaks a rule" begin
    @testset "$(case.fragment)" for case in RECORD_REFUSALS
        @test_throws ModelError as_shown(case.fragment) record_of(case)
    end
end

@testset "Record leaves out of its wire form what is absent" begin
    fields = sort(collect(keys(Ops.wire(record_at(0, NO_OPS)))))
    @test fields ==
        ["chain_id", "client", "format_version", "ops", "slot", "state_fingerprint"]
end

@testset "Record writes format_version 1 and the client map" begin
    client = Client("h", "u", "L", "J", 2)
    record = Record(
        RECORD_CHAIN_ID, 1, RECORD_PARENT, RECORD_FINGERPRINT, client, "why", ONE_OP
    )
    wire = Ops.wire(record)
    @test wire["format_version"] == 1
    @test wire["client"]["time_ms"] == 2
    @test wire["client"]["host"] == "h"
end

@testset "Record conforms: equal records are one key of a Dict, one member of a Set" begin
    record = record_at(1, ONE_OP)
    twin = record_at(1, [DropTable("t")])
    other = record_at(2, ONE_OP)
    @test (record == twin) === true
    @test (record == other) === false
    @test hash(record) == hash(twin)
    @test Dict(record => 1)[twin] == 1
    @test length(Set([record, twin, other])) == 2
end

@testset "local_client names this package, this Julia and this host" begin
    client = @inferred Ops.local_client(; user = "carol")
    @test startswith(client.lib, "ChainTables 0.")
    @test client.julia == string(VERSION)
    @test client.host == gethostname()
    @test client.user == "carol"
end

@testset "local_client stamps the time in milliseconds" begin
    # A fixed clock: production reads `time()`.
    @test Ops.local_client(; at = 1.7e9).time_ms == 1_700_000_000_000
end

@testset "local_client leaves out an empty user" begin
    @test Ops.local_client(; user = "").user === nothing
    @test Ops.local_client().user === nothing
end

@testset "local_client leaves out the host on request" begin
    # A fixed host name: production reads `gethostname()`.
    @test Ops.local_client(; host = "box").host == "box"
    client = Ops.local_client(; record_host = false, host = "box")
    @test client.host === nothing
    record = Record(
        RECORD_CHAIN_ID, 1, RECORD_PARENT, RECORD_FINGERPRINT, client, nothing, ONE_OP
    )
    @test !haskey(Ops.wire(record)["client"], "host")
end
