---
status: accepted
---

# Every row carries the slot of the last record that changed it

Every row of every table carries its **row slot**: the slot of the last
transaction record whose ops changed that row's cells. It is content, so it is
stored in the table file and covered by the state fingerprint. Users read it
through an opt-in Tables.jl table, `ChainTables.table_with_slots(v)`, which adds
a `_slot` column. Issue #65; it answers the "which record wrote this row" part of
#36 by storing the attribution rather than by a replay query over the record
cache.

**No backwards compatibility.** No production chain exists anywhere, so
`format_version` 1 is amended in place, as ADR-0022 did. The determinism
vectors' literals moved once under this ADR.

## What is stored

The slot, an `int64`, not the transaction hash. It is unique within a chain,
immutable, ordered and 8 bytes. The hash can be recovered from the slot, and
`as_of` already addresses slots (ADR-0015).

## The stamping rule

Any op that changes a row's cells stamps that row with the record's slot.

- `insert` and `update` stamp the rows they name.
- `add_column` and `drop_column` stamp **every** row of the table.
- `delete` stamps nothing; a deleted row's slot leaves with the row. There are no
  tombstones, and a per-table "last changed" is out of scope.
- All ops in one record stamp the same slot.
- An update that writes the same value still stamps: apply never compares old
  and new values.

The consequence is accepted: a column op overwrites every row's earlier stamp, so
after a schema change the row slot no longer says which record wrote the row's
values. The row slot answers "when did this row's cells last change", not "who
wrote this value". In exchange the invariant holds without exception: **a row
whose cells changed after slot `s` has row slot > `s`**, so "rows changed since
`s`" is always correct. Finding the record that wrote a given value stays a
replay query (#36's remaining part).

## Records and ops are unchanged; apply copies the slot

Apply takes the slot from the record envelope's `slot` field. This copies a
value and computes nothing, so it is consistent with "apply never computes"
(ADR-0022). The slot is a **required argument everywhere**: the model's
primitives (`insert_rows!`, `update_rows!`, `add_column!`, `drop_column!`,
`push_row!`), `Table(shape, rows, slot)` and the op form
`Ops.apply!(content, op, slot)` all take it, with no default, so apply can never
silently stamp the wrong slot. The record form passes `record.slot`; `commit!`
passes its target slot, `head.slot + 1`, which is safe because a lost race never
re-applies (the builder is spent, ADR-0002).

The write builder's scratch tables hold shapes and never rows, so its
`add_column!`/`drop_column!` stamp nothing, whatever slot they get. It passes a
fixed placeholder `0` and fails fast if a scratch table ever holds a row. It does
not use `w.head.slot + 1`: a `WriteBuilder(content)` has no head.

## Genesis carries no ops

Before this ADR a record at slot 0 *could* carry ops; only `create_chain` happened
to write zero. Such a record would stamp slot 0, which a table file refuses, so a
chain that apply accepted would load as a damaged copy, and `repair!` would write
the same bytes back and loop. **The rule is now: slot 0 carries exactly zero ops,
and every later slot carries at least one.** The `Record` constructor holds it,
so the builder and `decode_record` share it, and a decoded violation is a
`MalformedRecordError`. So every row slot is at least 1.

## The table file's row form

Each row is `[cells…, slot]`: the cells in declaration order, then the row slot,
as one CBOR array of `ncols + 1` entries. This keeps `write_table` and
`read_table` single-pass and streaming (ADR-0023's 1 GB ceiling). `read_table`
requires the last entry to be an `int64` of at least 1.

The shape is unchanged: the row slot is not a column of the shape.

## The load check

When a table file is loaded, every row slot must be at most the head's slot;
otherwise it is a damaged copy, and the message names `repair!`. This is a cheap
consistency check, not the main way a damaged copy is caught: table files are
hashed before use (ADR-0023), and the head's fingerprint is checked against its
own tables list at open. Only a fabricated or wrongly written head reaches it.

## Column names may not start with `_`

The column-name rule becomes `[a-z][a-z0-9_]*`. Table names keep
`[a-z_][a-z0-9_]*`. This reverses ADR-0025's "no reserved prefix" for column
names, and it guarantees `_slot` never collides with a column.

## The read surface

- A `TableView`'s `Tables.columns`/`Tables.rows` stay pure content, so a row set
  read from a view still goes straight back into the write builder (ADR-0024).
- `ChainTables.table_with_slots(v)` returns `(; v.columns..., _slot = slots)`, a
  `NamedTuple` of vectors in the view's key order. It reuses the view's own
  vectors without copying, which is safe because they are already the view's own
  (ADR-0024). The column name is fixed as `_slot`; there is no `name` keyword.
- There is no `slot_of(v, key)` and no `row_slots(v)`:
  `table_with_slots(v)._slot` covers both. Nothing is exported (ADR-0019).
- `v.slot` is the head the view was taken at; `_slot` is per row and always at
  most `v.slot`.

## Considered options

- **A local sidecar file outside the fingerprint.** Rejected: unverified across
  clients, which goes against fail-fast.
- **A user-declared column filled by a builder helper.** Rejected: other clients
  can't check it, and an apply-side check would be policy, contrary to ADR-0003.
- **No column at all, only a replay query over the record cache.** Rejected:
  O(records) per query.
- **A reserved `_slot` column inside `Tables.columns(v)`.** Rejected: it breaks
  the round trip into the builder.
- **Slot data kept out of the view entirely.** Rejected: clumsy access, and lost
  in `DataFrame(v)`.
- **The transaction hash instead of the slot.** Rejected: 32 bytes per row
  instead of 8, unordered, and recoverable from the slot.
- **A separate third array, `[shape, rows, slots]`.** Rejected: it needs a second
  pass in key order or a buffer, and keeping rows and slots aligned separately.
- **Accepting row slot ≥ 0 instead of forbidding ops at genesis.** Rejected: it
  keeps a meaningless 0 stamp, and the chain would still accept a genesis that
  `create_chain` never writes.
- **The builder passing `w.head.slot + 1`.** Rejected: it breaks when there is no
  head.
- **An optional slot on the primitives.** Rejected: apply could silently forget
  it.
- **A test helper that infers the slot.** Rejected: it hides exactly what the
  tests are meant to show.
- **Stamping only on `insert`/`update`.** Rejected: it keeps attribution through
  schema changes, but "rows changed since slot `s`" would then silently miss rows
  a column op changed.

## Consequences

- **ADR-0001 amended in place**: the column-name charset.
- **ADR-0006 and ADR-0019 amended in place**: genesis carries no ops, and every
  later record at least one.
- **ADR-0007 amended in place**: the fingerprint's rows include each row's slot.
- **ADR-0022 amended in place**: apply copies the envelope's slot into each row it
  touches.
- **ADR-0023 amended in place**: a table file's rows are `[cells…, slot]`; the
  load check.
- **ADR-0024 amended in place**: `table_with_slots(v)` is part of the read
  surface; the view's `Tables.columns` stays pure content.
- **ADR-0025 amended in place**: the column-name rule and the reversal of "no
  reserved prefix" for column names; the table file row form.
- **The determinism vectors** were regenerated once, both at slot `2^32` so the
  slot cell uses CBOR's widest integer form (an 8-byte argument). The record
  vector moved off slot 0 to slot `2^32` with a `prev_hash`, since genesis
  carries no ops. The `empty` table's hash did not move: it has no rows.
- **Glossary**: *Row slot* joins `CONTEXT.md`; *State fingerprint* names it.
