---
status: accepted
---

# The conditional PUT happens inside the local transaction

A commit is one SQLite transaction wrapped around the network round-trip:

```
BEGIN
  apply the ops
  compute the state fingerprint          (ADR-0007)
  build the record                       (ADR-0006)
  conditional PUT to the slot            (ADR-0002)   ← rc = 0 required
  write s3sqlite_head / s3sqlite_applied (ADR-0008)
COMMIT
```

Anything other than `rc = 0` rolls back, and the local copy is untouched.

ADR-0002 settled what the commit does to the bucket and ADR-0007 settled that the
fingerprint check happens before `COMMIT`; neither said where the PUT sits
relative to the local transaction, and the two orderings are not equivalent. The
alternative — commit locally, then PUT — leaves a local copy holding a record the
chain rejected whenever the PUT returns `412`, which then needs a compensating
un-apply path. There is no such path: the ops are not invertible in general
(ADR-0003 admits whole-table rewrites), so the only recovery would be a full
replay from the chain. Putting the PUT inside the transaction replaces that with
SQLite's own rollback.

This is also what ADR-0008's reserved tables bought with their atomicity
argument: the head advances in the same atomic step as the ops it records, and a
lost race leaves neither.

## Consequences

- **A write transaction is held open across a network round-trip.** This is only
  acceptable because writes are infrequent and single-writer by assumption, both
  stated premises of the design; it is recorded here as a deliberate cost rather
  than left as an accident. It is the sharpest constraint on the unsettled
  single-machine concurrency question: a second process on the same local copy
  blocks for the duration of an S3 PUT.
- **Idempotent recovery still reads the slot back.** ADR-0002's `412` handling —
  fetch the slot and compare `transaction_hash` to distinguish a lost
  acknowledgement from a lost race — happens with the transaction still open. A
  lost acknowledgement means our own record is there, so the transaction commits;
  a lost race rolls back and raises.
- **Applying records from the chain is unaffected.** There is no PUT, so the
  transaction is local-only and short.
