---
status: accepted
---

# Apply is one local transaction per record, and sync is explicit

`sync!(db)` probes slot `N` — the local head — gallops for the chain head from
`N+1` (ADR-0012), fetches the tail with a bounded read-ahead window into the
record cache, and applies the records **in slot order, one SQLite transaction per
record**, with `s3sqlite_head` and `s3sqlite_applied` advancing inside that same
transaction (ADR-0008).

## Why per record rather than per batch

ADR-0009 wraps a *commit* in one transaction, so the obvious reading is that a
batch replay is one transaction too. It is not, and the difference only shows at
cold start: 10⁴ records is one rollback journal holding every intermediate state
of a database ADR-0003 lets a single record rewrite wholesale, and a crash 9,000
records in loses all 9,000.

Per record makes the record the atom on disk as well as in the chain. A crash
always leaves a consistent local copy at some slot `k`, and the next `sync!`
resumes from it — cold start becomes restartable rather than all-or-nothing.

What per batch would have bought is a whole-sync rollback when the head
fingerprint mismatches. That is worth little: a mismatch sends the client to
ADR-0014's repair path whatever the local copy is holding, and ADR-0007 verifies
the head only, so every intermediate slot in a batch was unverified regardless. A
failed sync leaves the copy at `n-1` — consistent, and unverified in exactly the
way slot `n-1` was a moment earlier.

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
slot lands; `s3sqlite_applied` covers everything already applied.

## Consequences

- **ADR-0009's crash window closes itself.** A crash after the conditional PUT
  succeeded but before `COMMIT` leaves our own record in the chain at slot `n`
  and the local copy at `n-1`. The next `sync!` applies it as an ordinary record.
  There is no authorship special case, and there cannot be one — ADR-0006 made
  client metadata advisory.
- **No recovery journal of our own.** SQLite's atomicity covers every crash
  window, and ADR-0008's open checks cover what is left.
- **The read-ahead window is v1's only performance knob**, and the place the
  unmeasured cold-start question will first be felt.
