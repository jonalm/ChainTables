---
status: accepted
---

# Content lives in a Julia model, and replay determinism rests on the encoder alone

The content of a local copy is a Julia model: per table, a shape plus a map
from primary key to a row of typed values, null where the shape allows it.
Replay, apply and the state fingerprint pass run on that model. No database
engine sits on the replay path. Replay determinism is therefore a property of
the format — the record bytes, ADR-0006's frozen encoder and the apply rules —
and of nothing on the machine. It is claimed unconditionally wherever the
package runs.

Decided at the pivot of 2026-09-12 and written down by issue #24. This ADR
records the decision and draws its boundary; the tickets it unblocks fill in
the representation.

## Why SQLite was a hazard

The ops were already literal rows keyed by the full primary key under a
shape-only schema (ADR-0003, ADR-0005). SQLite computed nothing during replay.
Yet it was the authority for content and for the state fingerprint, so every
behaviour of it became a determinism hazard: float→text rendering that differs
between patch releases the compat range admits (`cast(0.1+0.2 AS TEXT)` is
`0.3` on 3.51.2 and `0.30000000000000004` on 3.53.2), `SQLITE_AVOID_U64_DIVIDE`
self-defined on 32-bit ARM and PowerPC, `SQLITE_DQS=3` compiled in and
invisible in `PRAGMA compile_options`, `STRICT` admitting text into a `REAL`
column through `strtod` and a bound double into a `TEXT` column through
`vdbeMemRenderNum`, and SQLite.jl deserialising a BLOB into a Julia object when
its first 18 bytes happen to match.

