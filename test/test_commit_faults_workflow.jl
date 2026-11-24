using Test

include("fixtures/commit_model.jl")
include("fixtures/commit_faults.jl")
include("fixtures/commit_checks.jl")

const SEEDS = 1:20
const OUTCOME_KINDS = (:committed, :stale_head, :lost_race, :unknown, :transport)

@testset "commit! under injected faults agrees with the reference model" begin
    outcomes = Outcome[]
    unknown_landed = Bool[]

    # To replay a failing seed: include this file, then `run_trace(seed).failure`.
    @testset "seed $seed" for seed in SEEDS
        trace = run_trace(seed)
        append!(outcomes, trace.outcomes)
        append!(unknown_landed, trace.unknown_landed)
        @test trace.failure === nothing
    end

    @testset "some commit ends as $kind" for kind in OUTCOME_KINDS
        @test count(outcome -> outcome.kind === kind, outcomes) > 0
    end

    @testset "an unknown outcome hides a record that landed, and one that did not" begin
        @test true in unknown_landed
        @test false in unknown_landed
        @test count(outcome -> outcome.detail == (true, :SystemError), outcomes) > 0
        @test count(outcome -> outcome.detail == (nothing, :SimulatedCrash), outcomes) > 0
    end
end
