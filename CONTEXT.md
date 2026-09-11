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

**Slot**:
One position in the chain. At most one transaction record ever occupies a slot,
and a record's slot never changes.
_Avoid_: index, offset, position, sequence

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
_Avoid_: sync, materialize, rehydrate, project

**Local index**:
An index a client builds on its own local copy to serve its own reads. It is
never named by a transaction record, so two clients may hold different ones and
still agree on the content.
_Avoid_: index (bare), secondary index, chain index

**Commit**:
To add a transaction record to the chain, which succeeds only if no other client
claimed the same position first.
_Avoid_: push, upload, write, publish

**Point-in-time rebuild**:
A replay that stops at a chosen transaction record, producing the local copy as
it stood at that point.
_Avoid_: time travel, snapshot, checkout

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
local copy obtains the same content. This is what the chain guarantees.
_Avoid_: determinism, reproducibility, idempotency

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
