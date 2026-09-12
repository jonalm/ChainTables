---
status: accepted
---

# The head file is written after the conditional PUT

A commit is a sequence of file writes around one network round-trip, and the
local copy's head file is written **last**:

```
apply the ops to the model
write the touched tables' files          (ADR-0023; existing names skipped)
compute the state fingerprint            (ADR-0007; free, from the file hashes)
build the record                         (ADR-0006)
conditional PUT to the slot              (ADR-0002)   ← rc = 0 required
write the head file                      (ADR-0023)
sweep
```

Anything other than `rc = 0` stops before the head. The old head and its files
are untouched, the new table files are orphans the next open sweeps, and the
model reloads the touched tables from the old head's files. Nothing is rolled
back because nothing was committed locally.

Rewritten by issue #26. The first version of this ADR wrapped the PUT inside
the local copy's write transaction so that a `412` would roll the apply back;
the argument was
that ops are not invertible (ADR-0003 admits whole-table rewrites) and a local
copy holding a rejected record had no recovery short of a full replay. That
argument stands; what changed is the mechanism. With write-once, hash-named
files there is no partial state to undo: a head either exists, naming complete
files, or it does not.

## Consequences

- **No write transaction is held open across the network round-trip.** The
  cost the first version recorded — a second process blocking for the duration
  of a PUT — is gone. The single-machine concurrency question inherits
  ADR-0023's sweep instead.
- **Idempotent recovery still reads the slot back.** ADR-0002's `412` handling
  — fetch the slot, compare `transaction_hash` — decides whether to write the
  head (lost acknowledgement, our record is there) or stop and raise (lost
  race).
- **The window between PUT and head write is ADR-0014's orphan**: our record is
  in the chain at slot `n`, the copy is at `n-1`, and the next `sync!` applies it
  as an ordinary record and finds its table files already present.
- **Applying records from the chain is unaffected.** There is no PUT, so a
  replay is model updates plus checkpoints (ADR-0013).
