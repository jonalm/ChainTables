---
status: accepted
---

# Ops and rows are typed values ordered by key, and apply re-validates every op

ADR-0003, ADR-0005 and ADR-0007 were argued against SQLite. This ADR keeps what
stood on its own, replaces what was SQLite's, and fixes the wire form of a
shape, a row and an op, which ADR-0006 left as `"ops": [ … ]`. Decided by issue
#28, the last format decision before the handoff.

## Value types

A cell holds one of four **value types** — `int64`, `float64`, `text`, `bytes`
— or null where the shape allows it. Those four strings are the wire spelling;
the chain is a format, not a Julia artefact. On the builder side the *type tag*
is the Julia type that names a value type (`Int64`, `Float64`, `String`,
`Vector{UInt8}`, ADR-0019), and `Int32`/`Float32` widen as issue #9 decided.

**Null is not a value.** It is the absence a nullable column allows, carried as
CBOR null and read as `missing`. NaN is a `float64` value, `typeof(NaN) ==
Float64`, and the two never touch: a non-nullable `float64` column may hold NaN
and may never hold null.

**The `float64` domain is all of IEEE binary64.** ±Inf, `-0.0` and NaN are
admitted. Issue #9 excluded NaN three times over; every reason was SQLite's or
is fixed here. SQLite turning NaN into NULL left with SQLite. The many bit
patterns of NaN, which RFC 8949 §4.2.2 leaves open, are fixed by one profile
rule: **the builder canonicalises every NaN to `f97e00`** — the RFC's own
suggestion — and sign bit and payload are not preserved. Refusing non-canonical
NaNs instead is not an option: `0.0/0.0` sets the sign bit on x86-64 and not on
aarch64, so a refusing builder would be platform-dependent, which is the class of
hazard this design exists to remove. Canonicalisation is a builder-side
conversion like `Float32` widening; apply still never computes, since the decoder
reads `f97e00`, the model holds that value and the fingerprint re-emits it. `NaN
!= NaN` is answered by the comparator below. ±Inf never had a reason of its own
(issue #9: "banned because one rule is cheaper to explain than two").

**The `text` domain is well-formed UTF-8 without U+0000.** Invalid UTF-8 is
excluded by the format — a CBOR text string must be valid UTF-8 and the builder
refuses it. U+0000 is excluded on a reason of our own now that SQLite's is gone:
`comment` already refuses it (ADR-0006), any future read engine takes C strings,
and lifting an exclusion later is free while adding one is a chain break.

## The primary-key order

Rows are ordered by their primary key, in an op and in a table file, and the
order is **typed**, not the bytewise order of the encoded key:

- `int64` numerically;
- `float64` by IEEE value, with `-0.0 < 0.0` and `-0.0 ≠ 0.0`, and NaN equal to
  itself and after everything, `+Inf` included;
- `text` by UTF-8 bytes; `bytes` by bytes;
- a composite key lexicographically, in key declaration order.

This coincides exactly with Julia's `isless` and `isequal` on the key tuple, and
the implementation is expected to be exactly that; the determinism vector
(ADR-0022) pins it. A key column is single-typed and non-nullable (ADR-0003), so
no cross-type case arises. **A `float64` key may hold both `-0.0` and `0.0`**,
which inverts ADR-0007's note that SQL equality forbade it, and `float64` keys
stay permitted: excluding them is policy.

The bytewise alternative — sort by the encoder's output for the key — is total
but nonsensical: negatives land after every positive (a different major type),
and `1.0` as a half-float bears no byte relation to `1.1` as a double. Typed
order is what `ORDER BY … BINARY` gave, and what a reader of a table file
expects.

## Wire forms

All through ADR-0006's frozen encoder, text-key maps in the envelope's house
style. Sorted keys mean the order shown is expository.

**Shape.** One encoding for both of its uses: the shape in a table file is
byte-identical to what `create_table` would carry for that table after its
`add_column` and `drop_column` ops.

```
{"columns": [[name, type, nullable], …],   ; declaration order; type ∈ {"int64","float64","text","bytes"}; nullable is a CBOR bool
 "key":     [name, …]}                      ; key declaration order; every key column non-nullable
```

**Row.** A CBOR array of typed values in declaration order, key columns
included; column names are stated once, in the shape. The table file is
`cbor([shape, rows])` with rows in key order (ADR-0007).

**Ops.** Seven, each a map with an `"op"` discriminator and a `"table"`:

```
create_table  {"op", "table", "shape"}
add_column    {"op", "table", "column": [name, type, nullable], "fill": value}
drop_column   {"op", "table", "column": name}
drop_table    {"op", "table"}
insert        {"op", "table", "rows": [[every column, declaration order], …]}
update        {"op", "table", "columns": [non-key names, declaration order], "rows": [[key…, values…], …]}
delete        {"op", "table", "keys": [[key…], …]}
```

`rows` and `keys` are sorted by the primary-key order above. `fill` is always
present on `add_column`, so absence has one spelling: null, which is legal only
when the column is nullable. A non-nullable column requires a non-null fill.

## No DEFAULT in the shape, and a fill value in the op

`insert` names every column (ADR-0005), so a shape-level DEFAULT is never read
after backfill: it would be hashed dead weight. ADR-0003's "a DEFAULT may never
be `REAL`" was the float→text path, which is gone. So the shape declares no
default, `create_table` carries none, and `add_column` carries a **fill value**
— the typed value every existing row receives, encoded like any cell. A
non-nullable `float64` column is now addable.

## `drop_column` is the seventh op

Issue #9 refused `drop_column`, `rename_table` and `rename_column` because each
was a documented SQLite schema-text rewrite, leaving `drop_table` +
`create_table` + `insert` inside one record as the only path. In the model
`drop_column` is structural — remove the column from the shape and from every
row, and apply never computes — and the rewrite path has a real hole: ADR-0006's
64 MiB record cap means a table past that size could never drop a column. So
`drop_column` is admitted, refusing a key column and nothing else: dropping the
last non-key column leaves a key-only table (a set, which hashes fine), and
adding then dropping one column inside a record is two ops applied in sequence.
Renames stay out: an op addresses by name, and a rename is the one change that
makes an older record's meaning depend on a later one.

## Apply re-validates every op

Under SQLite, `STRICT` and `NOT NULL` re-checked type and nullability at apply
on every client, whatever the committer had done. The model has no such floor,
so **apply re-runs every structural check the write builder runs**: value type
and nullability against the shape, every column named by an insert, known table
and column, a non-key column for `drop_column`, no duplicate key inside an op,
rows in key order, and the state gate of ADR-0001 — insert on a present key,
update or delete on an absent key. A record that fails any of them is a
**malformed record**, and apply raises `MalformedRecordError` naming the slot,
the op index and the rule broken.

A malformed record is neither damage (its `transaction_hash` is fine) nor
divergence (no client can apply it). It is a bug in the committer, and no client
can advance past that slot under this format version; the chain is dead beyond
it and a new chain is the recovery. That is why every record is applied locally
before it may be committed (ADR-0001), and why the builder's checks and apply's
are one code path, not two.

## Reserved names and identifiers

**There is no reserved table-name prefix.** `s3sqlite_` was folded at build and
replay because client state lived as tables in the same file (ADR-0008,
deleted). Per-client state has the head file (ADR-0023), and any future
library-owned content in the chain is a new op or field, which is a
`format_version` bump regardless.

**The identifier charset stays `[a-z_][a-z0-9_]*`**, lowercase ASCII, no length
cap, for tables and columns. SQLite's case folding was the original reason; three
live ones replace it: a future read engine folds ASCII case in identifiers
(issue #25), names become `Symbol`s and NamedTuple fields on the read surface
(ADR-0024), and a Unicode name would import the normalisation question the
encoder deliberately refuses (ADR-0006).

## The resident representation is the build's

The wire forms above are format. How a loaded table sits in memory is not, and
ADR-0024's copy-on-view freed it from any zero-copy constraint. One
recommendation is recorded, not mandated: columnar vectors in declaration order
plus a `Dict` from key tuple to row index. Row-of-`NamedTuple` is the 3–5×
expansion ADR-0023's 1 GB ceiling feared, and columnar makes a `TableView` a
plain vector copy.

## Considered options

- **Bytewise key order.** Rejected above.
- **Refuse non-canonical NaNs**, or keep NaN excluded. Rejected above; the
  first is platform-dependent, the second is policy.
- **Trust the record at apply.** Rejected: a buggy committer would corrupt every
  replayer silently, and the checks already exist in the builder.
- **Two error types** for structural violations and state contradictions.
  Rejected: the caller's next move is the same, and ADR-0020's rule is that a
  type exists where the branch differs.
- **Julia type names on the wire.** Rejected: `Vector{UInt8}` in a hashed byte
  stream ties the format to one language.
- **A reserved prefix kept for the future.** Rejected: nothing would use it
  without a format bump anyway.
- **Renames alongside `drop_column`.** Rejected above.
- **Mandating the in-memory representation.** Rejected: nothing on the format
  depends on it.

## Consequences

- **ADR-0001 amended in place**: `NaN` and `Inf` leave the refused list; the
  identifier charset stands on the three reasons above.
- **ADR-0003 amended in place**: storage class → value type; `STRICT` and
  `WITHOUT ROWID` gone (the builder's type check and the key-keyed map were
  already doing their jobs); no DEFAULT; seven ops; no reserved prefix.
- **ADR-0005 amended in place**: rows sort by the typed key order.
- **ADR-0006 amended in place**: NaN encoded as `f97e00`, not refused; the op
  array is defined here.
- **ADR-0007 amended in place**: the order rule and the shape encoding are this
  ADR's; nothing is read from a catalog.
- **ADR-0020 amended in place**: `MalformedRecordError` joins the table.
- **Determinism vector** gains a NaN cell fed a sign-bit-set NaN, so the
  canonicalisation itself is under test, plus `±Inf`.
- **Named tests**: NaN as a key matches itself and sorts after `+Inf`; a
  `float64` key holding both `-0.0` and `0.0`; a shape read from a table file
  equals the shape `create_table` plus its column ops would carry; `add_column`
  with a null fill on a non-nullable column refused; `drop_column` on a key
  column refused; a record with a `float64` in an `int64` column raises
  `MalformedRecordError` at apply on a second client; a key-only table's file.
- **For a future read engine**, a constraint, not a rule here: DuckDB treats
  `-0.0 == 0.0` and NaN as equal to NaN, so a `float64` key holding both zeros
  needs handling there.
- **Glossary**: **Value type** and **Malformed record** added; **Typed value**
  and **Shape** rewritten.
