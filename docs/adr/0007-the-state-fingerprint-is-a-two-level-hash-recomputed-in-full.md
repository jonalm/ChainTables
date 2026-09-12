---
status: accepted
---

# The state fingerprint is a two-level hash of logical content, recomputed in full

After the ops of a transaction record are applied, a client derives that record's
`state_fingerprint` by reading its **local copy** back and hashing what it finds:

```
table_hash  = SHA-256("s3sqlite/v1/fp-table" ‖ cbor([shape, rows]))
state_fingerprint
            = SHA-256("s3sqlite/v1/fp" ‖ cbor([[name, table_hash], …]))
```

where `cbor` is ADR-0006's frozen §4.2.1 encoder, `shape` is the table's shape
in ADR-0025's wire form, `rows` is every row of the table as ADR-0025's arrays,
and the outer array is sorted by table name. Both domain separators are part of
the format.

**A table file holds exactly the `table_hash` byte stream, separator included**
(ADR-0023), so `table_hash == sha256(file)`: a table's verification is hashing a
file, and the outer hash is over the head file's `tables` list.

**What is inside.** Every table the chain created, and its shape: table name,
column names, declared storage class, nullability, primary-key position. Shape is
read from SQLite's own catalog (`PRAGMA table_list` / `table_info`), never from
our replayed schema model and never from `sqlite_schema`'s SQL text, which SQLite
rewrites and which is version-sensitive. **Outside**: reserved tables and local
indexes (ADR-0003), both of which are per-client by definition. Since ADR-0023
there is nothing to exclude: the local copy holds table files and a head file
and nothing else, and every table file is inside the fingerprint.

**What is hashed.** Typed values only — `INTEGER`→int, `REAL`→preferred float,
`TEXT`→tstr, `BLOB`→bstr, NULL→CBOR null. **No number is ever rendered to text.**
This is what makes the check trustworthy rather than noisy: issue #3's
cross-version divergences live in the float→text path (3.53.0 moved from 15 to 17
significant digits), so a fingerprint that never takes that path cannot fire for a
legitimate version difference. Every mismatch is a real divergence.

**In what order.** Tables by the UTF-8 bytes of their name; columns in declaration
order; rows in primary-key order. *Amended by ADR-0025*: the order is the typed
key order defined there — numeric for `int64`, IEEE value for `float64` with
`-0.0 < 0.0` and NaN last, bytes for `text` and `bytes`, lexicographic over a
composite key — which is what `ORDER BY … BINARY` gave in the SQLite era. A key
column is single-typed and non-nullable, so no cross-type case arises.

**Values are read through `sqlite3_step` + `sqlite3_column_*`, not SQLite.jl's row
API.** This is a correctness requirement, not a performance one: `SQLite.jl` runs
every BLOB it returns through `SQLite.sqldeserialize`, i.e. Julia's
`Serialization`, so a BLOB whose bytes happen to be a valid Julia serialization
comes back as a decoded *object*. The fingerprint would hash something the chain
never stored, and two clients holding identical bytes could disagree. The 6.6×
speedup is a side benefit. See the ticket opened from this one for the rest of the
read path.

## Cost, and why there is no incremental structure

Measured on an M2 Pro, warm, Julia 1.12.7 / SQLite 3.53.2, over five `STRICT,
WITHOUT ROWID` tables of mixed storage classes:

| rows | file | full pass, SQLite.jl row API | full pass, C API | SHA-256 of the raw file (floor) |
|---|---|---|---|---|
| 100 k | 11.3 MiB | 0.34 s | 0.048 s | 0.033 s |
| 1 M | 113 MiB | 3.51 s | 0.48 s | 0.34 s |

Linear, and bit-identical digests by both paths. At the stated ceiling of 10⁷ rows
a full pass is **~5 s**, against tens of commits a day. A canonical logical
re-encode therefore lands within 1.4× of the cheapest conceivable whole-database
pass, and buys version-independence that hashing the file cannot.

Two facts about where that time goes. Through `DBInterface.execute` the pass is
**88 % marshalling** — 723 B allocated per row, a fresh `String` per TEXT cell and
a fresh `Vector` per BLOB, to read their bytes back out; the C-API loop allocates
zero. Past that, 57 % of what remains is `SHA.jl`, which is pure Julia at ~360
MB/s where `openssl` on the same bytes runs 5.3× faster using the CPU's SHA-256
instructions. Both are implementation freedoms: the digest is fixed, so a client
may call a hardware-accelerated SHA-256.

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
- **Hashing the `.sqlite` file's bytes.** Rejected. It is only 1.4× cheaper than
  the logical pass, and it hashes page layout, freelist state, vacuum history and
  local indexes — none of which clients agree on, and all of which ADR-0003
  deliberately left per-client. It would also import issue #3's entire
  version-hazard list into the check.
- **Computing the fingerprint from the ops** instead of reading the local copy
  back. Rejected as tautological: it would verify our own arithmetic, while the
  thing actually under test is whether *SQLite* did the same thing on both
  machines. ADR-0005's silent `Int64`→`REAL` truncation is exactly that class of
  bug, and only a read-back sees it.
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
- Named tests: a BLOB whose bytes are a valid Julia serialization fingerprints as
  its raw bytes; an empty table contributes its shape and no rows; `-0.0` (already
  required by ADR-0006). Note also that `0.0` and `-0.0` compare *equal* in SQL, so
  a `REAL` primary key can never hold both — primary-key uniqueness, not the
  fingerprint, but it is the kind of thing that should be a test rather than a
  surprise. *Inverted by ADR-0025*: under the typed key order `-0.0 ≠ 0.0`, so
  a `float64` key may hold both, and NaN is one key; both are named tests there.
