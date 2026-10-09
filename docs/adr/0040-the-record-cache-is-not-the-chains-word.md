---
status: accepted
---

# The record cache is not the chain's word

ADR-0010 said a cached record is never re-validated, and that this is correct
because a slot holds at most one record for all time. That holds for the
bucket. It does not hold for the file on disk. A cache file can be truncated
by a power loss (nothing is fsynced), damaged by the disk, or hold another
store's object: the cache was keyed by bucket name and key only, so a MinIO
bucket and an AWS bucket with the same name shared files, and a test bucket
that was emptied and refilled still does. Every reader trusted a hit. So a
damaged cache was reported as a damaged chain: `sync!` raised
`MalformedRecordError` ("the chain is dead beyond this slot") or
`RewrittenChainError` ("written from outside the protocol"), though deleting
one file fixed it. `verify(full = true)` raised `ArgumentError` and
`ErrorException`, and `slot_at` and `as_of` by hash answered from records they
never linked. Issue #70.

## Decision

**The cache is keyed by the store's namespace too.** A record is cached at
`cache_dir/<namespace>/<bucket>/<key>`. `cache_namespace(store)` is `aws`,
`aws-cn` or `aws-us-gov` for AWS's own URL, where bucket names are unique in
the partition, and `ep-` with 8 hex digits of the SHA-256 of the canonical
`scheme://host[:port]` for a configured endpoint. A gateway store reads from
S3 directly and shares its S3 client's namespace. Each
`Testing.InMemoryObjectStore` is its own (`mem-` and 8 random hex digits). Any
other store is `other`. It is internal dispatch, like `record_author`; the port
stays four verbs (ADR-0010). Two stores that may hold different objects under
one name no longer share a file.

**A hit is still served without asking the store, but no reader trusts it on
its own.** Only bytes the store returned vouch for a record:

- **The forward reader (`read_forward`) yields a cached record only once a
  record the store returned names it**, directly or through a run of cached
  records that name each other. `sync!`, `as_of`, `slot_at` and `as_of` by
  hash all read through it. A record must decode, carry the chain's id, and
  name its parent's hash. A record fetched from the store, a miss, is yielded
  once checked. The last record of a read, and slot 0, are always fetched from
  the store, so every read ends vouched for. Up to 64 MiB of a cached run
  waiting to be vouched for is kept decoded; the rest is read from the cache
  again, and a file that changed meanwhile is `RecordCacheError`.
- **A check that fails is asked of the store before the chain is blamed.**
  First the slot's own bytes. If the store's bytes fail against a cached
  parent, the cached run below is fetched from the store from the top down,
  until the store's bytes at a slot equal the cache's. That slot vouches for
  the run below it, and the store's bytes above it are checked upwards. A run
  of cached records that agree with each other, carry the chain's id, and are
  not the store's (an emptied and refilled bucket, holding a fork of the same
  chain) is therefore replaced, never applied or checkpointed.
- **Only the store's bytes raise** `RewrittenChainError` or
  `MalformedRecordError`.
- **The store's bytes replace a cache file only once they pass**
  (`heal_record!`), with a warning naming the file when it held other bytes.
  When the store's bytes fail too, the cached file stays as it was, as
  evidence.

**The head's own slot (`check_head_slot`) is fetched again when the cached
bytes do not hash to the head.** The head is ours, so it is the anchor.

**`verify(copy; full = true)` stays local.** A record the cache lacks or holds
other bytes for raises the new `RecordCacheError`, naming the file and both
hashes, with `repair!(copy)` as the next move. **`repair!` fetches such a
record itself** and replaces the file instead of telling the user to delete
it. The store's bytes not hashing to what the chain names are
`RewrittenChainError`. A cache file that changes while `verify` or `repair!`
reads it is `RecordCacheError` too: another process is writing the cache.

**The read-back of a put asks the store, never the cache.** ADR-0010 made the
read-back the authority, and a cache file is not one.

## Considered options

- **Keep the key at bucket and key, and rely on the checks.** The first
  draft of this ADR. A stale file is replaced the first time a check fails,
  so the key needs no change. But two stores sharing a bucket name rewrite
  each other's files on every read: one synchronous GET and one warning per
  slot, with no read-ahead. And a reader over AWS cannot tell another store's
  run of the same chain from a rewritten bucket. Rejected.
- **The endpoint's host as the namespace.** Readable, but a host costs up to
  253 characters of the path budget ADR-0034 gave to `cache_dir`. A short
  hash costs 12. Rejected.
- **Vouch for a cached record one level up: the next record names it.** The
  first implementation. A cached run of two or more records that name each
  other was applied, and could be checkpointed, before the store's record
  above it disagreed. Rejected for the store-vouched rule above.
- **Hash-check every hit against a hash stored beside it.** Disk damage would
  then be caught, but another store's object hashes correctly. Only the chain
  knows which bytes belong at a slot. Rejected.
- **Raise on a damaged cache instead of replacing the file.** The cache is
  disposable (ADR-0010), and replacing a file loses nothing. The warning keeps
  the event visible. Only `verify`, which is local by contract, raises.
- **Always fetch the head's slot from the store.** ADR-0014 counts one fetch
  of slot N per sync, but in practice the cache serves it, so a rewrite of
  slot N alone goes unseen until the next record. That is a separate gap in
  rewrite detection, not a cache-damage problem. Left for its own issue.

## Consequences

- ADR-0010's "a cached record is never re-validated" now means "never asked
  of the store on a hit". The chain's readers check every hit, and a cached
  record waits for the store to vouch for it.
- The path below `cache_dir` grows by up to 13 characters. ADR-0034's
  budget is now 12 + 1 + 63 + 1 + 100 + 1 + 20 = 198, which leaves 61 for
  `cache_dir`. Every record cached before this change is fetched again once,
  into its namespace.
- A fresh `sync!`, an `as_of` and a scan each fetch slot 0 and their last slot
  from the store even when cached. A `sync!` that finds a cached record at the
  top fetches it once more.
- A cached record is applied only when the read reaches a record the store
  returned. A `sync!` that fails mid-read leaves the copy at the last record
  the store vouched for, which can be lower than before.
- `open` still reads the chain id from the cached slot 0 alone (no network).
  A stale file there can raise `WrongChainError` at open, and the message does
  not mention the cache. With the namespace, only a bucket that was emptied
  and refilled can cause it. Not addressed here.
- Adds `RecordCacheError`, the seventeenth type (ADR-0020).
