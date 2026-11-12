# A commit end to end through the gateway double into the loopback S3 (ADR-0028): the
# author from the STS double in every record, the refusals, the retry loop, the cap.
using Test
using ChainTables: ChainTables, Chain, Credentials, GatewayMismatchError,
    WriteBuilderError, WriteRefusedError, column!, commit!, create_chain, create_table!,
    head, insert_rows!, open, primary_key!, sync!, table, write_builder

include("fixtures/s3_server.jl")
include("fixtures/gateway_server.jl")

const SESSION = Credentials("AKIATEST", "topsecret"; session_token = "session-token")
const ALICE = "alice@example.com"
const ALICE_ARN = "arn:aws:sts::123456789012:assumed-role/writer/$ALICE"
const DOUBLES = (SESSION, ALICE, ["exp" => [ALICE]])

decode_record(bytes, slot) = ChainTables.Ops.decode_record(bytes; slot)

function gated_chain(store, prefix, cache_dir)
    return Chain("bkt", prefix; store, cache_dir, assume_first_writer_wins = true)
end

# A chain on a gateway store and its copy synced at slot 0, beside the doubles.
function with_gateway_copy(f)
    return with_gateway_doubles(DOUBLES...; arn = ALICE_ARN) do d
        mktempdir() do dir
            chain = gated_chain(d.store, "exp/run-1", joinpath(dir, "cache"))
            created = create_chain(chain)
            copy = open(chain, joinpath(dir, "a"))
            sync!(copy)
            f((; d.s3, d.double, d.gw, d.sts, chain, created, copy, dir))
            close(copy)
        end
    end
end

puts(gw) = count(r -> r.method == "PUT", gw.requests)

function note_builder(copy, id, note)
    w = write_builder(copy)
    create_table!(w, :samples) do t
        column!(t, :id, Int64)
        column!(t, :note, String)
        primary_key!(t, :id)
    end
    insert_rows!(w, :samples, [(; id, note)])
    return w
end

@testset "create_chain writes slot 0 through the gateway, authored from STS" begin
    with_gateway_copy() do g
        @test g.created.slot == 0
        @test length(g.sts.requests) == 1 && puts(g.gw) == 1
        @test !any(r -> r.method == "PUT", g.s3.requests)
        genesis = decode_record(g.s3.objects["exp/run-1/000000000000"], 0)
        @test genesis.client.user == ALICE
    end
end

@testset "commit! writes through the gateway with the memoized author" begin
    with_gateway_copy() do g
        done = commit!(note_builder(g.copy, 1, "through the gateway"); comment = "gated")
        @test done.slot == 1
        @test length(g.sts.requests) == 1 && puts(g.gw) == 2
        record = decode_record(g.s3.objects["exp/run-1/000000000001"], 1)
        @test (record.client.user, record.comment) == (ALICE, "gated")
        other = open(g.chain, joinpath(g.dir, "b"))
        @test sync!(other).slot == 1
        @test table(other, :samples)[1].note == "through the gateway"
        close(other)
    end
end

@testset "commit! raises a policy refusal for the slot, never retried" begin
    with_gateway_copy() do g
        g.double.caller = "bob@example.com"
        w = note_builder(g.copy, 1, "refused")
        e = (@test_throws WriteRefusedError "refused to fill the slot" commit!(w)).value
        @test (e.reason, e.slot, e.caller) == ("not_allowed", 1, ALICE)
        @test (e.key, e.chain_id) == ("exp/run-1/000000000001", g.created.chain_id)
        @test puts(g.gw) == 2 && head(g.copy).slot == 0
        @test_throws WriteBuilderError "this builder is spent" commit!(w)
    end
end

# The put lands, then its reply is lost.
function losing_reply(double)
    return req -> begin
        double.respond = Returns(nothing)
        double(req)
        gwtest_json(502, "s3_error", "reply lost")
    end
end

@testset "commit! survives a lost reply: the read-back finds our record" begin
    with_gateway_copy() do g
        g.double.respond = losing_reply(g.double)
        @test commit!(note_builder(g.copy, 1, "lost reply")).slot == 1
        @test puts(g.gw) == 2
    end
end

@testset "commit! retries a throttle" begin
    with_gateway_copy() do g
        throttle = gwtest_json(429, "throttled", "slow down")
        g.double.respond = req -> (g.double.respond = Returns(nothing); throttle)
        @test commit!(note_builder(g.copy, 1, "throttled once")).slot == 1
        @test puts(g.gw) == 3
    end
end

@testset "commit! refuses a record over 4 MiB before any put" begin
    with_gateway_copy() do g
        w = note_builder(g.copy, 1, "x"^(4 * 1024 * 1024 + 100))
        @test_throws WriteBuilderError "4194304" commit!(w)
        @test puts(g.gw) == 1 && head(g.copy).slot == 0
    end
end

@testset "create_chain raises a gateway that fills another bucket, never retried" begin
    with_gateway_doubles(DOUBLES...; arn = ALICE_ARN, filled_bucket = "other") do d
        mktempdir() do dir
            chain = gated_chain(d.store, "exp/run-2", dir)
            says = "the bucket does not hold the object"
            e = (@test_throws GatewayMismatchError says create_chain(chain)).value
            @test (e.slot, e.key) == (0, "exp/run-2/000000000000")
            @test (e.bucket, e.gateway) == ("bkt", loopback_url(d.gw))
            @test count(r -> r.method == "PUT", d.gw.requests) == 1
        end
    end
end
