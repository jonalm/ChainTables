---
status: accepted
---

# The state fingerprint is a two-level hash of logical content, recomputed in full

After the ops of a transaction record are applied, a client derives that record's
`state_fingerprint` by encoding its **model** (ADR-0022) and hashing the result:

```
table_hash  = SHA-256("chaintables/v1/fp-table" ‖ cbor([shape, rows]))
state_fingerprint
            = SHA-256("chaintables/v1/fp" ‖ cbor([[name, table_hash], …]))
```

where `cbor` is ADR-0006's frozen §4.2.1 encoder, `shape` is the table's shape
in ADR-0025's wire form, `rows` is every row of the table as ADR-0025's arrays,
and the outer array is sorted by table name. Both domain separators are part of
the format.

**A table file holds exactly the `table_hash` byte stream, separator included**
(ADR-0023), so `table_hash == sha256(file)`: a table's verification is hashing a
file, and the outer hash is over the head file's `tables` list.

**What is inside.** Every table the chain created, and its shape: table name,
column names, value types, nullability, primary-key position — the shape as the
model holds it, in ADR-0025's wire form. **Nothing is outside.** The local copy
holds table files and a head file and nothing else (ADR-0023), a client's own
state lives in the head and not in a table, and every table file is inside the
fingerprint. (This ADR first read the shape from a database catalog and excluded
per-client tables by name; both left with ADR-0022.)

**What is hashed.** Typed values only — `int64`→int, `float64`→preferred float,
`text`→tstr, `bytes`→bstr, null→CBOR null. **A typed value reaches the encoder
untransformed**: never converted, rendered, parsed or arithmetically touched
(ADR-0022, *apply never computes*). This is what makes the check trustworthy
rather than noisy: no rendering or conversion sits between the model and the
hash, so a mismatch can never come from two clients formatting the same value
differently. Every mismatch is a real divergence.

**In what order.** Tables by the UTF-8 bytes of their name; columns in declaration
order; rows in primary-key order. *Amended by ADR-0025*: the order is the typed
key order defined there — numeric for `int64`, IEEE value for `float64` with
`-0.0 < 0.0` and NaN last, bytes for `text` and `bytes`, lexicographic over a
composite key. A key column is single-typed and non-nullable, so no cross-type
case arises.

**Values come from the model and from nowhere else.** The model *is* the content
(ADR-0022): there is no read-back through a driver, no catalog, and no path on
which a stored value could come back as something other than its bytes. The
fingerprint is the frozen encoder applied to what the model holds.

## Cost, and why there is no incremental structure

Measured in the SQLite era (M2 Pro, warm, Julia 1.12.7), a full pass over five
tables of mixed value types read straight from storage ran at **0.48 s per
million rows** (1 M rows, 113 MiB) against 0.34 s for a raw SHA-256 of the same
bytes, linear in row count. At the stated ceiling of 10⁷ rows a full pass is
**~5 s**, against tens of commits a day. A canonical logical re-encode therefore
lands within 1.4× of the cheapest conceivable whole-content pass. Under the
model there is no storage boundary to cross at all — the pass is the encoder
over resident values — so that figure is an upper bound, to be re-measured by
the build. One fact about where the time went survives: 57 % of the pass was
`SHA.jl`, pure Julia at ~360 MB/s where `openssl` on the same bytes runs 5.3×
faster using the CPU's SHA-256 instructions. That is an implementation freedom:
the digest is fixed, so a client may call a hardware-accelerated SHA-256.

## When it is checked

- **Applying one new record onto the current head verifies that record.** This is
  the steady-state case.
- **A batch replay verifies every checkpoint and the head** (amended by
  ADR-0023; this ADR first said *the head only*, a cost decision). 10⁴ records at
  cold start × a full pass each is O(n·R) and the design dies there, but a
  checkpoint computes every table hash to name its files, so its fingerprint is
  free and is compared with that record's. Between checkpoints a wrong
  intermediate fingerprint propagates, so detection is never lost, and
  `verify(chain; full=true)` recovers localization on demand by bisecting to the
  first mismatching slot. A point-in-time rebuild verifies the record it stops at.
