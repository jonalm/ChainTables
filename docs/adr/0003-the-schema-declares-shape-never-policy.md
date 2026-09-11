---
status: accepted
---

# The schema declares shape, never policy

A table declaration carried in the chain may state only what a row *is* — its
columns, their storage class, their nullability, and its primary key. It may not
state `CHECK`, `COLLATE`, `GENERATED ALWAYS AS`, `UNIQUE` or `FOREIGN KEY`, and
indexes are not chain ops at all. The op set is therefore six ops:
`create_table`, `add_column`, `drop_table`, `insert`, `update`, `delete`. Every
table is `STRICT, WITHOUT ROWID` with an explicit, mandatory, `NOT NULL` primary
key.

The dividing line is what clients must agree on. S3SQLite's guarantee is that
every client obtains the same content; it is not that the content is correct.
Every refused clause is a data-quality feature, and every admitted clause is one
more thing the canonical encoding must carry for the life of the format.

## Considered options

- **`FOREIGN KEY` with actions** (`ON DELETE CASCADE` and friends). Rejected, but
  not for the reason first supposed. Actions *are* replay-deterministic once
  `PRAGMA foreign_keys` is pinned — issue #3's hazard 19 says so, and the pragma
  is pinnable because the library opens the connection. They are rejected because
  the transaction record then stops describing its own effect: the op names one
  row and fifty change. That contradicts the settled premise that an op holds a
  row set rather than a condition, it makes the chain unreadable by a person, and
  it would force any future compactor to carry the table declarations and
  simulate the actions rather than merge ops as a pure function.
- **`FOREIGN KEY` with no action, deferred.** A genuine candidate: it mutates
  nothing and only refuses an op that would orphan a row, which is fail-fast at
  exactly the right moment. Rejected on scope. It changes nothing about whether
  clients agree, and the cheapest thing to add to a locked format later is a
  feature left out of it.
- **`CHECK`.** Rejected outright, and it could not have been admitted safely.
  Issue #18 established that SQLite accepts `CHECK(x < random())` and always
  will — `deterministic.html` §2.1 documents the non-enforcement as deliberate
  policy — so validating a `CHECK` would require S3SQLite to own an expression
  grammar, which is the thing v1 exists to avoid.
- **`COLLATE`.** Rejected. The built-in collations are safe (issue #3, hazard 4),
  but the clause is the door a user-defined collation enters through, and with no
  clause every comparison is `BINARY`, which is `memcmp`.
- **`UNIQUE`, and indexes in the chain.** Both rejected, and the second reverses
  an earlier answer in this ticket. Indexes were first put in the chain partly to
  stop per-client drift and partly because `UNIQUE` is a real constraint that
  cannot be optional. Once `UNIQUE` went, so did half the argument, and what
  remained was that an index is neither shape nor content but performance
  tuning — which a client is entitled to choose for its own read patterns. This
  also keeps the state fingerprint purely about content.

## Consequences

- The primary key is the only constraint in the system. Referential integrity and
  uniqueness beyond the key are the caller's problem, enforced by caller code,
  and orphaned rows can be committed and are then permanent.
- `PRAGMA foreign_keys` needs no pinning, because no declaration can use it.
- A table's shape is changed by `drop_table` + `create_table` + `insert` of the
  whole table inside one transaction record. ADR-0001's record-is-the-atom rule
  makes that safe; issue #9 refused `rename_table`, `rename_column` and
  `drop_column` precisely so that this is the only path.
- A column `DEFAULT` is literal-only and may never be `REAL`. It is exercised only
  by `add_column` backfill, because an `insert` names every column (ADR-0005). A
  `REAL` default is the one place a float would be rendered into schema text, and
  SQLite 3.51 and 3.53 parse the same decimal text to different bits at extreme
  magnitudes — so a `NOT NULL REAL` column cannot be added, and the whole-table
  rewrite above is the way to get one.
