# `create_chain` and `commit!` through the loopback gateway into the loopback S3, with the
# author from the STS double. The store is built directly, to point it at the doubles.
using Test
using ChainTables: ChainTables, Chain, GatewayMismatchError, Ops, WriteBuilderError,
    WriteRefusedError, column!, commit!, create_chain, create_table!, head, insert_rows!,
    primary_key!, sync!, table, write_builder

include("fixtures/s3_server.jl")
include("fixtures/gateway_double.jl")

const PREFIX = "exp/run-1"
const POLICY = ["exp" => [ALICE]]
const SLOT_2 = PREFIX * "/000000000002"
const AWS_REFUSAL = "User: arn:aws:sts::123456789012:assumed-role/x/alice is not authorized"

const REFUSALS = [
    (
        name = "a caller outside the policy", caller = "bob@example.com", policy = POLICY,
        respond = nothing, reason = "not_allowed",
        detail = "bob@example.com may not write under exp/run-1",
    ),
    (
        name = "a caller that the record does not name", caller = "mallory",
        policy = ["exp" => ["mallory"]], respond = nothing, reason = "author_mismatch",
        detail = "the record names '$ALICE' as client.user but the caller is 'mallory'",
    ),
    (
        name = "AWS before the gateway ran", caller = ALICE, policy = POLICY,
        respond = _ -> (403, [], Vector{UInt8}("{\"Message\":\"$AWS_REFUSAL\"}")),
        reason = "forbidden", detail = AWS_REFUSAL,
    ),
]

gateway_puts(world) = count(request -> request.method == "PUT", world.gateway.requests)

function gateway_chain(world, dir; prefix = PREFIX, s3 = world.s3)
    store = gateway_store(world; s3)
    cache_dir = joinpath(dir, "cache")
    return Chain("bkt", prefix; store, cache_dir, assume_first_writer_wins = true)
end

function decoded(world, key, slot)
    return Ops.decode_record(world.s3.objects[key]; slot)
end

function notes_builder(local_copy, id, note)
    w = write_builder(local_copy)
    insert_rows!(w, :samples, [(; id, note)])
    return w
end

function create_samples!(local_copy)
    w = write_builder(local_copy)
    create_table!(w, :samples) do t
        column!(t, :id, Int64)
        column!(t, :note, String)
        primary_key!(t, :id)
    end
    insert_rows!(w, :samples, [(id = 1, note = "through the gateway")])
    return commit!(w; comment = "gated")
end

# A chain through the gateway at slot 1, and a local copy at its head.
function with_gateway_copy(f)
    with_gateway(; policy = POLICY) do world
        mktempdir() do dir
            chain = gateway_chain(world, dir)
            created = create_chain(chain)
            local_copy = ChainTables.open(chain, joinpath(dir, "a"))
            sync!(local_copy)
            committed = create_samples!(local_copy)
            f((; world, dir, chain, created, committed, local_copy))
            close(local_copy)
        end
    end
    return nothing
end

# A gateway that fills the bucket "other", and a chain that reads the bucket "bkt".
function with_mispaired_gateway(f)
    with_s3_server(; bucket = "bkt", credentials = GWTEST_CREDS) do ours
        with_gateway(; bucket = "other", policy = POLICY) do world
            mktempdir(dir -> f(world, gateway_chain(world, dir; s3 = ours)))
        end
    end
    return nothing
end

# The put lands, and its reply is lost.
function lose_reply!(double, request)
    double.respond = _ -> nothing
    double(request)
    return gwtest_json(502, "s3_error", "reply lost")
end

function throttle_once!(double)
    double.respond = _ -> nothing
    return (429, [], Vector{UInt8}("{\"Message\":\"Rate Exceeded.\"}"))
end

@testset "create_chain through a gateway puts slot 0 with the caller from STS" begin
    with_gateway(; policy = POLICY) do world
        mktempdir() do dir
            withenv("USER" => "carol") do
                create_chain(gateway_chain(world, dir))
            end
            @test decoded(world, PREFIX * "/000000000000", 0).client.user == ALICE
            @test length(world.sts.requests) == 1
            @test gateway_puts(world) == 1
            @test !any(request -> request.method == "PUT", world.s3.requests)
        end
    end
end

