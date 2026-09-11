---
status: accepted
---

# Values cross the SQLite boundary through the C API

Every value S3SQLite reads out of a local copy, and every value it binds into
one, passes through `sqlite3_column_*` and `sqlite3_bind_*` — reached through
`SQLite.C`, the bindings SQLite.jl already ships. SQLite.jl stays the
dependency and keeps the connection, the statement and the SQL; only value
marshalling is ours. The row API (`DBInterface.execute` rows,
`Tables.columntable`) is not used for any value that reaches a transaction
record, the state fingerprint, or a reserved table.

ADR-0007 already mandated the C API for the fingerprint pass, on the ground
that SQLite.jl decodes some BLOBs. Issue #21 measured the rest of the read and
write paths and found the same hazard in four more places, so the rule is
generalised: the boundary, not one pass, is where typed values are made.

Measured on SQLite.jl 1.8.2, SQLite\_jll 3.53.2, Julia 1.12.7 — the versions the
compat range admits. `test/sqlite_jl_marshalling.jl` pins every measurement
below.

## What the row API does to a BLOB

`SQLite.sqldeserialize` compares a BLOB's first 18 bytes against
`sqlserialize(0)[1:18]` and, on a match, returns
`Serialization.deserialize(...)` instead of the bytes. Three outcomes, all
measured:

- `sqlserialize([1,2,3])` stored as bytes comes back as `Vector{Int64}`.
- Those 18 bytes followed by arbitrary data raises `SQLite.SerializeError` —
  a BLOB the chain stored is then unreadable through the row API.
- **`sqlserialize(UInt8[9,9])` comes back as `UInt8[9,9]`**: the right Julia
  type, the wrong bytes, for a column whose declared type is still `BLOB`.

The third case is the one that matters. ADR-0005's schema-aware type check
catches a BLOB that decodes to a `String` or an `Int64`, because the declared
column type convicts it. It cannot catch a BLOB that decodes to a shorter
`Vector{UInt8}` — nothing downstream can. ADR-0001 makes read-then-write the
normal way to compute a row set, so this is a live path from a local copy into
a transaction record.

`strict = true` and `Tables.columntable` both take the same path;
`juliatype` maps a BLOB to `Any`, and every `Any` read is a deserializing read.

The 18-byte marker embeds Julia's `ser_version` (30 here) and version bytes, so
**which** BLOBs are affected depends on the Julia version. That is a divergence
source with no SQLite version in it, which is what makes it unlike every other
hazard the design has met.

An ordinary `Serialization.serialize` payload does **not** match, because the
marker includes SQLite.jl's own wrapper type. The trigger set is narrow: bytes
SQLite.jl itself wrote, and anything crafted. Narrow is not empty, and a
64 MiB record of opaque bytes is exactly where the design invites both.

## What the row API does to a number

SQLite.jl materializes a `String` with `sqlite3_column_text`, which is
`vdbeMemRenderNum` — the path ADR-0017 forbids. It is reached whenever the
requested type is `String` and the stored value is numeric: a `TEXT`-declared
column holding a REAL returns `"0.30000000000000004"` on 3.53.2 and `"0.3"` on
3.51.2 (issue #18). A typed read dispatches on `sqlite3_column_type` and
therefore asks for text only where text is stored, so the render is not merely
avoided — it is unreachable.

## What `bind!` does

`bind!` has methods for `Int32`, `Int64`, `Bool`, `AbstractFloat`,
`AbstractString` and `Vector{UInt8}`. There is no method for `Integer`, and the
fallback is `bind!(stmt, i, sqlserialize(val))`. Measured: `Int16(7)`,
`UInt8(7)`, `Int128(7)` and `:sym` are each stored as a BLOB, silently. A
value that cannot be represented must raise, not be stored as something else,
so the bind side asserts ADR-0019's four types and raises on anything else.

## STRICT does not hold the ADR-0017 boundary

`INSERT INTO s VALUES(?, ?)` binding `0.1 + 0.2` into a `TEXT NOT NULL` column
of a `STRICT, WITHOUT ROWID` table is **accepted**, and stores the text
`0.30000000000000004` — as a bound parameter exactly as it does as a literal. So
`vdbeMemRenderNum` is reachable with no SQL text, no `CAST` and no
type-affinity trick, from a single `sqlite3_bind_double`.

Issue #19 found the mirror of this — `STRICT` admits TEXT into a `REAL` column
through `strtod` — and ADR-0017 recorded it. This is the other direction, and
it is worse, because the rendering happens inside the write that a record
describes.

## Consequences

- **The fingerprint's rule was never about the fingerprint.** ADR-0007's C-API
  requirement generalises to every internal read: reserved tables (ADR-0008),
  the local index registry, `repair!`'s rebuild comparison, and anything a
  later decision adds. One rule, no exceptions, because the exception is
  exactly where it would bite.
- **ADR-0005's type check runs at apply, not only at build.** The builder's
  check is what closes the render door (ADR-0017), and a record that reaches a
  client was built by a different client — possibly a buggy or a future one.
  The applying client re-checks each value's type against the declared column
  type of the replayed schema and raises. It is one comparison per value
  against a schema the client already holds, and without it a malformed record
  is stored as a silently coerced value rather than refused.
- **The user's own reads are not covered, and cannot be.** The read surface is
  a plain `SQLite.DB` (ADR-0019), so a user's `DBInterface.execute` keeps
  SQLite.jl's behaviour and S3SQLite has no way to intervene. Two things
  follow: the hazard is documented where BLOB columns are documented, and
  **S3SQLite ships a byte-faithful reader on its qualified public surface** —
  an addition to ADR-0019's list, not a change to its shape — because
  read-then-write is the sanctioned way to build a row set and the silent case
  has no downstream catcher.
- **It is faster, which is not why it is done.** A four-column pass over
  500,000 rows: 1.19 s and 608 B/row through the row API, 0.116 s and 96 B/row
  through the C API — 10×, corroborating issue #11's 7.3×. The layer is not a
  tax paid for correctness.
- **We take a dependency on SQLite.jl's internals.** `SQLite.C` and
  `SQLite._get_stmt_handle` are not documented public API. They are used from
  one internal module, the compat bound is narrow, and
  `test/sqlite_jl_marshalling.jl` fails loudly if either the internals or the
  marshalling behaviour moves. A break here is a `MethodError` or an
  `UndefVarError`, never a wrong value — which is the trade being made. Going
  around SQLite.jl to `SQLite_jll` directly buys nothing: it is the same
  library, and it adds a direct dependency for bindings we already have.
- **Upstream is worth telling, and is not a plan.** A BLOB written as bytes
  that comes back as an object, or raises, is a reportable bug in SQLite.jl.
  Nothing here waits on it: the same reader is needed for ADR-0017 and for the
  10× regardless of what upstream does.
