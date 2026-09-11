---
status: accepted
---

# Identifiers are bracketed, never bare and never double-quoted

Every table and column name the builder emits is wrapped in square brackets —
`CREATE TABLE [sample] ([id] INTEGER NOT NULL, PRIMARY KEY ([id]))` — and names
are restricted to `[a-z_][a-z0-9_]*` with the `sqlite_` prefix refused. This
supersedes the "bare-safe identifiers with no quoting anywhere" consequence of
ADR-0001; the rest of that ADR stands.

ADR-0001 banned quoting because issue #18 found `SQLITE_DQS=3` compiled into
`SQLite_jll` and invisible in `PRAGMA compile_options`, so a double-quoted
identifier that fails to resolve silently degrades into a string literal. That is
true, and it is specific to *double* quotes. Square brackets have no such
fallback. Measured on 3.53.2 through SQLite.jl:

- `SELECT "nosuchcol" FROM t` returns the string `'nosuchcol'`, with no error.
- `SELECT [nosuchcol] FROM t` raises `no such column: nosuchcol`.
- `pragma_compile_options` returns no `DQS` row at all, so only the behavioural
  test detects the setting — exactly as #18 warned.

The probes were run through SQLite.jl rather than the `sqlite3` CLI bundled with
the jll, because #18 showed the CLI is a different build that hardcodes `DQS=0`
and would have given a reassuring and wrong answer.

## Considered options

- **Bare identifiers plus a reserved-keyword list**, as the #7 prototype had.
  Rejected: the list is hand-maintained and is itself a cross-version hazard. A
  keyword added in a later SQLite turns a table one client created into a syntax
  error on another, and the failure arrives long after the record is immutable.
  Measured: `CREATE TABLE select (...)` and a bare `index` column are both syntax
  errors today, while `[select]`, `[index]` and `[order]` all work.
- **Backticks.** Behave identically in the probes. Brackets were preferred
  arbitrarily; either would do.

## Consequences

- No keyword list exists, so there is nothing to maintain and nothing to skew.
- A bracketed identifier cannot escape a `]`, so the character restriction is
  load-bearing rather than stylistic.
- Identifiers are lowercase-only. SQLite matches identifiers case-insensitively,
  so `foo` and `FOO` are one column; restricting the charset makes the builder's
  uniqueness check agree with SQLite's instead of accepting a table SQLite will
  reject.
- `sqlite_schema.sql` stores the brackets verbatim, and `ALTER TABLE ADD COLUMN`
  appends verbatim. This is further reason the state fingerprint must never read
  schema text (issue #3, hazard 26).
