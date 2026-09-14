---
status: accepted
---

# Dependencies are chosen on merit, and nothing forbids them

ChainTables may depend on a package outside the standard library when that
package is **trustworthy, well maintained, and does one job the package needs**.
The goal is a lean package, not a dependency-free one. Leanness is judged by
what a dependency drags in and what it takes over, not by whether it is in the
sysimage.

This ADR exists because three earlier ADRs stated the opposite as a consequence
without ever arguing it. ADR-0022 retired SQLite.jl and recorded that the
non-stdlib dependency count had *reduced to none*; ADR-0010 and ADR-0024
restated that count as a rule. It was a description of the state after the
pivot, and it hardened into a constraint nobody chose. The first cost was
issue #61: the S3 client and the test store reimplement calendar arithmetic
and a PRNG to avoid `Dates` and `Random`, which are stdlib and were never
covered by the rule even as written.

## The criterion

A dependency is added when all of these hold:

- **It is trusted.** Maintained by people the ecosystem relies on, with a
  release history and a compat story; no single-commit packages.
- **It is narrow.** It does the job needed and does not bring a transitive
  tree, a runtime, or a binary the package would otherwise not have. The size
  of what `] add` pulls in is the leanness test.
- **It does not take over a decision this repo has made.** A dependency that
  owns retries (ADR-0002), bytes on the wire (ADR-0006), or an encoding the
  fingerprint hashes (ADR-0007) is refused on those grounds, not on principle.
- **Vendoring would be worse.** Rewriting it here costs more lines, more bugs,
  or more maintenance than pinning it.

Stdlib packages (`Dates`, `Random`, `Base64`, …) meet the criterion trivially.
They are listed in `Project.toml` like any other dependency and used freely.

## What stays vendored, and why

- **The CBOR encoder** (ADR-0006, ADR-0022). Determinism rests on the encoder's
  bytes being frozen for the life of the format. A third-party codec is free to
  change its output between releases; that would be a chain break. This is the
  third bullet above, not a dependency-count argument, and it holds under this
  ADR.
- **The SigV4 signer** (ADR-0010). The available alternative, AWS.jl, has an
  inner retry layer that cannot be switched off. ADR-0010 requires the transport
  to make one request per port call so that the commit layer owns the whole
  retry budget and transient failures stay visible. That fails the third bullet.
  Its dependency weight would not by itself rule it out. An S3 client whose
  retries switch off entirely (boto3 is one, in Python) would pass; no Julia
  client does today, and no narrow signer package exists.

Neither of these is an exception to the rule. They are the rule applied.

## Considered options

- **Keep "no non-stdlib dependency" and treat it as intended.** Rejected: it was
  never decided, and it produced issue #61.
- **Allow stdlib only.** Rejected: the sysimage boundary is an implementation
  detail of Julia, not a measure of trust or weight. `Tables.jl` is lighter
  than `Dates`.
- **Amend ADR-0010, ADR-0022 and ADR-0024 in place with no new ADR.** Rejected:
  the rule was stated in three places, and a reader who finds one needs a
  single ADR that owns the criterion.

## Consequences

- **ADR-0010, ADR-0022 and ADR-0024 are amended in place**: each "no
  non-stdlib dependency" line now points here.
- **Issue #61** replaces the hand-rolled calendar math and PRNG with `Dates` and
  `Random` under this ADR.
- **Reopened as a merit call, not decided here**: `Tables.jl` as a hard
  dependency so `TableView` is a Tables.jl source (ADR-0024 currently keeps it a
  test extra). A new issue if wanted.
- **Not reopened**: a DuckDB.jl read extension, weak or hard. ADR-0024 rules it
  out as outside the package's scope, and that reason does not depend on this
  ADR. A read engine is a different package's job.
