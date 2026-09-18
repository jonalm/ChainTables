using Test
import ChainTables

# ---------------------------------------------------------------------------
# One test file per src file, in the build order of #34 §3. Everything before
# step 7 runs against the double with no credentials. The live half — one
# test against the real bucket (#34 §2 "Live S3", issue #6) — lives in
# test/s3.jl and needs:
#
#     CHAINTABLES_TEST_BUCKET=<bucket> AWS_REGION=<region> aws-vault exec <profile> -- \
#         julia --project -e 'using Pkg; Pkg.test()'
#
# It is skipped without CHAINTABLES_TEST_BUCKET; no bucket, region or profile has a default,
# because those belong to whoever owns the deployment and never to this repository.
#
# The live gateway test (ADR-0028, issue #60) lives in test/gateway.jl and runs as an
# Identity Center writer (docs/gateway-setup.md) under an `aws sso login` session. It is
# skipped without CHAINTABLES_GATEWAY_URL; with it, every variable below is required and
# none has a default. The region is the function URL's unless AWS_REGION says otherwise.
#
#     aws sso login --profile <profile>               # --use-device-code if the browser balks
#     CHAINTABLES_GATEWAY_URL=https://<id>.lambda-url.<region>.on.aws \
#     CHAINTABLES_GATEWAY_BUCKET=<bucket> \
#     CHAINTABLES_GATEWAY_PREFIX=<a prefix the gateway policy lists you under> \
#     CHAINTABLES_GATEWAY_UNLISTED_PREFIX=<a prefix it does not> \
#     AWS_PROFILE=<profile> \
#         julia --project -e 'using Pkg; Pkg.test()'
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
end
