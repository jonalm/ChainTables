---
status: accepted
---

# The package is ChainTables, and the hash domain separators carry its name

The package is **ChainTables.jl** (module `ChainTables`, UUID unchanged from
S3SQLite). The name follows the glossary: a *chain* of transaction records
materialises *tables*. It was free in General on 2026-09-12 and clears
AutoMerge's name-distance rules against `Chain`, `ChainRules`, `ChainModels`
and the `*Tables` family; registration itself is not a v1 goal, so General is
re-checked when the repo is renamed.

The three hash domain separators become `chaintables/v1/txn` (ADR-0006),
`chaintables/v1/fp-table` and `chaintables/v1/fp` (ADR-0007), lowercase as
before. They change only because no chain has ever been written, so
`format_version` stays 1. **From the first written chain onward the separators
are format bytes and never follow a package rename**: a rename after v1 ships
keeps `chaintables/v1/…` until a `format_version` bump. That freeze is why this
decision has its own ADR rather than a line in ADR-0022.

Every other identifier that carries the package name follows it mechanically,
with no exceptions — `ChainTables.ChainTablesError`, `CHAINTABLES_CACHE_DIR`,
the `chaintables/` cache directory, test profiles. These are not format bytes
and may be renamed freely; the mechanical pass is issue #31. ADR filenames are
identifiers and are never renamed (ADR-0010 keeps its slug and is retitled in
place), matching ADR-0022's rule that ADR numbers are never reused.
