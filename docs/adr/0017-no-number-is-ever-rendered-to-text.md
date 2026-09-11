---
status: accepted
---

# No number is ever rendered to text

Inside the replay path and the state fingerprint pass, no number is ever
rendered to text and no text is ever parsed into a number. This is the
invariant replay determinism rests on, and it is the reason S3SQLite can claim
determinism without naming a platform.

Two hazards were found, and they turned out to be one. Issue #18 measured a
cross-*version* divergence: SQLite 3.51.2 and 3.53.2 render `cast(0.1+0.2 AS
TEXT)` as `0.3` and `0.30000000000000004` respectively. Issue #19 found a
cross-*architecture* one: `SQLITE_AVOID_U64_DIVIDE` is self-defined on 32-bit
ARM and 32-bit PowerPC, never appears in `PRAGMA compile_options`, and does not
exist in 3.51.2 at all — so two admitted versions differ in compiled code and
not merely in options. Every use site of that macro is `sqlite3Int64ToText`,
`sqlite3UInt64ToText` or `sqlite3FpDecode`, all reached through
`vdbeMemRenderNum` — which is also where #18's divergence lives. Both hazards
are the same hazard, and excluding the path excludes both at once.

`vdbeMemRenderNum` needs no SQL function to be reached. It fires whenever a
number must acquire a text representation: `sqlite3_column_text()` on a numeric
column, or a value taking TEXT affinity. So the exclusion has to be a rule, not
an observation.

## Where the invariant is already enforced

Nothing new is built here. The rule names something four earlier decisions
between them already achieve, so that a fifth cannot quietly undo it.

- **ADR-0003**: a column `DEFAULT` is literal-only and may never be `REAL`.
- **ADR-0005**: the builder is schema-aware and type-checks each value against
  the declared column type.
- **ADR-0006**: the wire encoding carries int64 and float64 as distinct CBOR
  major types, which is why JSON was structurally disqualified in issue #4.
- **ADR-0007**: the fingerprint reads typed values through `sqlite3_column_*`
  and hashes them as typed values, never as text.

## Consequences

- **ADR-0005's type check is reclassified.** It reads as a data-quality rule and
  it is not: `STRICT` *admits* a TEXT value into a `REAL` column when the
  conversion is lossless, which is a `strtod` path and therefore exactly the
  cross-version hazard. `STRICT` does not close that door; the builder's check
  does. It is load-bearing for determinism.
- **A new op must be checked against this invariant.** An op that rendered or
  parsed a number would break the cross-version claim and the cross-platform
  claim simultaneously, and would do so silently — no fingerprint would differ
  until two clients on different builds met.
- **libm is unreachable from the chain.** `SQLITE_ENABLE_MATH_FUNCTIONS` adds 30
  scalar functions, each a direct libm call, and every one is invoked only by SQL
  text naming it. No op can emit such text. The one ungated libm call —
  `fabs()` inside `kahanBabuskaNeumaierStep`, backing `SUM`/`AVG`/`TOTAL` — is
  reachable only from a user's own query against the local copy, which enters
  neither a transaction record nor the fingerprint.
- **Float↔text conversion is not the exposure it looks like.** Issue #18's claim
  was re-verified against 3.53.2: `sqlite3Fp2Convert10` and `sqlite3Fp10Convert2`
  use fixed-point integer arithmetic and 128-bit multiplication, not libm. The
  hazard in that path is the algorithm changing between versions, which it did,
  not the platform's C library.
- **Numbers do reach text outside this boundary, and that is fine.** S3SQLite
  renders an integer `DEFAULT` and a slot number into text itself, in Julia, and
  a user may render anything they like from their own local copy. The invariant
  binds the replay path and the fingerprint pass, not the package.
