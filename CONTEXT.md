# S3SQLite

Several independent clients agree on the content of a SQLite database without a
database server. The agreed content is an append-only, hash-chained sequence of
immutable records in an S3 bucket; each client keeps its own local copy of the
database, built by replaying that sequence.

## Language

### The chain

**Chain**:
The totally ordered, append-only sequence of transaction records under one S3
key prefix. One bucket holds many chains.
_Avoid_: log, stream, history, ledger

**Chain id**:
What a chain is called, minted when the chain is created and carried in every one
of its transaction records. Distinct from where the chain currently lives: a chain
copied to another bucket or prefix is still the same chain.
_Avoid_: prefix, path, location, name, uuid

**Slot**:
One position in the chain. At most one transaction record ever occupies a slot,
and a record's slot never changes. The chain has no gaps — a slot is only ever
filled once the one before it is.
_Avoid_: index, offset, position, sequence

**Reserved name**:
Anything under a chain's prefix that is not a slot. Clients ignore reserved names,
so whatever a later version of S3SQLite keeps there cannot break an earlier one.
_Avoid_: metadata object, sidecar, extra key. Distinct from a *reserved table*,
which lives inside a local copy rather than in the bucket.

**Transaction record**:
One immutable object in the chain. It holds the ops of one commit, and the
hashes that place it in the chain.
_Avoid_: commit object, changeset, delta, event, patch. Also avoid bare
*transaction* for a group of ops inside a record — no such group exists; the
record is the only grouping and the only atom.

**Transaction hash**:
The hash of a transaction record's stored bytes. It is what the next record
names as its parent, and it is never carried inside the record it identifies.
_Avoid_: record hash, content hash, digest, id

**Comment**:
Free text a client may attach to a transaction record. It is hashed with
everything else, and the software never reads it.
_Avoid_: label, message, tag, description

**Op**:
One structured change inside a transaction, such as the creation of a table or
the insertion of a set of rows. An op holds literal values only; it is never SQL
text and never a SQLite changeset.
_Avoid_: statement, command, mutation, operation

**Head**:
The last transaction record of the chain that a given client has applied.
_Avoid_: tip, latest, current, HEAD

**State fingerprint**:
A canonical hash of the whole logical content of the database after a transaction
record has been applied — the rows and the shape of every table the chain created,
and nothing a client keeps for itself. It is carried in the record, and every
client recomputes it. Distinct from the transaction hash: that one hashes stored
bytes, this one hashes content a client derived for itself.
_Avoid_: checksum, digest, merkle root, state hash

**Divergence**:
Two clients deriving different content from the same transaction records. A state
fingerprint mismatch that survives a fresh replay is divergence; one that a fresh
replay clears was a damaged local copy instead. A diverged client may still read,
but never commits.
_Avoid_: drift, corruption, conflict (that is two clients racing for a slot)

**Rewritten chain**:
A chain whose bucket contradicts what a client has already applied — a slot whose
record changed, or a slot that vanished. The protocol cannot produce one, so it is
evidence of an actor outside it, and no client ever heals one.
_Avoid_: corrupted chain, rollback, history rewrite

### Clients

**Client**:
One process with its own local copy and its own cache of transaction records.
Clients never talk to each other; they agree only through the chain.
_Avoid_: user, node, peer, replica

**Local copy**:
The SQLite database file a client builds by replay. It is derived state, always
rebuildable from the chain.
_Avoid_: materialized database, cache, mirror, replica

**Replay**:
To apply the ops of a sequence of transaction records, in chain order, to a local
copy. Schema is derived this way too, so a replay to an earlier point yields the
schema of that point.
_Avoid_: materialize, rehydrate, project. Distinct from a *sync*, which is the
whole round trip that ends in a replay.

**Sync**:
Bringing a local copy up to the chain's head: finding the head, fetching the
records after the copy's own, and replaying them. It is always asked for, never
implicit, and true only as of the moment it finished.
_Avoid_: pull, update, refresh, catch up

**Reserved table**:
A table inside a local copy that holds what a client keeps for itself — which
chain the copy belongs to, where its head is, what it has applied. No transaction
record may name one, and the state fingerprint covers none of them.
_Avoid_: metadata table, system table, internal table

**Layout version**:
Which set of reserved tables a local copy carries. Purely local, and never a
property of the chain — distinct from the record format version, which the chain
does carry. A client that meets a layout version other than its own rebuilds the
local copy or refuses it; it never migrates one.
_Avoid_: schema version, db version, format version (that is the chain's)

**Local index**:
An index a client builds on its own local copy to serve its own reads. It is
never named by a transaction record, so two clients may hold different ones and
still agree on the content.
_Avoid_: index (bare), secondary index, chain index

**Record cache**:
The machine-wide directory of transaction records a client has fetched. Keyed by
bucket and key, disposable, and never re-validated — correct because at most one
record ever occupies a slot, so a key's bytes are immutable by protocol. Distinct
from the local copy, which is derived from the records rather than a copy of them.
_Avoid_: blob cache, object cache, store, mirror

**Object store**:
The four operations S3SQLite needs of a bucket — fetch one object, put one object
only if its key is absent, stat one key, list a prefix. It is S3SQLite's own seam,
so the real client and the in-process double are interchangeable, and it carries
no delete.
Put-if-absent is the load-bearing one: a store that overwrites instead of
failing does not raise, it splits the chain. Only AWS S3 is supported for that
reason.
_Avoid_: backend, adapter, driver, blob store, client (that is the process)

**Assumed guarantee**:
A promise about the environment that S3SQLite cannot check, which a user makes on
its behalf by setting a named field. It lets a client commit where the software
would otherwise refuse, and it is named for the promise rather than for the rule
it lifts.
_Avoid_: override, flag, unsafe mode, escape hatch

**Commit**:
To add a transaction record to the chain, which succeeds only if no other client
claimed the same position first.
_Avoid_: push, upload, write, publish

**Point-in-time rebuild**:
A replay that stops at a chosen transaction record, producing the local copy as
it stood at that point.
_Avoid_: time travel, snapshot, checkout

**Pinned copy**:
A local copy deliberately held at a chosen transaction record rather than kept
current. It never advances and never commits until it is explicitly unpinned.
_Avoid_: snapshot, frozen copy, historical database

### Writing

**Write builder**:
The only way to create a transaction record. Reads go straight to SQLite; only
writes pass through the builder.
_Avoid_: DSL, query builder, ORM, writer

**Row set**:
The explicit rows an op names, computed by the client against its local copy
before the record exists. A record carries the rows that were found, never the
condition that found them.
_Avoid_: materialized rows, predicate, filter, where clause

**Replay determinism**:
The property that every client applying the same transaction record to the same
local copy obtains the same content. This is what the chain guarantees. It is
claimed on every machine the package runs on, but only for the SQLite library
the package itself ships.
_Avoid_: determinism, reproducibility, idempotency

**Typed value**:
A value as SQLite holds it — an integer, a float, text or a blob — rather than
any text rendering of it. Ops and the state fingerprint carry typed values only,
because rendering a number to text, and parsing text into a number, are where
clients on different SQLite versions or different processors stop agreeing.
_Avoid_: literal, raw value, stored value, cell

**Shape**:
What a table declaration is allowed to state: the columns, their storage class,
their nullability, and the primary key. Anything that constrains which content is
*permitted* rather than how it is structured is policy, and the chain carries
none of it.
_Avoid_: schema (for this sense), structure, layout

**Delete rows**:
An op that removes a named row set from the content. Distinct from destroying a
transaction record, which never happens — the chain only ever grows longer.
_Avoid_: bare "delete", drop, remove, purge
