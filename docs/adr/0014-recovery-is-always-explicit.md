---
status: accepted
---

# Nothing heals itself: repair, divergence and a rewritten chain

## The repair path is asked for, never taken

A state fingerprint mismatch **raises**, and the error names `repair!(db)`.
ADR-0007 defined the diagnostic — a fresh rebuild into a temporary file from the
cached records, adopt it if it matches, divergence if it does not — but not who
starts it. The client never does: a rebuild can take minutes and ends by
replacing the user's file, so it is a thing the user asks for.

`repair!` rebuilds into a temporary file, verifies the fingerprint at the target
slot, and on a match swaps it over the local copy — **recreating the local
indexes from the damaged copy's `s3sqlite_local_index` registry**, which is the
case ADR-0008 kept that table for, and clearing `pinned`, since the diagnostic
rebuild is itself a pinned copy. On a mismatch it reports divergence, and the
client refuses to commit onto that chain.

**Divergence is not persisted.** No column records it: ADR-0007's committer
pre-check re-derives it before every commit, and a stored flag can only go
stale — in the direction that matters, a copy marked clean that no longer is.

## A rewritten chain is evidence, not a state to recover from

Under correct client behaviour a slot holds one record for all time (ADR-0002)
and the chain has no gaps (ADR-0012). Two observations therefore mean an actor
outside the protocol has rewritten the bucket:

- a fetch of a slot present in `s3sqlite_applied` returns a different
  `transaction_hash`;
- the local head's own slot `N` is absent.

Both hard-error, and neither is ever healed. The first is checked on **every**
fetch of an already-applied slot, which is the only place it can be caught: the
record cache is machine-wide and explicitly clearable, so after an eviction
nothing else local would contradict a bucket whose objects had been deleted and
rewritten. That is what ADR-0008 kept `s3sqlite_applied` for.

The second costs one extra `stat_object` per sync, since galloping starts at
`N+1` and never looks down. It is also the symptom of a wrong bucket or prefix,
and the two cannot be told apart — ADR-0006 deliberately left "empty chain" and
"missing prefix" indistinguishable — so treating a missing head slot as "start
over" would silently rebuild a local copy against a chain that is not its own.

In all three cases the existing local copy stays readable. Refusing to commit is
not refusing to work.

## `verify`

`verify(db)` is one full fingerprint pass of the local copy against
`s3sqlite_head.state_fingerprint` — the ~5 s pass ADR-0008 deliberately keeps out
of `open`. `verify(db; full = true)` is ADR-0007's localizing form: walk the
cached records, rehash each and check `prev_hash`, replaying to bisect to the
first mismatching slot. Record-hash verification folds in here rather than
becoming a third entry point, because those records are exactly what a rebuild
would consume.

Error names and types are issue #16's. What is fixed here is that each of these
failures is distinguishable, and that none of them resolves itself.
