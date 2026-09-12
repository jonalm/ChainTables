---
status: accepted
---

# The read surface is a table view, fixed at the head it was taken at

A user reads content through **table views**. `ChainTables.table(copy, :orders)`
returns a `TableView`: a Tables.jl table (columns and rows), a key lookup, and
the `(chain_id, slot, transaction_hash)` it was taken at. Taking a view **copies
the table's rows out of the model** into the view's own column vectors, once per
table per head; a `sync!` or `commit!` that moves the copy leaves every view
already taken exactly as it was. There is no SQL engine on the read surface in
v1. Amends ADR-0019, whose read surface was a `SQLite.DB` under `query_only`,
and fills in the "how a user reads the model" slot ADR-0022 left open. Decided
by issue #27.

## The surface

```julia
v = ChainTables.table(copy, :orders)     # TableView, as of copy's head now
Tables.columns(v); Tables.rows(v)        # NamedTuple of vectors; NamedTuple rows
length(v); keys(v)                       # rows; primary keys
v[7]; v[(7, "eu")]                       # row by primary key → NamedTuple
haskey(v, 7); get(v, 7, nothing)         # Base conventions; v[k] raises KeyError
v.slot; v.transaction_hash               # what head this is

ChainTables.tables(copy)                 # sorted table names
ChainTables.shape(copy, :orders)         # the declaration create_table! built
ChainTables.head(copy)                   # (; slot, transaction_hash, state_fingerprint)
```

- A row is a `NamedTuple` in declaration order. Null is `missing`: a nullable
  column is `Vector{Union{Missing,T}}`, a non-nullable one `Vector{T}`, which is
  what ADR-0001 already accepts on the write side, so a row set read from a view
  goes into the write builder with no conversion.
- A composite key is a tuple in primary-key declaration order; a one-column key
  accepts the bare value. A missing key raises `KeyError`; `get` is the soft
  form. Fail-fast, and no convention of our own.
- `Base.getindex` on the copy is **not** extended: `copy[:orders]` reads as a
  `Dict` and invites `copy[:orders] = …`. Every call is qualified, per ADR-0019.
- Nothing on the read surface performs network I/O or moves the head.

## Why a copy, not the model's own storage

The scenario that decided it. `orders(id, status)` at head 40 holds
`1 open, 2 open, 3 closed`; records 41–55 are in the chain, among them one that
closes `id = 2`.

```julia
v = ChainTables.table(copy, :orders)     # head 40
ChainTables.sync!(copy)                  # head 55
v[2]
```

| option | `v[2]` | a loop over `v` spanning the sync | user mutates a column of `v` |
|---|---|---|---|
| **copy on view** (chosen) | `(id=2, status="open")` | sees head 40 throughout | damages only `v` |
| live over the model | `(id=2, status="closed")` | head-55 rows mixed into a head-40 loop, silently | **corrupts the model**: the next `commit!` fingerprints content the chain never had and the copy refuses to commit as diverged |
| bound, fail-fast | raises naming slots 40 and 55 | raises at the first row after the sync | nothing, if every column is behind a read-only wrapper |

Live loses on both columns: silent mixing and a read path that can corrupt the
thing the fingerprint protects. Bound-and-fail-fast is honest but needs a slot
check on every element access, a read-only wrapper type per column, and forces
issue #28 to store the model as columns plus a key index so that the wrapper
has something to be zero-copy over. Copy-on-view needs none of that: the view
owns its vectors, the model can be whatever apply wants, and a user who mutates
a view has mutated a value that reaches nothing.

The cost is one O(rows) copy per viewed table per head — about the table's own
size in memory again, at most the 1 GB per-table ceiling ADR-0023 fixes, and
nothing during a cold start, when no view is taken. Views are **cached strongly
in the copy**, one per table for the current head, returned unchanged by a
second `table(copy, :orders)`, and dropped when the head moves or the copy is
closed; a user holding one keeps it. A weak cache was considered and rejected
as unpredictable — the head moving is the natural eviction.

## What a view does not promise

A view carries its slot so that staleness is **inspectable**, not prevented. A
row set handed to the write builder is any Tables.jl table, and it stops being
a view the moment the user filters or transforms it, so the builder does **not**
compare a row set's origin to the head: the check would cover only the
unfiltered case and imply a guarantee it cannot keep. ADR-0002's stale-head
check at `commit!` stands as the one gate, and the row set is the user's
responsibility, as ADR-0001 already says.

## The DuckDB extension is out of scope for v1

The pivot planned DuckDB.jl as an optional read engine behind a package
extension — SQL over the model and a `to_parquet` export — and issue #25
measured it fit for that. Issue #27 ruled it out of v1's scope: the read surface
above is complete without it, and an engine, its compat floor (BLOB ↔
`Vector{UInt8}` is fixed only on an unreleased DuckDB.jl), its identifier quoting
and its export format are a second effort. Two facts from #25 are kept as
constraints for that effort, not built here: a read engine folds ASCII case in
identifiers, so issue #28's charset decision should keep names distinct under an
ASCII fold; and `register_table` interpolates its name unescaped, so a chain name
must never reach it. `LocalCopy` no longer forwards `DBInterface`; nothing on the
surface speaks SQL. **No weak dependency is added** — the package's non-stdlib
dependencies stay at none (ADR-0022).

Also settled in passing: invalid UTF-8 can never reach a view, because a
`String` typed value is a CBOR text string and RFC 8949 requires it to be valid
UTF-8 — the builder refuses it. Handed to issue #28 as a reason of its own.

## Considered options

- **Live views over the model's storage.** Rejected above: silent mixing, and a
  read path that can corrupt the model.
- **Zero-copy views bound to a slot, raising when the copy moves.** Rejected
  above: per-access checks, a wrapper per column, and a representation
  constraint on issue #28, to save a copy that costs less than a cold start's
  first record.
- **`copy[:t]` via `getindex`.** Rejected: reads as a mutable `Dict`.
- **A bare `NamedTuple` of vectors, no wrapper.** Rejected: nowhere for the key
  lookup and the slot to live.
- **`nothing` for null.** Rejected: `missing` is Tables.jl's convention and
  ADR-0001's, and the round trip to the builder would otherwise convert.
- **A missing key returns `nothing`.** Rejected: fail-fast, and `get` exists.
- **DuckDB.jl as a weak dependency in v1.** Out of scope, above.
- **Amending ADR-0019 in place with no new ADR.** Rejected: the copy-on-view
  trade-off is one a future reader will question.

## Consequences

- **ADR-0019 is amended in place**: the `DBInterface` forwarding and
  `S3SQLite.sqlite(copy)` paragraph now points here. `TableView` joins `Chain`
  and `LocalCopy` as the third type with behaviour.
- **ADR-0022 is amended in place**: DuckDB.jl leaves the "read engine only"
  option and the dependencies line; non-stdlib dependencies stay at none.
- **Issue #28 inherits** the free hand over the model representation, the
  ASCII-fold reason for the identifier charset, and the UTF-8 note.
- **Memory**: a viewed table is resident twice, model and view, until the head
  moves. Documented beside the 1 GB ceiling.
- **Named tests**: a view taken before `sync!` is unchanged after it; a second
  `table(copy, :t)` before the head moves returns the same object, and a
  different one after; `v[k]` on an absent key raises `KeyError` and `get`
  returns the default; a composite key is looked up as a tuple in declaration
  order; a nullable column reads `missing` and round-trips through
  `update_rows!` unchanged; mutating a view's column leaves `head(copy)` and
  the next `commit!`'s fingerprint unchanged.
- **Glossary**: **Table view** added; **Write builder** loses "reads go straight
  to SQLite".