Four ADRs (0004, 0017, 0018, 0021), four research issues (#3, #18, #19, #21), a
C-API marshalling layer, a curated compile-options profile, a library-override
check and a two-axis version matrix existed to fence a component that did no
work. Removing the component removes the fence. The measurements survive in
`docs/research/sqlite-determinism.md`,
`docs/upstream/sqlite-jl-blob-marshalling.md`, the closed issues and git
history.

## The model

Stated abstractly, on purpose. A table is a shape (ADR-0003, as amended by
issue #28) plus a map from primary key to row. A typed value is one of
ADR-0019's four tags — `Int64`, `Float64`, `String`, bytes — or null where the
shape allows it. Nothing here names a Julia type, an ordering, or a file:

- the primary-key comparator, what a row is, and which of ADR-0003's and
  ADR-0005's rules were SQLite's — issue #28;
- the table files, the head file, verification at open and the crash windows —
  issue #26;
- how a user reads the model — issue #27.

## What the claim rests on

- The stored bytes of a transaction record and a rejecting decoder (ADR-0006).
- The apply rules: `insert`, `update` and `delete` act on the map by primary
  key; `create_table`, `add_column` and `drop_table` act on the shape.
  Structural, never evaluative.
- The frozen RFC 8949 §4.2.1 encoder and SHA-256 for the fingerprint
  (ADR-0006, ADR-0007).
- Julia's `Int64`, `Float64` and `String` as carriers of bits. No arithmetic,
  no conversion; `-0.0` is preserved by the encoder's sign check.

Not on: a database engine, its version, its build, a platform, or a shared
library. The package version is not a condition either — a buggy version is
what the fingerprint catches.

## What the fingerprint now tests

ADR-0007 rejected computing the fingerprint from the ops as tautological,
because SQLite was the thing under test. That inverts. The model *is* the
content, so the fingerprint is a hash over the model, and what it tests is that
two clients hold the same model: an apply bug, an encoder bug, or a Julia
difference no one predicted. It also becomes the local copy's own integrity
check — `table_hash` is defined over exactly the byte stream a table file holds
(issue #26), so `table_hash == sha256(file)`. Divergence keeps its meaning: a
mismatch that survives a fresh replay is two clients disagreeing about content.

## Apply never computes

Successor to ADR-0017's rule, which had no target left. A typed value passes
from record to model to encoder untransformed: never converted, rendered,
parsed, or arithmetically touched. A new op is checked against this. An op that
evaluated anything would reintroduce, in Julia, the class of hazard SQLite was
removed for.

## The determinism vector

Successor to ADR-0018's regression net; the argument carries the claim and CI
catches the day someone breaks it. One fixed op sequence, with one literal
`state_fingerprint` and one literal `transaction_hash` asserted identical in
every cell. Two axes: Julia version (the compat floor and the latest release)
and the runners that exist (ubuntu x86-64 and aarch64, macOS x86-64 and
aarch64, windows x86-64). The vector covers `-0.0`, an int64 at `2^63-1` and a
non-ASCII TEXT primary key. Checking the literals in also discharges the
frozen-encoder obligation ADR-0006 and ADR-0007 impose. It is a test fixture
with no public entry point.

## The envelope

Amends ADR-0006 in place. `sqlite_version` and `build_profile` leave the
record. `client` gains `julia` (tstr, `string(VERSION)`), advisory like
`client.lib`. When a fingerprint mismatch fires, the suspects the record names
are `client.lib` — package name and version — and `client.julia`.
`format_version` stays 1: no chain has ever been written, so no bytes are owed
compatibility. The three domain separators carry the old package name and are
renamed by issue #29 with the package.

## Considered options

- **Keep SQLite as a read engine only**, content in the model. Rejected: a hard
  dependency on a database for a job an optional engine does. DuckDB.jl was to
  take that job as a weak dependency; issue #27 ruled any read engine out of
  v1's scope (ADR-0024).
- **Mark the four ADRs superseded and keep them.** Rejected, and the rule is
  set here: a superseded ADR is deleted, an amended one is edited in place,
  numbers are never reused, and git history is the archive. Four dead files in
  the listing invite a reader to treat them as live constraints.
- **An encoder version field** in the envelope. Rejected: `format_version`
  already freezes the encoder, and ADR-0006 refused a second negotiation point.
- **An assumed guarantee for the Julia version**, replacing
  `assume_sqlite_is_equivalent`. Rejected: there is no library to check and no
  claim conditional on Julia; the fingerprint is the check.
- **Delta Lake / Iceberg, Dolt, Litestream, a `.duckdb` file, Parquet per
  table.** Ruled out at the pivot: no Julia writer or no hash chain, a server
  and DynamoDB, single writer, a hard dependency with no canonical bytes, and
  bytes that are not canonical respectively. Parquet is kept as an export only.

## Consequences

- **Deleted**: ADR-0004, ADR-0017, ADR-0018, ADR-0021.
- **Amended in place here**: ADR-0006's envelope.
- **Amended by this ADR, body edits owed by issue #32**: ADR-0007 (the model
  replaces the read-back, the catalog and the C API; the primary-key order
  comes from issue #28's comparator; there is nothing to exclude by name),
  ADR-0010 (non-stdlib dependencies reduce to none — stdlib plus the vendored
  encoder and the vendored signer), ADR-0019 (only the AWS open-time warning
  remains; `assume_sqlite_is_equivalent` and `PRAGMA query_only` are gone),
  ADR-0001 (its note on the deleted ADR-0004; the identifier charset is issue
  #28's to re-decide).
- **Owed to later pivot tickets**: ADR-0008 is superseded by issue #26; ADR-0009
  and ADR-0013 are amended by issue #26; ADR-0003, ADR-0005 and ADR-0007's
  ordering rule are amended by issue #28; ADR-0019's read surface by issue #27.
- **Leaves with no successor**: the C-API marshalling layer, the compile-options
  profile, the library-override check, the SQLite version axis of the matrix,
  the byte-faithful reader, `PRAGMA query_only`, **local index**, the SQLite
  half of the test substrate, and `test/sqlite_jl_marshalling.jl` (deleted by
  issue #31, with the dependency). **Reserved table**'s successor is the head file (issue #26).
- **Assumed guarantee** keeps only its AWS instance (ADR-0016).
- **Dependencies**: no non-stdlib dependency, hard or weak — issue #27 put the
  DuckDB.jl extension out of scope (ADR-0024). The `Project.toml` edit is issue
  #32's.
- **Glossary**: **Typed value** and **Replay determinism** are redefined here;
  the full pass is issue #30's.
- Issues #20 and #23 are closed as invalidated.
