using Test
import ChainTables

# ---------------------------------------------------------------------------
# The live suite (ADR-0030): the tests only AWS can answer. It is never part of `Pkg.test()`.
# Run it through its one entry point,
#
#     test/live/run.sh [s3] [gateway]        # no argument: all
#
# which reads the configuration from a file outside the repository (env/live.env, git-ignored;
# test/live/live.env.example lists the variables), checks the login sessions, and runs this
# file. Every variable of a selected test is required and nothing here skips: not selecting a
# test is how it is not run. Every run leaves objects behind for good — the port has no delete
# verb — so what it is about to write to is printed first.
#
# It resolves against the package's own environment; Test and Sockets are standard libraries.
# ---------------------------------------------------------------------------

include("config.jl")
include(joinpath(@__DIR__, "..", "fixtures", "gateway.jl"))

const LIVE_S3_PREFIX = "chaintables-test"       # the live S3 test writes under <this>/<run>

const LIVE_SELECTION = live_selection(ARGS)
const LIVE_CONFIG = Dict(test => live_config(test) for test in LIVE_SELECTION)    # all of it, before any test runs

for test in LIVE_SELECTION
    c = LIVE_CONFIG[test]
    prefix = test === :s3 ? LIVE_S3_PREFIX : c.prefix
    println("live $test test: writes permanent objects under s3://$(c.bucket)/$prefix/<run>/ ($(c.region), profile $(c.profile))")
end

@testset "ChainTables live" begin
    for test in LIVE_SELECTION
        include("$test.jl")
    end
end
