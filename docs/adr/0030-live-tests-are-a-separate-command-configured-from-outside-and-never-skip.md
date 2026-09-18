---
status: accepted
---

# Live tests are a separate command, configured from outside the repository, and never skip

The tests only AWS can answer — a plain bucket's conditional put (issue #6) and a
gateway bucket end to end (issue #60) — live in `test/live/` and run through one
entry point, `test/live/run.sh [s3] [gateway]`. `Pkg.test()` is offline: it reads
no live configuration and makes no request beyond loopback, whatever the shell
exports. The live configuration is a git-ignored file, `env/live.env`
(`test/live/live.env.example` lists the variables), and **every variable of a
selected test is required**: nothing is defaulted, nothing is taken from the
ambient environment, and nothing in `test/live/` skips.

This is the test-side counterpart of ADR-0028 and ADR-0029's "the values belong
to the deployment and live outside the repository".

## The problem

Both live tests used to sit at the end of their offline files and switch
themselves on from the environment.

- **Ambient state decided whether `Pkg.test()` wrote to a real bucket.** A live
  run leaves records behind for good — the port has no delete verb — so whether
  it happens must follow from the command that was run, not from what happens to
  be exported.
- **Skips were silent.** A live test that did not run was one `Broken` in a
  summary of two thousand; a mistyped variable gave a green run. That is the
  opposite of failing fast.
- **Two conventions for one job**: different switches, different credential
  paths (exported keys, a profile), run lines in a comment.
- **Deployment values had leaked in** as a default and in comments, and nothing
  stopped it recurring.

## The decision

- **Selection is the command line.** `run.sh gateway` runs the gateway test;
  not naming a test is how it is not run. There is no `@test_skip` in
  `test/live/`, and an unset or empty variable is an error naming the variable
  and the example file — raised for the whole selection before any test starts.
- **One naming scheme**, `CHAINTABLES_LIVE_<TEST>_<NAME>`; region is a variable
  like any other, never inferred from the function URL or from `AWS_REGION`.
  `run.sh` drops ambient `CHAINTABLES_LIVE_*` and AWS credential, profile and
  region variables, and reads the file as data rather than executing it.
- **One credentials path**: each test takes a profile and builds a `Bucket`
  (ADR-0029), so credentials come from `sso_credentials(profile)` — any profile
  the CLI can export credentials for, Identity Center or not. A test never
  calls `sso_login` (ADR-0029); `run.sh` checks each profile's session with
  `aws sts get-caller-identity` up front and fails with the login command
  instead of part-way through a run.
- **What a run writes to is printed first**: bucket, prefix, region, profile.
  Expiring those prefixes is the operator's lifecycle rule.
- **No new dependency and no second environment** (ADR-0027): the live suite
  resolves against the package's own project; `Test` and `Sockets` are standard
  libraries. What the two suites share is `test/fixtures/`.
- **A tripwire in the offline suite** (`test/tracked_values.jl`) scans the
  tracked tree for an account id, a function URL's host id, an Identity Center
  start URL and an e-mail address that are not the documented placeholders. It
  knows a few shapes — a bucket or profile name has none — so it is a tripwire,
  not a proof.

## Consequences

- CI runs `Pkg.test()` only and needs no AWS identity; live verification is a
  deliberate act by someone holding a deployment.
- A live test cannot be half-configured into a pass: it runs fully or the run
  fails before writing.
- The live gateway test is the live coverage of `Bucket` /
  `Chain(bucket, prefix)`, and with it of ADR-0029's post-`200` check on every
  commit.
- Considered and not done: a live `GatewayMismatchError` test. It needs two
  deployments and strands a record in the wrong bucket on every run; the
  loopback test in `test/gateway.jl` covers the path.
