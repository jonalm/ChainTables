---
status: accepted
---

# Head discovery gallops, and every object ChainTables writes is write-once

A client finds the chain head by probing `stat_object` at slot `N+1`, `N+2`, `N+4`,
`N+8`… from its own head — slot `0` when it has none — until a probe misses, then
bisecting the last gap. It is the only head-discovery mechanism: no listing, no
pointer object, no manifest. And every object ChainTables writes, of every kind, is
written once and never replaced.

## Galloping rests on the chain having no gaps

This is the assumption that makes bisection sound, and it has never been written
down as one. ADR-0002 gives it: a commit is a conditional PUT to `head + 1` after a
preflight head check, so slot `k` can only be occupied once `k-1` is. A missing
slot therefore means the end of the chain, never a hole in it. Anything that could
create a gap — a client writing ahead of the head, a compactor "reserving" slots —
would break head discovery, not merely the chain's tidiness.

Cost is one cheap `HEAD` per probe, `O(log Δ)` from a warm head and `O(log N)` cold
— about twenty probes at 10⁶ records. ADR-0010 removed the objection that used to
stand against this: a probe is a real HTTP `HEAD`, not a process spawn.

## Considered options

**`list_objects(prefix; start_after = <head key>)`** finds the head in a *single*
request in the warm case and hands back the exact tail to fetch, which galloping
needs two probes and a separate fetch plan to do. It loses on three counts: a LIST
is roughly ten times the price of a HEAD; cold start costs `Δ/1000` requests rather
than `log Δ`; and it depends on `ListObjectsV2` returning keys in lexicographic
order. Standard S3 documents that ordering, but S3 Express One Zone does not, and
issue #17 has not yet settled which stores ChainTables claims to support — so relying
on it would decide that question by accident. `list_objects` stays in the port;
**nothing in the protocol depends on listing, or on its order**, which is also what
keeps ADR-0010's deliberately shuffled in-process fake honest.

**A mutable pointer object** (`<prefix>/_latest`, a manifest) makes head discovery
one request flat. Rejected, and with it mutability anywhere: a mutable object can
never be read through the record cache, which ADR-0010 established is never
re-validated; it needs a second write verb the port does not have and would not
want; and it reintroduces staleness and write races into the one place the chain
was designed to have none. Twenty probes once at cold start is not worth that.

## Consequences

- **`put_object_if_absent` remains the only write verb**, and ADR-0002's
  prohibition on unconditional PUT and delete stays unrepresentable rather than
  merely forbidden — including for the reserved names ADR-0011 admits.
- **The record cache is safe for every object type**, not only transaction records.
  Its correctness rests on a key's bytes being immutable by protocol, and that now
  holds for everything ChainTables writes.
- **A miss is never memoized.** A client polling a slot that is still empty must see
  the record the moment it lands, so a failed probe is never cached — in contrast
  to a hit, which is cacheable forever.
- **Derived objects are addressed, not overwritten.** Anything cached in the bucket
  later is keyed by the slot it belongs to, so successive versions accumulate rather
  than replace. Since clients have no delete, cleanup is a bucket lifecycle rule or
  an external janitor, never a client.
