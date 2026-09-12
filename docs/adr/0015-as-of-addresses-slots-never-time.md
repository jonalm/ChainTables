---
status: accepted
---

# `as_of` addresses slots, never time

`as_of(chain, target; path = nothing)` takes a **slot** or a **transaction
hash**. It does not take a timestamp.

## Why not time

Users reach for time first, and neither clock available can carry an address.

S3's `LastModified` is the defensible one — server-assigned, outside client
control — and it is unusable: whole seconds on the wire, ties observed inside a
three-object test (issue #6), no documented ordering guarantee of any kind (issue
#2), and it is not in the record, so reaching it costs an O(n) `stat_object`
sweep or the listing ADR-0012 spent an ADR avoiding.

The record's `client.time_ms` is the one users mean, and ADR-0006 made it
advisory: asserted by whoever committed, and not monotone across clients with
skewed clocks. Forcing monotonicity by rejecting a commit whose time does not
exceed its parent's was considered and rejected — it would stop a client with a
slow clock from committing at all, to buy a binary search over data that is still
only a client's word.

So time is a **separate, differently named lookup** that returns a slot, which the
caller then passes to `as_of`. Two names, so the advisory thing can never be
mistaken for an address. Its semantics are defined as a scan, since monotonicity
cannot be assumed: the highest slot whose `client.time_ms` is at or below `t`. A
time before the genesis record is an error, not slot 0 — there is no state before
slot 0 to return.

## The directory

`path = nothing` builds a temporary local copy, deleted on close; this is the
common case, a historical read. A given path is kept, and is **opened rather than
rebuilt** when it already exists bound to the same chain at the same slot and
pinned — ADR-0023's open checks are what make that safe. `as_of` never touches
the live local copy, and verifies the fingerprint of the record it stops at
(ADR-0007).

## Pinned, and `unpin!`

A pinned copy is marked by the empty `pin` file (ADR-0023); `sync!` on it errors
and commit on it errors. The pin exists precisely so that a copy deliberately
held at slot 40 is not silently advanced by the next open.

**`unpin!(copy)` exists.** Replaying 40 → 100 is deterministic and yields exactly
what a full replay from slot 0 would, so a pinned copy going live is legitimate;
it just must never happen by accident. The alternative — delete the directory
and rebuild — would charge a full replay to reach a state the copy is forty
records away from.
