---
status: accepted
---

# The commit log is read from a local copy, down from its head

A client that edits tables wants to show who changed them lately: slot, author,
time and comment of the newest records. All four are in every record
(ADR-0006), but the only way to them was the internal `Ops.decode_record` over
bytes the caller fetched. BioMeCore's `LabTables.recent_commits` needs a public
read (Bio-Me/BioMeCore.jl#18).

## Decision

`commit_log(copy; last = nothing)` returns the copy's history newest first, one
`(; slot, transaction_hash, author, host, time_ms, comment)` per record, from
the copy's head down to slot 0 or the `last` newest. Genesis is included: it is
a record, and `create_chain`'s author is a fact.

**It takes a local copy, not a chain.** The log is the history of the state the
caller reads: a copy behind the chain reports its own head, `sync!(copy)` first
for the newest, and a pinned copy's log ends at its pin.

**It walks down from the head.** The head names its record's transaction hash,
and every record names its parent's (the walk `verify(copy; full = true)` and
`repair!` already make). A cached record whose bytes hash to the name the slot
above gives is the record the copy applied, so it needs no store to vouch for it
(ADR-0040 asks the store for what is *on the chain*; this reads what the copy
*applied*). A miss or a mismatch is fetched from the store once and held to the
same name: bytes that hash to it heal the cache, bytes that do not are
`RewrittenChainError`, the cached file left as evidence. A warm cache is read
with no network I/O, and `last = n` decodes `n` records.

**Time stays `time_ms`.** The record's own field and unit, and what `slot_at`
takes: no `Dates` dependency for a conversion the caller can do.

## Considered options

- **`commit_log(chain; last)`**, as the issue first put it. The chain's head is
  a gallop away, but a record above slot 0 is vouched for only by a forward read
  from slot 0 (`read_forward`), which decodes the whole chain to report its tail;
  and the log could then name commits the caller's copy has not applied.
  Rejected.
- **A log table the client maintains in its own data.** Duplicates what every
  record already carries, and can disagree with it. Rejected.
- **Return `Record`s.** Hands out ops and the envelope's internals, which no
  log reader needs, and fixes `Record` as public surface. Rejected.
- **Oldest first.** A log is read from the newest; `last` would then index from
  the end. Rejected.

## Consequences

- `cached_chain_hashes` (verify, repair!) is now a use of `walk_back`, the walk
  with a callback that may stop it early.
- The **Comment** is still never acted on; `commit_log` hands it back as text.
