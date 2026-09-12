---
status: accepted
---

# Nothing heals itself: repair, divergence and a rewritten chain

## The repair path is asked for, never taken

A damaged copy — a table file whose bytes do not hash to its name, or a head
that is not self-consistent — **raises** at open or at load, and the error names
`repair!(copy)`. A state fingerprint mismatch at apply is divergence (ADR-0007 as
amended by ADR-0023) and raises too, naming `repair!` as the confirming step.
The client never starts a rebuild itself: it can take minutes, so it is a thing
the user asks for.

`repair!` runs **in place** (amended by ADR-0023). It replays from the cached
records to the head's slot in memory, encodes and hashes each table, and
compares the list with the head's. All match: it rewrites only the files whose
on-disk bytes did not hash to their name; the head and the pin are untouched,
and there is no temporary directory and no swap. Mismatch: divergence, nothing
written, and the client refuses to commit onto that chain. A copy with no
readable head cannot be repaired; the error says to delete the directory and
sync again.

**Divergence is not persisted.** No column records it: ADR-0007's committer
pre-check re-derives it before every commit, and a stored flag can only go
stale — in the direction that matters, a copy marked clean that no longer is.

## A rewritten chain is evidence, not a state to recover from

Under correct client behaviour a slot holds one record for all time (ADR-0002)
and the chain has no gaps (ADR-0012). Two observations therefore mean an actor
outside the protocol has rewritten the bucket:

- a fetch of the local head's own slot `N` returns a different
  `transaction_hash` from the head file's;
- the local head's own slot `N` is absent.

Both hard-error, and neither is ever healed. Amended by ADR-0023: this ADR first
checked every fetch of an already-applied slot against a per-slot applied log.
The log is gone, because record `N`'s hash transitively commits to every slot
below it, so the head's `transaction_hash` alone contradicts any rewrite of the
chain the copy has applied. What the log bought was *localization* after a
record-cache eviction under a consistent rewrite; `verify(copy; full=true)`'s
`prev_hash` walk recovers what it can, and a rewritten chain is a hard stop
regardless.

Both checks cost one `fetch_object` of slot `N` per sync, since galloping starts
at `N+1` and never looks down. Absence is also the symptom of a wrong bucket or
prefix, and the two cannot be told apart — ADR-0006 deliberately left "empty
chain" and "missing prefix" indistinguishable — so treating a missing head slot
as "start over" would silently rebuild a local copy against a chain that is not
its own.

In all three cases the existing local copy stays readable. Refusing to commit is
not refusing to work.

## `verify`

`verify(copy)` hashes every table file the head names, recomputes the fingerprint
from the head's `tables` list and compares both with the head — the pass
ADR-0023 deliberately keeps out of `open`; local only, no network. `verify(copy;
full = true)` is ADR-0007's localizing form: walk the cached records, rehash each
and check `prev_hash`, replaying to bisect to the first mismatching slot.
Record-hash verification folds in here rather than becoming a third entry point,
because those records are exactly what a rebuild would consume.

Error names and types are issue #16's. What is fixed here is that each of these
failures is distinguishable, and that none of them resolves itself.
