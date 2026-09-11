---
status: accepted
---

# The determinism claim names a library, not a platform

S3SQLite claims replay determinism wherever the package installs, on one
condition: the `libsqlite3` that is loaded is `SQLite_jll`'s own artifact. There
is no list of supported platforms. An overridden library warns at `open`, reads
and syncs normally, and raises on commit unless the user sets
`assume_sqlite_is_equivalent = true`.

Issue #19 asked which platforms v1 claims and how the claim is verified. Its
premise inverts. ADR-0017's invariant is architecture-independent: no op
evaluates anything, and the one architecture-dependent code path anyone found —
`SQLITE_AVOID_U64_DIVIDE` on 32-bit ARM and PowerPC — is in the number-to-text
rendering that ADR-0017 excludes. A platform list would therefore promise
something the argument does not depend on, and it would go stale: Julia already
rates ARMv7 Tier 4, "known not to build currently", while `SQLite_jll` still
ships 18 artifacts including two 32-bit ARM ones. The property that is both
load-bearing and checkable at runtime is *which library we loaded*, not *which
machine we are on*.

## Considered options

- **Julia Tier 1 only**, or Tier 1 + Tier 2. Rejected: a narrower claim than the
  argument supports, expressed in a vocabulary that moves independently of us.
  Julia's tiers are about whether Julia builds, which is Julia's problem and is
  settled before our code runs.
- **Every platform `SQLite_jll` ships an artifact for.** Rejected for the same
  reason in a different vocabulary — it is a list we would maintain in order to
  restate a condition the loader already enforces.
- **Ignore an overridden library**, treating `sqlite_version` and
  `build_profile` as the advisory fields ADR-0006 made them. Rejected: those
  fields name a suspect after a fingerprint has already failed, and an
  overridden build is outside issue #18's uniformity result entirely — different
  options, possibly `SQLITE_DQS=0`, possibly a version outside the admitted
  range.

## How an override is detected

- `Preferences.load_preference(SQLite_jll, "libsqlite_path")` — note the product
  is named `libsqlite`, not `libsqlite3`, so the preference key is
  `libsqlite_path`. After `__init__` the module-level path is always populated,
  so it is the *preference* that must be read, not the resolved value.
- `isdir(joinpath(dirname(dirname(pathof(SQLite_jll))), "override"))` — the
  dev'd-jll case, mirroring JLLWrappers' own check.
- `SQLite_jll.artifact_dir` compared against the artifact path computed from the
  jll's own `Artifacts.toml` — the `~/.julia/artifacts/Overrides.toml` case.
- `Libdl.dlpath(SQLite_jll.libsqlite_handle)` as a cross-check on what was
  actually `dlopen`ed.

`LD_PRELOAD` is invisible to all four. Following ADR-0016, the check is
**explicitly not a security control**: it catches accident and configuration,
never an adversary. The gate is deliberately the same shape as ADR-0016's
non-AWS gate — warn at open, refuse at commit, escape under a field named for
the promise the user is making rather than for the rule it lifts — because an
unverified object store and an unverified library are the same kind of thing.

## How the claim is verified

**The argument carries the claim; the test is a regression net.** A matrix of
five runners cannot generalise to eighteen artifacts, and if ADR-0017's
invariant were wrong those five might pass anyway. What the test actually
catches is the day someone adds an op that evaluates something — the change that
would break the claim silently.

The test replays a fixed op sequence and asserts one literal `state_fingerprint`
and one literal `transaction_hash`, identical in every cell. Checking those
values in also discharges the frozen-encoder obligation ADR-0006 and ADR-0007
impose on the fingerprint, which is about time rather than machines: the
fingerprint is the one hash taken over a re-encoding, so an encoder change
silently forks every chain. The vector covers ADR-0006's named `-0.0` case, an
int64 at `2^63-1`, and a non-ASCII TEXT primary key.

Two axes, and **the version axis is the load-bearing one** — it carries the only
measured divergence, while the platform axis carries none:

- **SQLite version**: the *edges* of the admitted compat range, pinned by
  explicit manifests. Today that is 3.51.2 and 3.53.2.
- **Platform**: ubuntu x86-64, ubuntu aarch64, macOS x86-64, macOS aarch64,
  windows x86-64 — the runners that exist. None of them is 32-bit ARM or
  PowerPC, which is the honest reason the platform axis is a net and not
  evidence.

## Consequences

- **Compat is not narrowed.** `SQLite = "1.8.2"` admits `SQLite_jll = "3.51.0 -
  3"`, so a future 3.x is admitted sight-unseen, and ADR-0017's invariant is
  what protects us — it holds for any version that stores and returns a typed
  value. The obligation this creates is on the matrix: it must track the edges of
  the admitted range rather than whichever two versions happen to be installed.
- **The vector is a test fixture, with no public entry point.** A user on a
  platform no runner covers — ppc64le, riscv64, musl, 32-bit ARM — runs
  `Pkg.test("S3SQLite")`. A second, exported copy would have to stay
  byte-identical to the first for no gain.
- **Issue #16 inherits only the open-time warning** from this decision, and
  nothing else.
- Building the CI workflow is implementation. Its shape is decided here; it also
  gives issue #6's deliberately unwired `aws-tests` environment something to feed.
