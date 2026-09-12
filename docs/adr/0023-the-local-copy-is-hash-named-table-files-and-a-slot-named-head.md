---
status: accepted
---

# The local copy is hash-named table files and a slot-named head file, written last

A local copy is a directory. It holds one **table file** per table and one
**head file**, and nothing a client keeps for itself lives anywhere else.
Supersedes ADR-0008, whose reserved tables have no SQLite file to live in.

```
mycopy/
├── heads/
│   └── 000000000042            head file, named by slot
├── tables/
│   ├── 3f9a…c21e               table file, named by its own SHA-256
│   ├── 7b02…e8d4
│   └── a5c7…10f9
└── pin                          present iff the copy is pinned
```

Decided by issue #26 after ADR-0022 moved the content into a Julia model.

## The table file is the fingerprint's byte stream

ADR-0007 defines `table_hash = SHA-256("…/fp-table" ‖ cbor([shape, rows]))`. A
table file holds **exactly that stream, domain separator included**, so

```
sha256sum tables/3f9a…c21e  →  3f9a…c21e
```

The name is the proof of the content, the ASCII separator doubles as the file
magic, and a CBOR tool that wants the item skips the prefix. Lowercase hex, not
base32: a hash is compared against `sha256sum`, never spoken; a chain id is
base32 because humans read it in messages. A table file has no name inside it.
Two tables with identical shape and rows share one file. A table with zero rows
still has a file, since its shape is hashed.

Consequences the fingerprint buys for free: verification of a table is hashing a
file, an untouched table's file is shared across slots, and a future
bucket-cached snapshot is these files copied up under a reserved name, verifiable
by any client against the record's `state_fingerprint`.

## The head file

One CBOR map through the same frozen encoder, behind its own ASCII magic that
identifies the layout before decoding:

```
"…/head" ‖ {
  "layout_version":    1,
  "chain_id":          "K7QX3M…",
  "format_version":    1,
  "slot":              42,
  "transaction_hash":  h'91af…',       hash of record 42's stored bytes
  "state_fingerprint": h'4e0c…',       equals record 42's field
  "tables":            [["bar", h'7b02…'], ["baz", h'a5c7…'], ["foo", h'd80e…']],
  "written_at_ms":     1757660000000,  advisory
  "written_by":        {"lib": …, "julia": …}                      advisory
}
```

`tables` is sorted by name and is the only place that says which file is `foo`.
`state_fingerprint` is redundant with it — it *is* ADR-0007's outer hash over
that list — and is stored so that `open` can check the head against itself and
`commit!` can compare the local head with the parent record without hashing a
table. `chain_id` binds the copy to its chain, collapsing ADR-0008's separate
write-once row: every head is write-once, so the lifetimes no longer differ.
`written_by` carries the two suspects ADR-0022 names for a fingerprint mismatch,
never checked. **Not in the head**: the pin, because a pin toggles and the head
never changes; bucket and prefix, because they are location and a chain may be
copied.

The pin is an empty file `pin`. `as_of` creates it, `unpin!` deletes it, and
`sync!` and `commit!` refuse while it exists.

## Write once, write the head last

Every file is written to `<name>.tmp` in its directory and renamed into place.
No file is ever overwritten. The head is written after every table file it
names, so a head file, when it exists, names files that exist and are complete.
That is the whole crash-safety argument; there is no journal and no transaction.

**Commit** (amends ADR-0009): apply to the model → write the touched tables'
files (a name that already exists is skipped) → fingerprint over the new
`[name, hash]` list, free → build the record → conditional PUT → write the head
→ sweep. A crash or a `412` before the head leaves the old head and its files
intact and some orphan table files, which the next open sweeps; the model
reloads the touched tables from the head's files. A crash after the PUT and
before the head is ADR-0014's orphan: the next `sync!` fetches our own record
and applies it, finding its table files already present. The head rename is the
local commit point.

**Sweep**, at open after the head is chosen and after every head write: delete
every head but the chosen one, every table file the chosen head does not name,
and every `.tmp`. Silent — everything deleted is derived. Deleting *local* files
is fine; ADR-0012 forbids deletion of bucket objects only, and the object-store
port still has no delete verb.

**Choosing the head at open**: the highest head that is self-consistent and
whose named files all exist; failing that, the next lower one if present (the
crash window leaves at most two); failing that, a hard error.

## What `open` verifies, and the memory model

