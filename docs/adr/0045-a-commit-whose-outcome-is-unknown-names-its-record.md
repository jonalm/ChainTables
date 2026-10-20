---
status: accepted
---

# A commit whose outcome is unknown names its record

`commit!` puts its record conditionally and reads the slot back (ADR-0010), so a
lost acknowledgement is settled inside the call. Some failures are not: the retries
are spent, the read-back itself fails, the call is interrupted, or the record lands
and the local copy's head is not written. The caller then sees an error and cannot
tell whether the commit happened. A client that retries its edits after such an
error writes them twice when the first record had landed, and its rebase sees its
own record as another client's (Bio-Me/BioMeCore.jl#26). The record carries the
time it was built, so the caller cannot recompute its hash; only `commit!` holds it.

## Decision

Every failure once the put began, other than one that says the record was not
written, is raised as **`CommitOutcomeUnknownError`** with the chain id, the slot,
our record's transaction hash, `landed` and the failure as `cause`. After
`sync!(copy)`, the commit happened exactly when `commit_log(copy)` shows that hash
at that slot: the chain has no gaps and a slot holds one record (ADR-0002), so the
answer is exact, not a guess from author and time.

A failure that says the record was not written passes through unchanged: a
`ChainTablesError` (the gateway's refusal, a rewritten chain) and a client-error
`TransportError` that is not retried (403, 400). A 5xx, a 409 or a timeout proves
nothing, so retries spent on them are unknown, though the last read-back found the
slot empty.

A failed head write is the same type with `landed = true`: the record is in the
chain, the next `sync!` applies it.

## Considered options

- **Return the hash on success only, raise the raw failure.** The hash is then lost
  exactly when it is needed. Rejected.
- **Let the caller match its record by author, host and time in the commit log.**
  The time is set inside `commit!`; two commits by one user from one host can only
  be told apart by guessing. Rejected.
- **Retry until the outcome is known.** An interrupt must stop the call, and a store
  that is down stays down; the caller decides when to look again. Rejected.

## Consequences

- The `TransportError` a caller saw after spent retries is now the `cause` of a
  `CommitOutcomeUnknownError`; its text is still in the message.
- `create_chain` is unchanged: its caller can see whether the chain exists.
