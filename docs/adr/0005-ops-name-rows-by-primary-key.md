---
status: accepted
---

# Ops name rows by primary key, and an insert names every column

An `update` or `delete` identifies its rows by the table's full primary key and
by nothing else. An `insert` names every column of the table. An `update` names
the primary key plus any non-empty subset of the remaining columns, and may not
change a primary key column — that is a different row, and `delete` + `insert`
says so.

Naming rows by the full key makes "this op matches exactly one row" structural
rather than a runtime hope, and it makes a transaction record readable without
resolving the schema as it stood at that slot. Requiring an insert to name every
column makes the record say what the row *is*, instead of what the schema of that
moment would have filled in.

## Considered options

- **Arbitrary key columns**, as the #7 prototype allowed (`by = :id`, or any
  column set). Rejected: a non-key column set can match any number of rows, which
  leaves ADR-0001's exactly-one-row gate as the only thing between the caller and
  a record whose meaning depends on data.
- **A pre-image** — recording the old values alongside the new, making every
  record independently checkable against local state and trivially diffable.
  Rejected for v1 on size: the state fingerprint already catches divergence one
  record later. This is the decision held most loosely, and it is the expensive
  kind to revisit, because adding it changes the record format.

## Consequences

- The builder is **schema-aware**: it resolves each op's table against the schema
  as of the current head before applying. "Every column" cannot be checked without
  knowing the columns, and the value guard needs the declared column type — issue
  #9 measured that `STRICT` does *not* reject an `Int64` too large for a `REAL`
  column. `9007199254740993` into a `REAL` column stores `9.007199254740992e15`
  silently, both as a SQL literal and as a bound parameter, contradicting
  `stricttables.html`. Only a schema-aware builder can fail fast on that.
  The price is that an op can no longer be validated in isolation from the chain
  state it applies to.
- A record is canonical in three ways that were previously the caller's: column
  order is the table's declaration order, key-column order is the primary key's
  declaration order, and rows are sorted by primary key within an op. A duplicate
  primary key inside one op is rejected by the builder rather than by SQLite at
  apply time. The caller's own row ordering is discarded; in exchange the bytes of
  a record depend only on the logical change, which the idempotent-commit check of
  ADR-0002 and any future diff both want.
- The asymmetry between `insert` and `update` is deliberate: an insert declares
  what a row is, an update declares what changed. An update that named every
  column would not be an update.