@testset "commit! through a gateway puts the record under the author fetched once" begin
    with_gateway_copy() do setup
        world = setup.world
        key = PREFIX * "/000000000001"
        record = decoded(world, key, 1)
        @test setup.committed.slot == 1
        @test (record.client.user, record.comment) == (ALICE, "gated")
        @test length(world.sts.requests) == 1
        @test gateway_puts(world) == 2
        @test last(world.gateway.requests).query == ["key" => key]
    end
end

@testset "sync! of another copy reads a gateway bucket through S3" begin
    with_gateway_copy() do setup
        other = ChainTables.open(setup.chain, joinpath(setup.dir, "b"))
        n_requests = length(setup.world.gateway.requests)
        @test sync!(other).slot == 1
        @test table(other, :samples)[1].note == "through the gateway"
        @test length(setup.world.gateway.requests) == n_requests
        close(other)
    end
end

@testset "commit! through a gateway throws the refusal with the chain and the slot" begin
    @testset "$(case.name)" for case in REFUSALS
        with_gateway_copy() do setup
            world = setup.world
            world.double.caller, world.double.policy = case.caller, case.policy
            world.double.respond = something(case.respond, _ -> nothing)
            w = notes_builder(setup.local_copy, 2, "refused")
            e = (@test_throws WriteRefusedError "the gateway refused" commit!(w)).value
            @test (e.chain_id, e.slot, e.key) == (setup.created.chain_id, 2, SLOT_2)
            @test (e.caller, e.reason, e.detail) == (ALICE, case.reason, case.detail)
            @test e.gateway == loopback_url(world.gateway)
            @test gateway_puts(world) == 3
            @test head(setup.local_copy).slot == 1
            @test_throws WriteBuilderError "this builder is spent" commit!(w)
        end
    end
end

@testset "commit! through a gateway whose reply is lost reads its record back" begin
    with_gateway_copy() do setup
        double = setup.world.double
        double.respond = request -> lose_reply!(double, request)
        done = commit!(notes_builder(setup.local_copy, 2, "lost reply"))
        @test done.slot == 2
        @test gateway_puts(setup.world) == 3
        @test decoded(setup.world, SLOT_2, 2).client.user == ALICE
    end
end

@testset "commit! through a gateway retries a throttle" begin
    with_gateway_copy() do setup
        double = setup.world.double
        double.respond = _ -> throttle_once!(double)
        @test commit!(notes_builder(setup.local_copy, 2, "throttled once")).slot == 2
        @test gateway_puts(setup.world) == 4
    end
end

@testset "commit! through a gateway refuses a record over 4 MiB before a put" begin
    with_gateway_copy() do setup
        w = notes_builder(setup.local_copy, 2, "x"^(4 * 1024 * 1024 + 100))
        fragment = "the cap on a GatewayObjectStore is 4194304 bytes (4 MiB)"
        @test_throws WriteBuilderError fragment commit!(w)
        @test gateway_puts(setup.world) == 2
        @test head(setup.local_copy).slot == 1
    end
end

@testset "create_chain through a gateway outside the policy is refused at slot 0" begin
    with_gateway(; policy = POLICY) do world
        mktempdir() do dir
            chain = gateway_chain(world, dir; prefix = "other/run-1")
            e = (@test_throws WriteRefusedError "refused" create_chain(chain)).value
            @test (e.slot, e.key) == (0, "other/run-1/000000000000")
            @test e.reason == "not_allowed"
            @test length(e.chain_id) == 26
            @test isempty(world.s3.objects)
        end
    end
end

@testset "create_chain through a gateway refuses the account root before a put" begin
    with_gateway(; policy = POLICY, arn = "arn:aws:iam::123456789012:root") do world
        mktempdir() do dir
            chain = gateway_chain(world, dir)
            e = (@test_throws WriteRefusedError "not_allowed" create_chain(chain)).value
            @test (e.slot, e.key) == (0, PREFIX * "/000000000000")
            @test e.chain_id isa String
            @test isempty(world.gateway.requests)
        end
    end
end

@testset "create_chain through a gateway that fills another bucket is a mismatch" begin
    with_mispaired_gateway() do world, chain
        fragment = "does not act as the gateway"
        e = (@test_throws GatewayMismatchError fragment create_chain(chain)).value
        @test (e.slot, e.key, e.bucket) == (0, PREFIX * "/000000000000", "bkt")
        @test e.gateway == loopback_url(world.gateway)
        @test e.chain_id isa String
        @test gateway_puts(world) == 1
    end
end
