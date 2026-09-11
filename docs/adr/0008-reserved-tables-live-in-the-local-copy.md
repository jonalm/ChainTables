---
status: accepted
---

# Reserved tables live inside the local copy, excluded from the fingerprint by name

A client's own state — which chain this local copy belongs to, where its head is,
what it has applied, which local indexes it built — lives in **reserved tables**
inside the local copy's own `.sqlite` file, under the `s3sqlite_` name prefix.
They are never named by a transaction record, never carried in the chain, and
never inside the state fingerprint.

## Why inside the file

The head must advance in the same atomic step as the ops it records. A local copy
holding ops whose head says otherwise — in either direction — is precisely the
inconsistency the head exists to prevent, and it is unrecoverable without a
fingerprint pass to work out which side is right.

SQLite gives that atomicity only within one database file. A sidecar
(`db.sqlite` + `meta.sqlite`, `ATTACH`ed) is atomic across both files **only when
the main database is not in WAL mode**; in WAL mode a multi-database transaction
is atomic per file, not as a set. Paying for a sidecar with a forfeited WAL mode,
or with a two-phase recovery path written by hand, is a worse trade than solving
the namespace problem the sidecar would have avoided.

## The tables

| table | rows | lifetime |
|---|---|---|
| `s3sqlite_chain` | 0 or 1 | write-once |
| `s3sqlite_head` | 0 or 1 | replaced on every apply |
| `s3sqlite_applied` | one per slot | append-only |
| `s3sqlite_local_index` | one per local index | per `create_local_index!` / `drop_table` |

- **`s3sqlite_chain`** — `chain_id`, `created_at_ms`. Written at the moment slot 0
  is applied or committed, never updated. This is the **binding** check: a
  `chain_id` that does not match the chain being opened is a hard error.
- **`s3sqlite_head`** — `slot`, `transaction_hash`, `state_fingerprint`,
  `format_version`, `pinned`, `applied_at_ms`, the last-synced `bucket` and
  `prefix`, and the **applying client's own** `sqlite_version`, `build_profile`
  and `lib`. Bucket and prefix are *location*, not identity — a chain may be
  legitimately copied elsewhere — so they inform diagnostics and bind nothing.
  The three client fields are the forensics ADR-0007 asks for by name: a local
  copy built under a different SQLite than the one now open is the first suspect
  in a fingerprint mismatch, and runtime values cannot reveal that.
- **`s3sqlite_applied`** — `slot` (PK), `transaction_hash`, `state_fingerprint`,
  `applied_at_ms`.
- **`s3sqlite_local_index`** — the index's name, its table, its columns and
  uniqueness, **structured, never as SQL text**; rendered through ADR-0004's
  bracketed identifiers at rebuild. A `drop_table` op deletes the rows for that
  table during apply, since SQLite drops the index itself and the registry would
  otherwise accumulate rows pointing at nothing.

These tables are ours, not the chain's, so ADR-0003's shape rules do not bind
them: `CHECK (id = 0)` to pin at most one row is correct here.

**`s3sqlite_applied` is not made redundant by the record cache.** It duplicates
~80 bytes of a record that may be 64 MiB, and they are the 80 bytes that are
*evidence*. The cache is machine-wide, disposable and explicitly clearable; after
an eviction nothing local would contradict a bucket whose objects had been
deleted and rewritten. The cache is a download optimization; the log is the
client's own account of what it applied, and it survives. What a client *does*
when the log and the bucket disagree is issue #14's.

**No `s3sqlite_table_hash` in v1.** ADR-0007's skip-untouched-tables optimization
buys ~5 s at the 10⁷-row ceiling, and `user_version` (below) makes adding a
reserved table later a purely local change that breaks no chain. That is what the
version is for.

## File-header marks

`PRAGMA application_id = 0x53335351` (ASCII `S3SQ`) and `PRAGMA user_version = 1`.
Both are readable before any table is touched, which is the point: a **layout
version** held in a column cannot be consulted before you know the layout. This
is a third, strictly local version number — `format_version` versions the chain's
wire bytes, `sqlite_version` is advisory, this one never leaves the machine.

**A mismatched layout version is never migrated.** A newer client discards the
local copy and replays from the chain; an older client meeting a newer layout
refuses to open it. The local copy is derived state and the record cache survives
the rebuild, so a rebuild costs replay time and zero downloads. Migration code is
a second way to produce a local copy, needs its own tests forever, and a
migration bug produces exactly the silent divergence this design exists to
prevent.

## The namespace, and where it is enforced

The prefix is `s3sqlite_`. It cannot be `sqlite_`, which SQLite reserves and
refuses to create. SQLite's identifier case-folding is ASCII-only, so the
comparison is an **ASCII fold**: `S3SQLITE_HEAD` collides and must be caught, a
Unicode-cased lookalike does not collide and must not be.

