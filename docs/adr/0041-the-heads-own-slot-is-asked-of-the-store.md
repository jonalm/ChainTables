---
status: accepted
---

# The head's own slot is asked of the store

ADR-0014 holds a bound copy's head against its own slot `N` before every sync
and commit. An absent slot, or bytes of another hash, is a rewritten chain,
and bytes naming another chain are the wrong chain. ADR-0014 counted one
`fetch_object` of slot `N` for this. In practice the record cache served it.
ADR-0040 made `check_head_slot` go to the store only when the cached bytes did
not hash to the head. A warm cache holds the head's own bytes, so the store
was never asked, and the check passed whatever the store held.

So a bound copy never noticed that its prefix had been emptied or reused. Over
an emptied prefix, `sync!` returned `applied = 0`, and `commit!` wrote slot
`N+1` into the empty prefix: a gap, with no slots below it. Over a prefix
refilled with another chain, `commit!` wrote slot `N+1` on top of that chain,
whose next `sync!` raised `MalformedRecordError` ("the chain is dead"). One
stale machine killed another chain. The record cache is machine-wide
(ADR-0040), so any copy on the machine was enough to warm it. Issue #84.
ADR-0040 listed this gap and left it for its own issue.

## Decision

**`check_head_slot` fetches slot `N` from the store, past the record cache,
every time.** `sync!`, `commit!`'s pre-check and `as_of` all call it, so each
asks the store once. Absent bytes are `RewrittenChainError`. Bytes of another
hash are `WrongChainError` when the record names another chain, and
`RewrittenChainError` otherwise. A cold cache already behaved this way.

**Bytes that match the head replace a cache file that differs**
(`heal_record!`, with ADR-0040's warning). Bytes that do not match leave the
file as it was, as evidence.

## Considered options

- **Fetch past the cache in `commit!`'s pre-check only.** That stops the
  write, which is the harm. But `sync!` would still report `applied = 0`
  over an emptied prefix, and a reader would keep reading a chain that is no
  longer there. ADR-0014 already budgets the fetch per sync. Rejected.
- **`stat_object` slot `N` instead of fetching it.** A stat sees an emptied
  prefix, but not a refilled one. The store's ETag is not the transaction
  hash, and a record is small, so a GET costs about what a HEAD does.
  Rejected.
- **Check slot 0's chain id against the store instead.** That catches a
  reused prefix, but not a slot `N` rewritten within the same chain. Slot
  `N`'s hash commits to every slot below it (ADR-0023), so slot `N` is the
  one fetch that covers both. Rejected.

## Consequences

- Every `sync!` and `commit!` on a bound copy costs one GET of slot `N`, as
  ADR-0014 counted. An `as_of` over a pinned copy already at its target costs
  one GET too. Before, it was local on a warm cache.
- The window is narrowed, not closed. A prefix emptied between the pre-check
  and `commit!`'s conditional put still takes slot `N+1`. The protocol cannot
  make the two atomic, and an actor outside it is racing a commit.
- `open` still checks the chain id from the cached slot 0 alone, with no
  network (ADR-0040). A copy over a reused prefix opens, and the first
  `sync!` or `commit!` refuses it.
