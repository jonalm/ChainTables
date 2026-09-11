# Commit is a conditional PUT to a sequence-numbered slot

A transaction record is committed by a single `PutObject` carrying `If-None-Match: *`
to the key `<prefix>/<12-digit zero-padded seq>`. S3 documents this as exact
first-writer-wins: the first write to finish succeeds and every other gets `412
Precondition Failed`. That *is* the conflict resolution — there is no second
mechanism, no timestamp arbitration, and no tie-breaker, because there are no ties.

The key must be computable from the parent state alone. If any part of it derived
from the new record's own content, two committers racing for the same position
would write *different* keys, both would succeed, and the precondition would never
collide — so the record's own `transaction_hash` cannot appear in its key.

## Considered options

**Timestamp arbitration** (`LastModified`, lowest wins) was the original sketch and
is retired. S3 documents no ordering guarantee of any kind for `LastModified` — not
monotonic, not unique, whole seconds on the wire, and not even returned by a
successful PUT. Three back-to-back writes during test-bucket provisioning already
produced a tie inside a three-object test.

**Hash-addressed keys** (`<prefix>/<prev_hash>`, so the record whose parent is `H`
lives at key `H`) satisfy the computable-from-parent rule and are self-verifying,
but they make the chain a linked list that can only be traversed one round trip at
a time. Sequence numbers let a cold client learn the head once and fetch `0..N` in
parallel, let head discovery gallop in `O(log Δ)` requests with no listing at all,
give a future compactor a *range* to name, and make a point-in-time rebuild a direct
address. The integrity that hash keys would have provided is retained by carrying
`prev_hash` in the body and validating it on every apply.

## Consequences

- **Forks are impossible under correct client behaviour** — only one object can ever
  exist at a slot. They are detected anyway: a record's `prev_hash` must equal the
  `transaction_hash` of slot `n-1`, and cached records are verified by content hash.
- **Clients never issue an S3 object deletion or an unconditional PUT** against a
  chain prefix. This is the one fork vector fully within our control, so it is closed
  by rule. (Deleting rows from the content is unaffected — that is an ordinary op,
  and it makes the chain longer, not shorter.)
- **`seq` and `prev_hash` live inside the hashed envelope**, not only in the key.
  Compaction dissolves individual keys as addresses, so a record whose position lived
  only in its key would lose it; and a `seq` outside the hash would let a record be
  relocated to another slot undetected.
- **A chain exists iff slot 0 exists.** Chain creation is an ordinary commit, with no
  bootstrap step, and two clients racing to create the same chain are resolved by the
  same rule as any other commit. Genesis carries no `prev_hash` field at all rather
  than a zero sentinel, which would be indistinguishable from a real parent hash.
- **The write path must expose the `412` as a value.** rclone exits `1` — the same
  code as a network failure — with `PreconditionFailed` only as English on stderr, so
  this protocol is not implementable on LazyFiles as it stands.
