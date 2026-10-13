---
status: accepted
---

# A table view is read-only, and a native Tables.jl table

ADR-0024 caches one table view per table per head: a second
`table(copy, :t)` before the head moves returns the same object. It also let
a user change a view's columns, on the grounds that the change "damages only
`v`". With the cache, `v` is every caller's view at that head:

```julia
ChainTables.table(copy, :e).columns.x[1] = 99.0
ChainTables.table(copy, :e).columns.x[1] == 99.0   # true
```

The change never reaches the local copy or the chain, so ADR-0024's promise
holds. But a later caller reads cells that no transaction record holds, and
nothing tells them. Issue #72, from the review in #66.

Separately, `Tables` sat in `[deps]` unused. ADR-0024 consumed Tables.jl
through its row-iterator fallback, so `Tables.schema(v)` was `nothing` and
`Tables.columns(v)` rebuilt every column on each call. ADR-0027 reopened
Tables.jl as a merit call.

## Decision

**A view's columns are read-only.** `v.columns`, `Tables.columns(v)` and
`table_with_slots(v)` hand out `ReadOnlyColumn`s: an `AbstractVector` over the
view's own vector whose `setindex!` raises

> a table view's columns are read-only: every table(copy, :t) at one head
> returns the same view (ADR-0043); copy(column) is a vector of your own

A `bytes` cell is itself a mutable `Vector{UInt8}`, so a `ReadOnlyColumn`
copies it on each read. Changing a cell read from a view changes only that
copy.

**A view is a Tables.jl table natively.** `Tables` is a dependency (ADR-0027:
trusted, narrow, and it takes over no decision of this repo). A `TableView`
answers `istable`, `columnaccess` and `rowaccess`; `Tables.columns(v)` is
`v.columns`, with no copy; `Tables.rows(v)` is `v`; `Tables.schema(v)` is the
declared names and types, a nullable column `Union{Missing,T}`.

**Two lookups are added.** `v[a, b]` is `v[(a, b)]`. A `NamedTuple` that names
every key column looks up its own key, so `v[first(v)]` works; it may name
other columns too.

## Considered options

- **Return fresh copies from `.columns` and `table_with_slots`.** Each call
  then costs O(rows), which is the cost the cache exists to pay once. And a
  write to a copy silently does nothing to the view, where the user may have
  meant it to. Rejected for the fail-fast error.
- **No cache: a fresh view per `table()` call.** The same O(rows) per call.
  Rejected.
- **Read-only, without the Tables dependency.** Fixes the bug, but keeps the
  fallback's copy per `Tables.columns(v)` and the missing schema, for a
  dependency lighter than `Dates`. Rejected.
- **`ReadOnlyArrays.jl` for the wrapper.** A package for about ten lines, and
  it would not copy `bytes` cells. Rejected.
- **Share `bytes` cells, and document it.** Leaves one way to change what
  every caller reads. Rejected.

## Consequences

- **ADR-0024 is amended in place**: its table's "user mutates a column of `v`"
  row now raises, and its named test "mutating a view's column leaves
  `head(copy)` … unchanged" becomes "a write to a view raises, and a later
  `table()` call reads the chain's cells".
- **ADR-0027's** reopened Tables.jl question is settled here.
- `Aqua`'s `stale_deps` ignore for `Tables` is removed; `Tables` leaves
  `[extras]` and the test target.
- Code that changed a view's columns in place now raises. `copy(column)`, or
  `DataFrame(v)` (which copies by default), gives a mutable table.
- Reading a `bytes` cell allocates.
- Not covered: concurrent `table()` calls from threads share the
  unsynchronized view cache. Issue #35 owns a local copy's locking.
