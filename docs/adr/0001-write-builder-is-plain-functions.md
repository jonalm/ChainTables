---
status: accepted
---

# The write builder is plain functions, and it guarantees replay determinism only

The write builder is plain Julia functions taking `NamedTuple` rows, with a
do-block for `create_table!` alone (a table is a list of declarations, so a block
reads well there and nowhere else). It is **not** a macro DSL, because the thing a
macro would buy cannot be bought: a builder cannot make a non-deterministic write
unrepresentable, so it does not try. What it guarantees instead is **replay
determinism** — an op carries literal values only, so every client applying the
record obtains the same content. Reproducing the same record by re-running the
author's code is a different property, and S3SQLite does not offer it.

## Considered options

Three front-ends were prototyped over one op model and shown to emit identical op
data, so the choice was purely about how the calling code reads (issue #7, branch
`prototype/write-builder`).

- **Plain functions over `NamedTuple`s** — chosen.
- **Do-blocks throughout** — kept for `create_table!` only. Elsewhere the block
  adds scope without adding clarity, and row sets come from ordinary Julia.
- **A macro DSL** — rejected. It needs sub-macros (`@required`, `@primary_key`)
  that are meaningless outside it; it cannot host ordinary Julia, so the query
  that computes a row set must move outside the block and be spliced back in; and
  its one real advantage does not hold. The macro can scan its own source and
  reject `value = rand()`. It accepts `value = noise()` where `noise() = rand()`,
  which is one function away and is also what every real caller does, since row
  sets come from a query over the local copy.

## Consequences

- The guard the builder *does* enforce is structural, and is where the fail-fast
  behaviour lives: SQLite storage class (no `Bool`, no `DateTime`, no `NaN`, no
  `Inf`, no U+0000 in TEXT), bare-safe identifiers with no quoting anywhere (a
  quoted identifier that fails to resolve becomes a string literal under
  `SQLITE_DQS=3`, issue #18), an explicit `PRIMARY KEY` on every table, uniform
  column order within an op, and literal-only defaults.
- Every record is applied to the local copy before it may be committed. An op
  that matches a number of rows other than the one it names is an error, not a
  no-op: the row set disagrees with local state, so the two clients do not agree
  on what the record means.
- `missing` is accepted as NULL, because it is what SQLite.jl returns for a NULL
  column and refusing it would break the read-change-write round trip. The
  accidental-NULL case it admits is caught by `NOT NULL` in the schema, which
  fails locally before a commit.
