using Test
import S3SQLite

# ---------------------------------------------------------------------------
# Test setup
#
# The suite has two halves. The offline half runs anywhere, needs no network
# and no credentials, and is where essentially all logic belongs — it is the
# substrate the design assumes.
#
# The live half runs only against a real S3 bucket, and covers only what no
# fake can answer: that S3 itself behaves as the commit protocol assumes. It
# is skipped — loudly, but without failing — when credentials are absent.
#
# Credentials come from the environment. Locally that is aws-vault, so the
# keys never touch disk:
#
#     aws-vault exec s3sqlite-test -- \
#         julia --project -e 'using Pkg; Pkg.test()'
#
# ADR-0010's signer signs `x-amz-security-token`, so an STS session works and
# issue #6's `--no-session` is retired: SSO and MFA-gated sessions are fine.
#
# A repo-root `env` file, if present, is loaded first and wins — a fresh
# checkout can then run the live tests without fighting unrelated AWS_* vars
# already in the shell. That file is gitignored and local-only; in CI it is
# absent and the injected environment is used instead.
# ---------------------------------------------------------------------------

const ENVFILE = joinpath(@__DIR__, "..", "env")
if isfile(ENVFILE)
    for line in eachline(ENVFILE)
        s = strip(line)
        (isempty(s) || startswith(s, "#")) && continue
        k, v = split(s, "=", limit = 2)
        ENV[strip(k)] = strip(v)
    end
end

# aws-vault injects only AWS_*, so the bucket name is defaulted here and
# overridden from the environment when someone points the suite elsewhere.
const BUCKET = get(
    ENV, "S3SQLITE_TEST_BUCKET",
    "s3sqlite-testbucket-319898207248-eu-north-1-an"
)

# Distinguishes this run's objects from every other run's, so concurrent or
# repeated runs cannot collide and a failed teardown cannot poison the next
# run. The bucket also expires everything after 7 days, so the suite must
# build whatever it reads and never inherit a fixture.
const RID = string(getpid(), "-", time_ns())

"""
    have_credentials()

Whether the environment can reach the test bucket. Returning `false` rather
than throwing is what lets the offline half run on a machine with no AWS
access at all. There is nothing to build a client *from* yet: ADR-0010 makes
the S3 client ours, and it is not written.
"""
function have_credentials()
    haskey(ENV, "AWS_ACCESS_KEY_ID") || return false
    haskey(ENV, "AWS_SECRET_ACCESS_KEY") || return false
    get!(ENV, "AWS_REGION", "eu-north-1")
    return true
end

const LIVE = have_credentials()

# ---------------------------------------------------------------------------

@testset "S3SQLite" begin

    @testset "offline" begin
        @testset "package loads" begin
            @test S3SQLite isa Module
        end

        # Everything the design decides — record encoding, the op set, replay,
        # the state fingerprint, conflict resolution against a fake S3 — lands
        # here. None of it is implemented yet; the design is still deciding it.
        #
        # What is here already pins the dependency's behaviour rather than
        # ours, because the design rests on it (see #21).
        include("sqlite_jl_marshalling.jl")
    end

    if LIVE
        # The live half — a smoke test that credentials, transport and bucket
        # work together, then whatever only S3 can answer about the commit
        # protocol — lands when ADR-0010's object-store port exists. It had
        # been written against LazyFiles, which issue #15 dropped.
        @info "AWS credentials present; live S3 tests land with the object-store port ($BUCKET, run id $RID)"
    else
        @info """
        Skipping live S3 tests: no AWS credentials in the environment.
        Run them with:
            aws-vault exec s3sqlite-test -- \\
                julia --project -e 'using Pkg; Pkg.test()'
        """
    end

end
