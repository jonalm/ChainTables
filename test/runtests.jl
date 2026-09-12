using Test
import ChainTables

# ---------------------------------------------------------------------------
# One test file per src file, in the build order of #34 §3. Everything before
# step 7 runs against the double with no credentials. The live half — one
# test against the real bucket (#34 §2 "Live S3", issue #6) — lives in
# test/s3.jl and needs:
#
#     aws-vault exec chaintables-test -- \
#         julia --project -e 'using Pkg; Pkg.test()'
#
# The suite resolves against the package's own environment; it declares no
# dependency of its own.
# ---------------------------------------------------------------------------

@testset "ChainTables" begin
    @testset "package loads" begin
        @test ChainTables isa Module
    end

    include("errors.jl")
    include("cbor.jl")
    include("model.jl")
    include("ops.jl")
    include("builder.jl")
    include("localcopy.jl")
    include("store.jl")
    include("s3.jl")
    include("Testing.jl")
end
