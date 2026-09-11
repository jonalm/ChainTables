using Test
import S3SQLite
import LazyFiles

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
#     aws-vault exec s3sqlite-test --no-session -- \
#         julia --project -e 'using Pkg; Pkg.test()'
#
# `--no-session` is required: the S3 backend authenticates with a static
# access key and never reads AWS_SESSION_TOKEN, so aws-vault's default STS
# session, AWS SSO and MFA-gated sessions all fail.
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
    live_config()

The S3 config for the live tests, or `nothing` when the environment cannot
supply one. Returning `nothing` rather than throwing is what lets the offline
half run on a machine with no AWS access at all.
"""
function live_config()
    haskey(ENV, "AWS_ACCESS_KEY_ID") || return nothing
    haskey(ENV, "AWS_SECRET_ACCESS_KEY") || return nothing
    get!(ENV, "AWS_REGION", "eu-north-1")
    return LazyFiles.config_from_env()
end

const CFG = live_config()

"""
    delete_remote(b, cfg)

Remove a remote object. LazyFiles exposes no public delete, so this reaches
through the same private path LazyFiles' own tests use. That gap is part of
the LazyFiles API additions this design needs; when a public delete lands,
this is the single place to change.
"""
function delete_remote(b, cfg)
    return LazyFiles._with_rclone(cfg) do mk
        LazyFiles._run(mk(`deletefile $(LazyFiles.RCLONE_REMOTE):$(b.bucket)/$(b.name)`))
    end
end

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

    if isnothing(CFG)
        @info """
        Skipping live S3 tests: no AWS credentials in the environment.
        Run them with:
            aws-vault exec s3sqlite-test --no-session -- \\
                julia --project -e 'using Pkg; Pkg.test()'
        """
    else
        @testset "live S3" begin
            @info "Live S3 tests against $BUCKET (run id $RID)"

            # Smoke test: prove the credentials, the transport and the bucket
            # work together, so that a later failure in a real test is a
            # failure of our logic rather than of the plumbing.
            @testset "round-trip through the object store" begin
                key = "_selftest/$RID.bin"
                payload = "S3SQLite smoke test $RID\n"
                path, io = mktemp()
                write(io, payload)
                close(io)

                blob = LazyFiles.s3_upload(path, BUCKET, key; config = CFG)
                @test blob.bucket == BUCKET
                @test blob.name == key

                @test read(blob(; config = CFG), String) == payload

                listed = LazyFiles.s3_list(BUCKET; prefix = "_selftest", config = CFG)
                @test key in [b.name for b in listed]

                delete_remote(blob, CFG)
                LazyFiles.clear_from_cache(blob)
            end
        end
    end

end
