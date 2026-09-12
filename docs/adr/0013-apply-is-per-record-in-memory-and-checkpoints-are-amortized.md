---
status: accepted
---

# Apply is per record in memory, checkpoints are amortized, and sync is explicit

`sync!(copy)` probes slot `N` — the local head — gallops for the chain head from
`N+1` (ADR-0012), fetches the tail with a bounded read-ahead window into the
record cache, and applies the records **in slot order to the model**, writing
the local copy's table files and a new head file at each **checkpoint**
(ADR-0023).

## Checkpoints, and why they are amortized

Amended by ADR-0023. This ADR first made every record one local write
transaction, so that a crash left a consistent copy at some slot `k` and cold start was
restartable rather than all-or-nothing. That property is kept; the mechanism is
not, because writing every touched table file after every record is
O(records × table bytes) and dead at 10⁴ records.

`sync!` checkpoints **always at the end, and mid-replay whenever the apply time
since the last checkpoint exceeds the duration of the last checkpoint**. That
bounds checkpoint overhead to half the replay wall time, bounds a restart to
about two checkpoints of lost work, needs no knob, and adapts to table size. A
crash leaves the copy at its last checkpoint's head, and the next `sync!`
resumes from it.

**Every checkpoint is verified.** Its table hashes are computed to name the
files, so the fingerprint is free and is compared with that record's
`state_fingerprint`; ADR-0007's "head only" becomes "every checkpoint and the
head". A failed sync leaves the copy at the last checkpoint — consistent, and
verified.

## Sync is explicit

`open` performs no network I/O and no replay, reads never sync, and commit does
not sync either — it hard-errors on a stale head (ADR-0002), because the row set
was computed against the state the builder saw. So **"up to date" means the head
as of the last `sync!`**, and the API never implies otherwise. The answer is
stale the moment it is computed; an implicit sync would only move that staleness
somewhere the user cannot see it.

`sync!` returns `(; applied, slot, transaction_hash)`, and nothing new is
`applied = 0` rather than an error. There is no `to = slot` argument: a live copy
deliberately stopped short is a fourth state, with no use ADR-0015's `as_of` does
not already serve.

## Fetching

Apply must be ordered; fetching need not be. Sequential fetch of 10⁴ records at a
~50 ms round trip is about eight minutes, and issue #15 removed rclone's bulk
parallelism when it removed rclone. A bounded read-ahead window over
`fetch_object` — default 8, configurable, 1 legal — is the whole mitigation:
records land in the record cache, and apply consumes them in slot order.

Cache writes go to a temp name and are `rename`d into place, and every cached
record is rehashed on read (ADR-0006). One asymmetry survives that: a record's
hash is vouched for by its child's `prev_hash`, so the newest record has nothing
vouching for it on first fetch. Trust on first fetch, pinned forever once the next
slot lands; the head's `transaction_hash` covers everything already applied
(ADR-0014).

## Consequences

- **ADR-0009's crash window closes itself.** A crash after the conditional PUT
  succeeded but before the head file is written leaves our own record in the
  chain at slot `n` and the local copy at `n-1`. The next `sync!` applies it as
  an ordinary record and finds its table files already present. There is no
  authorship special case, and there cannot be one — ADR-0006 made client
  metadata advisory.
- **No recovery journal of our own.** Write-once files with the head written
  last cover every crash window, and ADR-0023's open checks and sweep cover what
  is left.
- **The read-ahead window is v1's only performance knob**, and the place the
  unmeasured cold-start question will first be felt.