- **The committer runs no extra pass.** It needs the post-apply fingerprint anyway
  to build the record, and it has no independent value to check it against — it is
  the author. The touched tables are hashed as their files are written; untouched
  tables keep the head's `table_hash`, which is safe because the head is
  content-addressed (ADR-0023). What it does check first is that its local head
  matches the parent record's fingerprint, which catches "my local copy drifted
  since the last apply" *before* a bad fingerprint becomes permanent.
- **There is no opt-out.** A check that configuration can disable is not a
  guarantee.

## On mismatch

Amended by ADR-0023. A mismatch is found before any head is written, so the
local copy stays at its last checkpoint and the chain is never partially
applied. The error names the chain, the slot, the expected and computed
fingerprints, and the record's `client.lib` and `client.julia` against the local
ones — the forensic job ADR-0006 and ADR-0022 gave those advisory fields.

This ADR first made the mismatch a fork between *damaged copy* and *divergence*,
resolved by a fresh rebuild. **Damage and divergence are now caught in different
places.** A table file is hashed at load and a head is content-addressed, so a
damaged copy is decided without replay and can never reach the model
(ADR-0023). A fingerprint mismatch at apply is therefore **divergence**: this
machine cannot reproduce this chain. It is not self-healable, and the client
must **refuse to commit** onto that chain rather than write a record no one else
can reproduce. `repair!` remains the confirming step — a fresh replay from the
cached records, whose bytes are verified against their `transaction_hash`, that
also mismatches proves it.

## Considered options

- **A flat single-level stream** — one hash over every table in order, no
  `table_hash` layer. Rejected, though it is simpler and identical in cost.
  ADR-0006 makes the fingerprint's definition a chain break to change, and the
  two-level shape costs one domain separator today while permanently preserving
  one optimization: a client caching `table_hash` per table can skip untouched
  tables, which at 10 GB with one small table touched is milliseconds rather than
  seconds. Under ADR-0023 the cached value is the head file's, which is
  content-addressed, so the skip is sanctioned at commit; `verify` always
  recomputes every table from its file.
- **A multiset or Merkle structure** (per-row hashes combined commutatively, or a
  tree over sorted keys) giving O(changed rows) updates. Rejected on the
  measurements: it buys ~5 s → ~50 ms on an operation that runs tens of times a
  day, and charges persisted per-client structure, a second code path, and a
  definition frozen for the life of the format.
- **Hashing the local copy's files as stored, with no logical definition.**
  Rejected while the local copy was a database file: page layout, freelist
  state and per-client indexes are not things clients agree on. Under ADR-0023
  the two coincide by construction — a table file holds exactly the
  fingerprint's byte stream — but the logical definition is what makes that so,
  and it is the definition that is frozen.
- **Computing the fingerprint from the ops** instead of from the content. This
  ADR first rejected it as tautological, because a database engine was the thing
  under test. ADR-0022 inverts that: the model is the content, the fingerprint
  is a hash over the model, and what it tests is that two clients hold the same
  model — an apply bug, an encoder bug, or a Julia difference no one predicted.
- **Verifying every record during a batch replay.** Rejected; see above.
- **A separate algorithm or a `fingerprint_alg` field.** Rejected: SHA-256
  throughout, and ADR-0006 already refused a second negotiation point.

## Consequences

- **The definition is frozen for the life of `format_version` 1.** Changing the
  wire encoding is a version bump; changing this is a chain break (ADR-0006).
- **Issue #13's bucket-cached local copy is verifiable by construction.** The
  fingerprint depends on nothing per-client, so any client can check a cached copy
  against the `state_fingerprint` of the record it claims to represent.
- **A client's own state lives in the head file** (ADR-0023), outside the
  fingerprint by construction: the fingerprint is over the head's `tables` list,
  not over the head.
- **A foreign table cannot exist.** The head names every table file, and a file
  the head does not name is swept.
- Named tests: an empty table contributes its shape and no rows; `-0.0` (already
  required by ADR-0006); a `float64` key holding both `-0.0` and `0.0`, and NaN
  as one key, under ADR-0025's typed key order (this ADR first noted the
  opposite, when SQL equality decided key uniqueness).
