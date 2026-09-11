using Test
import S3SQLite

# ---------------------------------------------------------------------------
# The suite is offline-only. The live half — a smoke test of credentials,
# transport and bucket, then whatever only a real S3 bucket can answer about
# the commit protocol — returns with ADR-0010's object-store port. Issue #6
# holds the bucket, the IAM user and the invocation it needs:
#
#     aws-vault exec s3sqlite-test -- \
#         julia --project -e 'using Pkg; Pkg.test()'
#
# The suite resolves against the package's own environment; it declares no
# dependency of its own.
# ---------------------------------------------------------------------------

@testset "S3SQLite" begin

    @testset "package loads" begin
        @test S3SQLite isa Module
    end

    # Everything the design decides — record encoding, the op set, replay, the
    # state fingerprint, conflict resolution against a fake S3 — lands here.
    # None of it is implemented yet; the design is still deciding it.
    #
    # What is here already pins the dependency's behaviour rather than ours,
    # because the design rests on it (see #21).
    include("sqlite_jl_marshalling.jl")

end