The write builder rejects an op naming a reserved table, and **replay rejects one
too** — that second rule is the load-bearing one, since it holds against a record
written by a future, older or hostile client, while the first is a courtesy to
the local author.

## The fingerprint excludes reserved tables by explicit name, not by prefix

**This sharpens ADR-0007.** Excluding *by prefix* would leave a hole: a user who
hand-creates `s3sqlite_evil` gets a table invisible to the fingerprint forever,
defeating "a foreign table is caught". Excluding by the explicit list of names
this layout version defines means anything else in the file — reserved-looking or
not — falls inside the fingerprint and diverges immediately.

The obvious objection is that a newer client's extra reserved table would
fingerprint as foreign to an older client. It cannot: `user_version` makes the
old client refuse the newer layout before the fingerprint is ever computed.

## Two things that were forced, not chosen

- **The head hash cannot be inside the fingerprint.** The fingerprint is computed
  before the record exists, the record then carries the fingerprint, and the
  transaction hash is taken over those bytes. Including the head would be
  circular.
- **Reserved-table writes cannot be ops in the chain.** Same circularity for the
  head, and the rest is per-client data — local timestamps, this machine's
  `build_profile` — that no other client could reproduce.

## What `open` checks

Cheap checks always; a full fingerprint pass never. A full pass is ~5 s at the
10⁷-row ceiling, which is unacceptable on every open of a read-heavy workload,
and it is already paid where it matters — ADR-0007's committer pre-check runs it
before any commit, and `verify()` runs it on demand.

At open: `application_id`, `user_version`, `s3sqlite_chain`'s `chain_id` against
the chain being opened, the head row's presence, and `head.slot == max(applied.slot)`
with matching hashes. Each fails loudly and specifically — a foreign `.sqlite`
says *not an S3SQLite local copy*, not *no such table*. Three states are cleanly
distinguishable: not an S3SQLite file (`application_id`), initialized but empty
(no chain row, the legitimate state for a chain that does not exist yet, per
ADR-0002's "a chain exists iff slot 0 exists"), and bound.

**The user's read handle carries `PRAGMA query_only = 1`**, cleared only inside
apply. The settled premise is that reads go straight to a plain `SQLite.DB`, and
nothing otherwise stops a stray `INSERT` from being caught silently, hours later,
by a fingerprint check. This guards accidents, not adversaries — the user can
clear the pragma, and that is fine. It also makes an explicit
`create_local_index!` necessary, which ADR-0003 wanted anyway once indexes left
the chain.

## Considered options

- **A sidecar metadata database.** Rejected above on WAL-mode atomicity. It was
  attractive: no namespace to reserve, no per-client junk in the user's file, and
  "adopt the fresh rebuild" becomes a single file swap.
- **A key/value `s3sqlite_meta` table** instead of typed tables. Rejected:
  untyped values mean every read is a lookup plus a type assertion, which is the
  opposite of fail-fast.
- **One table for identity and head together.** Rejected once the lifetimes
  diverged — identity is written once, position is replaced on every apply, and
  conflating them made "is this the right chain?" a check against a mutable row.
- **Storing local indexes as `CREATE INDEX` SQL.** Rejected: it would make the
  reserved tables the one place in the design that persists SQL text, when ops
  are structured precisely so that nothing does.
- **Not recording local indexes at all.** Rejected: ADR-0007's "adopt the fresh
  rebuild" recovery would silently drop every index, and the user would meet a
  performance cliff with no error to explain it. It is the only reserved table
  whose *absence* causes a user-visible surprise.
- **Migrating the reserved-table layout in place.** Rejected; see above.

## Consequences

- **A point-in-time rebuild is marked, not inferred.** `pinned` in `s3sqlite_head`
  distinguishes a local copy deliberately held at slot 40 from one merely sixty
  records behind; without it the next open would sync it forward and destroy what
  the user asked for. What the flag *does* — refuse to advance, refuse to commit,
  require an explicit unpin — is issue #14's to decide. ADR-0007's diagnostic
  rebuild into a temporary file is a pinned copy too.
- **Two processes on one local copy need no extra state.** SQLite's locking
  already serializes the transactions; the failure it does not catch is the
  second process applying a slot the first already applied. Re-reading
  `s3sqlite_head` *inside* the transaction and hard-erroring if it moved is one
  optimistic check that costs nothing, and it leaves the single-machine
  concurrency question free to settle locking policy without a different on-disk
  layout.
- **Error names and messages are issue #16's**, not this ADR's. What is fixed
  here is that each failure is *distinguishable* at open.