`open` reads the head, recomputes the fingerprint from `tables` and compares,
and stats every named file. It hashes nothing (ADR-0008's rule, kept), and does
no network I/O (ADR-0013's, kept).

Tables load **lazily, one whole table on first touch**, resident until close. A
table file is hashed as it is read and the hash compared with its name **before
any byte of it reaches the model**, so no content is ever used unverified and a
wrong-content file is caught at load as a *damaged copy* naming `repair!`.
Untouched tables keep the head's `table_hash`, which the committer uses as is:
that skip trusts the head, and the head is content-addressed, so the logical
fingerprint it produces is right even if a local file has since been damaged —
the damage is the local copy's problem, caught at its next load, never the
chain's. `verify(db)` hashes everything on demand.

The ceiling is **1 GB per table file on disk**, chosen so that a table resident
as Julia values stays within a few GB at a 3–5× expansion. Lazy loading is
therefore required, not preferred, and the encoder and decoder stream a table
file rather than buffering it. The resident representation is issue #28's, with
this constraint handed to it.

## Persist cadence during a long replay (amends ADR-0013)

Writing every touched table file after every record is O(records × table bytes)
and dead at 10⁴ records. Instead `sync!` applies in memory and **checkpoints**:
always at the end, and mid-replay whenever the apply time since the last
checkpoint exceeds the duration of the last checkpoint. That bounds checkpoint
overhead to half the replay wall time and a restart to about two checkpoints of
lost work, with no knob and no dependence on table size.

**Every checkpoint is verified for free.** The table hashes are computed to name
the files, the fingerprint over them is trivial, and it is compared with that
record's `state_fingerprint`. ADR-0007's "a batch replay verifies the head only"
was a cost decision; it becomes "every checkpoint and the head". A failed sync
leaves the copy at the last checkpoint — consistent, and verified.

## Damage and divergence are caught in different places

This inverts ADR-0007's mismatch diagnostic. A **damaged copy** is a file whose
bytes do not hash to its name, or a head that is not self-consistent; it is
decided **without replay**, at open or at load, and it can never yield content.
A **fingerprint mismatch at apply can therefore no longer mean damage**: a
content-addressed head cannot name wrong hashes and still be self-consistent,
so the mismatch is divergence, or an apply bug, which from the chain's side is
the same thing. The error names the slot, both fingerprints and the record's
`client.lib` / `client.julia`, the client refuses to commit, and the error
still names `repair!` as the confirming step: a fresh replay that also
mismatches proves this machine cannot reproduce the chain.

**`repair!` runs in place** (amends ADR-0014). Replay from the record cache to
the head's slot in memory, encode and hash each table, compare with the head's
list. All match: rewrite only the files whose on-disk bytes did not hash to
their name. Head untouched, pin untouched, no temporary directory, no swap.
Mismatch: divergence, nothing written. A copy with no readable head cannot be
repaired; the error says to delete the directory and sync again.

## Layout version and binding

`layout_version` is one integer in the head, readable because the head's magic
names the layout before decoding. Table files carry none: they are frozen by
`format_version`. **Rebuild, never migrate** stands, and is cheaper than before
— replay time and zero downloads.

Open states: an absent or empty directory is unbound and fresh; a head present
is bound, and its `chain_id` is checked against the chain being opened; a
non-empty directory without `heads/` and `tables/` is *not a local copy*, a hard
error. Genesis through `create_chain` (ADR-0019) writes slot 0's head, whose
`tables` list may be empty.

## Considered options

- **The table file as a bare CBOR item**, hash taken over separator plus file.
  Rejected: `sha256sum` would no longer give the name, and the separator is a
  better magic than none.
- **The pin, bucket and prefix inside the head.** Rejected: a toggle would force
  an overwrite; location is not identity.
- **Keeping ADR-0008's applied log** as an append-only file, or by never
  sweeping heads. Rejected. Record N's hash transitively commits to every slot
  ≤ N, so the head's `transaction_hash` alone contradicts any rewrite below it;
  the log bought only *localization* after a record-cache eviction under a
  consistent rewrite, and a rewritten chain is a hard stop either way. Never
  sweeping heads would pin every superseded table file forever.
- **Whole model resident from open.** Rejected on the 1 GB-per-table ceiling.
- **Hashing every file at open.** Rejected, as ADR-0008 did: hash-on-load gives
  the same guarantee — nothing used unverified — at zero cost to open.
- **A fixed checkpoint interval, or a knob.** Rejected for the amortized rule,
  which needs neither and adapts to table size.
- **Table files in a machine-wide store**, shared across copies of one chain.
  Rejected for v1: a self-contained directory is one thing to copy, back up or
  delete, and content addressing makes sharing a later optimization with no
  format change.

## Consequences

- **ADR-0008 is deleted.** Its head, chain, applied and local-index tables have
  no successor beyond the head file; local indexes left with ADR-0022.
- **ADR-0009 is rewritten** around "the head is written last". No transaction
  is held open across the network round-trip; the single-machine concurrency
  fog loses that constraint and gains this one: **the sweep deletes files a
  second process may be about to name**, which is now the sharpest reason for
  ADR-0019's one-process-per-copy rule.
- **ADR-0007, 0013 and 0014 are amended in place** as marked above.
- **Named tests**: `sha256sum` of a table file equals its name; two heads at
  open after a simulated crash, the lower chosen when the higher's file is
  missing; an orphan table file swept; a `412` leaves the head untouched; a
  checkpoint's fingerprint compared to its record's; a zero-row table's file;
  a zero-table chain's head; a damaged file caught at load and not at open.
- **Glossary**: **Table file**, **Head file**, **Checkpoint** and **Damaged
  copy** added; **Local copy**, **Layout version** and **Divergence** rewritten;
  **Reserved table** dropped.
