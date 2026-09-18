using Test
import ChainTables

# ---------------------------------------------------------------------------
# One test file per src file, in the build order of #34 §3. The suite is offline: it
# runs against the doubles and loopback servers with no credentials, reads no
# CHAINTABLES_LIVE_* variable, and makes no request to anything but 127.0.0.1, whatever
# is exported in the shell. The tests only AWS can answer are a separate command,
# test/live/run.sh (ADR-0030), and are never part of `Pkg.test()`.
#
# The suite resolves against the package's own environment. Its one dependency
# of its own is Tables.jl, a test-target extra: test/views.jl proves a TableView
# is a Tables.jl table, and nothing in the package itself depends on Tables.jl
# (ADR-0022, ADR-0024).
# ---------------------------------------------------------------------------

@testset "ChainTables" begin
    @testset "package loads" begin
        @test ChainTables isa Module
    end

    include("fixtures/s3_server.jl")     # the loopback S3: s3.jl, gateway.jl
    include("fixtures/gateway.jl")       # gwtest_record: gateway.jl, live/gateway.jl

    include("hashes.jl")
    include("errors.jl")
    include("cbor.jl")
    include("model.jl")
    include("ops.jl")
    include("builder.jl")
    include("localcopy.jl")
    include("views.jl")
    include("store.jl")
    include("chain.jl")
    include("recovery.jl")
    include("s3.jl")
    include("gateway.jl")
    include("bucket.jl")
    include("Testing.jl")
    include("readme.jl")
    include("tracked_values.jl")
end
