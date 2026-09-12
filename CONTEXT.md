# ChainTables

Several independent clients agree on the content of a set of tables without a
server. The agreed content is an append-only, hash-chained sequence of immutable
records in an S3 bucket; each client keeps its own local copy of the tables,
built by replaying that sequence.

_History_: until 2026-09-12 the package was S3SQLite and a local copy was a
SQLite file. SQLite is no longer anywhere on the replay path
([ADR-0022](docs/adr/0022-content-lives-in-a-julia-model-and-determinism-rests-on-the-encoder.md)),
which is why several database words appear under _Avoid_ below.

Each term ends with the ADR that owns it.

## Language

### The chain

**Chain**:
The totally ordered, append-only sequence of transaction records under one S3
key prefix. One bucket holds many chains.
_Avoid_: log, stream, history, ledger
_See_: [ADR-0011](docs/adr/0011-a-chain-is-flat-slot-keys-plus-reserved-names.md)

**Chain id**:
What a chain is called, minted when the chain is created and carried in every one
of its transaction records. Distinct from where the chain currently lives: a chain
copied to another bucket or prefix is still the same chain.
_Avoid_: prefix, path, location, name, uuid
_See_: [ADR-0011](docs/adr/0011-a-chain-is-flat-slot-keys-plus-reserved-names.md)

**Slot**:
One position in the chain. At most one transaction record ever occupies a slot,
and a record's slot never changes. The chain has no gaps — a slot is only ever
filled once the one before it is.
_Avoid_: index, offset, position, sequence
_See_: [ADR-0002](docs/adr/0002-commit-is-a-conditional-put-to-a-sequence-numbered-slot.md)

**Reserved name**:
Anything under a chain's prefix that is not a slot. Clients ignore reserved names,
so whatever a later version of ChainTables keeps there cannot break an earlier one.
_Avoid_: metadata object, sidecar, extra key. Distinct from a *head file*,
which lives inside a local copy rather than in the bucket.
_See_: [ADR-0011](docs/adr/0011-a-chain-is-flat-slot-keys-plus-reserved-names.md)

**Transaction record**:
One immutable object in the chain. It holds the ops of one commit, and the
hashes that place it in the chain.
_Avoid_: commit object, changeset, delta, event, patch. Also avoid bare
*transaction* for a group of ops inside a record — no such group exists; the
record is the only grouping and the only atom.
_See_: [ADR-0006](docs/adr/0006-a-record-is-one-cbor-map-hashed-as-stored-bytes.md)

**Transaction hash**:
The hash of a transaction record's stored bytes. It is what the next record
names as its parent, and it is never carried inside the record it identifies.
_Avoid_: record hash, content hash, digest, id
_See_: [ADR-0006](docs/adr/0006-a-record-is-one-cbor-map-hashed-as-stored-bytes.md)

**Comment**:
Free text a client may attach to a transaction record. It is hashed with
everything else, and the software never reads it.
_Avoid_: label, message, tag, description
_See_: [ADR-0006](docs/adr/0006-a-record-is-one-cbor-map-hashed-as-stored-bytes.md)

**Op**:
One structured change inside a transaction record, such as the creation of a
table or the insertion of a row set. An op holds literal values only and is
applied without evaluating anything; it is never text in a query language.
_Avoid_: statement, command, mutation, operation, query
_See_: [ADR-0025](docs/adr/0025-ops-and-rows-are-typed-values-ordered-by-key-and-apply-re-validates.md)

**Head**:
The last transaction record of the chain that a given client has applied. The
chain's own head is its last record; a client's head lags it until the next sync.
_Avoid_: tip, latest, current, HEAD
_See_: [ADR-0013](docs/adr/0013-apply-is-per-record-in-memory-and-checkpoints-are-amortized.md)

**State fingerprint**:
A canonical hash of the whole content after a transaction record has been
applied — the shape and the rows of every table the chain created, and nothing a
client keeps for itself. It is carried in the record, and every client recomputes
it. Distinct from the transaction hash: that one hashes stored bytes, this one
hashes content a client derived for itself.
_Avoid_: checksum, digest, merkle root, state hash
_See_: [ADR-0007](docs/adr/0007-the-state-fingerprint-is-a-two-level-hash-recomputed-in-full.md)

**Divergence**:
Two clients deriving different content from the same transaction records. A state
fingerprint mismatch is divergence, because a damaged copy is caught by hash
before any content is used and so can never produce one. A diverged client may
still read, but never commits.
_Avoid_: drift, corruption, conflict (that is two clients racing for a slot)
_See_: [ADR-0014](docs/adr/0014-recovery-is-always-explicit.md)

**Rewritten chain**:
A chain whose bucket contradicts what a client has already applied — a slot whose
record changed, or a slot that vanished. The protocol cannot produce one, so it is
evidence of an actor outside it, and no client ever heals one.
_Avoid_: corrupted chain, rollback, history rewrite
_See_: [ADR-0014](docs/adr/0014-recovery-is-always-explicit.md)

**Malformed record**:
A transaction record whose bytes hash correctly but whose ops break a rule of the
format or contradict the content they apply to, so that no client can apply it.
It is the committer's bug, and the chain is dead beyond it. Distinct from a
damaged copy (a local file), divergence (clients disagreeing about content) and a
rewritten chain (the bucket changed).
_Avoid_: invalid record, bad record, corrupt record
_See_: [ADR-0025](docs/adr/0025-ops-and-rows-are-typed-values-ordered-by-key-and-apply-re-validates.md)

### Clients

**Client**:
One process with its own local copy and its own cache of transaction records.
Clients never talk to each other; they agree only through the chain.
_Avoid_: user, node, peer, replica
_See_: [ADR-0019](docs/adr/0019-the-public-surface-is-two-types-and-nothing-is-exported.md)

**Local copy**:
The directory a client builds by replay: one table file per table and one head
file. It is derived state, always rebuildable from the chain, and everything in it
may be deleted.
_Avoid_: materialized database, database, cache, mirror, replica
_See_: [ADR-0023](docs/adr/0023-the-local-copy-is-hash-named-table-files-and-a-slot-named-head.md)

**Table view**:
A read of one table of a local copy, fixed at the head the copy had when the
view was taken. It is the only way content is read. A sync or a commit moves the
copy and leaves every view already taken as it was, and nothing done to a view
reaches the copy.
_Avoid_: snapshot, query result, cursor, handle, dataframe
_See_: [ADR-0024](docs/adr/0024-the-read-surface-is-a-table-view-fixed-at-its-head.md)

**Table file**:
The file that holds one table's content in a local copy — exactly the bytes the
state fingerprint hashes for that table, so the file is named by its own hash. A
table file is written once and never changed; a table that changes gets a new
file. Two tables with the same content share one.
_Avoid_: data file, snapshot, page, segment
_See_: [ADR-0023](docs/adr/0023-the-local-copy-is-hash-named-table-files-and-a-slot-named-head.md)

**Head file**:
The one file in a local copy that says which transaction record the content is
the result of, and which table file holds each table. Named by slot, written once,
and written after every table file it names, so that a head that exists names
files that are complete. Everything a client keeps for itself lives here.
_Avoid_: manifest, index, metadata file, catalog, reserved table
_See_: [ADR-0023](docs/adr/0023-the-local-copy-is-hash-named-table-files-and-a-slot-named-head.md)

**Checkpoint**:
Writing the table files and a head file for the record a replay has reached. A
replay checkpoints at its end and, when long, at amortized points in between; a
checkpoint's state fingerprint is checked against its record.
_Avoid_: flush, save, snapshot, commit (that is adding a record to the chain)
_See_: [ADR-0013](docs/adr/0013-apply-is-per-record-in-memory-and-checkpoints-are-amortized.md)

**Damaged copy**:
A local copy holding a table file whose bytes do not hash to its name, or a head
file that does not agree with itself. It is found by hashing, never by replay, and
no content from it is ever used. Distinct from divergence, which is about content
two clients disagree on.
_Avoid_: corrupted database, bad copy, inconsistent state
_See_: [ADR-0023](docs/adr/0023-the-local-copy-is-hash-named-table-files-and-a-slot-named-head.md)

**Replay**:
To apply the ops of a sequence of transaction records, in chain order, to a local
copy. Shape is derived this way too, so a replay to an earlier point yields the
shape every table had at that point.
_Avoid_: materialize, rehydrate, project. Distinct from a *sync*, which is the
whole round trip that ends in a replay.
_See_: [ADR-0022](docs/adr/0022-content-lives-in-a-julia-model-and-determinism-rests-on-the-encoder.md)

**Sync**:
Bringing a local copy up to the chain's head: finding the head, fetching the
records after the copy's own, and replaying them. It is always asked for, never
implicit, and true only as of the moment it finished.
_Avoid_: pull, update, refresh, catch up
_See_: [ADR-0013](docs/adr/0013-apply-is-per-record-in-memory-and-checkpoints-are-amortized.md)

**Layout version**:
Which arrangement of head file and table files a local copy uses. Purely local,
and never a property of the chain — distinct from the record format version,
which the chain does carry. A client that meets a layout version other than its
own rebuilds the local copy or refuses it; it never migrates one.
_Avoid_: schema version, db version, format version (that is the chain's)
_See_: [ADR-0023](docs/adr/0023-the-local-copy-is-hash-named-table-files-and-a-slot-named-head.md)

**Record cache**:
The machine-wide directory of transaction records a client has fetched. Keyed by
bucket and key, disposable, and never re-validated — correct because at most one
record ever occupies a slot, so a key's bytes are immutable by protocol. Distinct
from the local copy, which is derived from the records rather than a copy of them.
_Avoid_: blob cache, object cache, store, mirror
_See_: [ADR-0010](docs/adr/0010-s3sqlite-owns-its-s3-client-and-its-record-cache.md)

**Object store**:
The four operations ChainTables needs of a bucket — fetch one object, put one object
only if its key is absent, stat one key, list a prefix. It is ChainTables's own seam,
so the real client and the in-process double are interchangeable, and it carries
no delete.
Put-if-absent is the load-bearing one: a store that overwrites instead of
failing does not raise, it splits the chain. Only AWS S3 is supported for that
reason.
_Avoid_: backend, adapter, driver, blob store, client (that is the process)
_See_: [ADR-0010](docs/adr/0010-s3sqlite-owns-its-s3-client-and-its-record-cache.md)

**Assumed guarantee**:
A promise about the environment that ChainTables cannot check, which a user makes on
its behalf by setting a named field. It lets a client commit where the software
would otherwise refuse, and it is named for the promise rather than for the rule
it lifts.
_Avoid_: override, flag, unsafe mode, escape hatch
_See_: [ADR-0016](docs/adr/0016-v1-claims-aws-s3-only-and-the-gate-is-on-commit.md)

**Commit**:
To add a transaction record to the chain, which succeeds only if no other client
claimed the same position first.
_Avoid_: push, upload, write, publish
_See_: [ADR-0002](docs/adr/0002-commit-is-a-conditional-put-to-a-sequence-numbered-slot.md)

**Point-in-time rebuild**:
A replay that stops at a chosen transaction record, producing the local copy as
it stood at that point.
_Avoid_: time travel, snapshot, checkout
_See_: [ADR-0015](docs/adr/0015-as-of-addresses-slots-never-time.md)

**Pinned copy**:
A local copy deliberately held at a chosen transaction record rather than kept
current. It never advances and never commits until it is explicitly unpinned.
_Avoid_: snapshot, frozen copy, historical database
_See_: [ADR-0015](docs/adr/0015-as-of-addresses-slots-never-time.md)

### Writing

**Write builder**:
The only way to create a transaction record. Reads go through table views; only
writes pass through the builder. A builder is a value, and it is used once: it
collects the ops of one transaction record, and committing it consumes it. It is
never re-run, because a commit that loses its slot is raised rather than retried.
_Avoid_: DSL, query builder, ORM, writer
_See_: [ADR-0001](docs/adr/0001-write-builder-is-plain-functions.md)

**Row set**:
The explicit rows an op names, computed by the client against its local copy
before the record exists. A record carries the rows that were found, never the
condition that found them.
_Avoid_: materialized rows, predicate, filter, where clause
_See_: [ADR-0005](docs/adr/0005-ops-name-rows-by-primary-key.md)

**Replay determinism**:
The property that every client applying the same transaction records obtains the
same content and the same state fingerprint. It is a property of the record
format and the frozen encoder alone, and of nothing on the machine, so it is
claimed wherever the package runs.
_Avoid_: determinism, reproducibility, idempotency
_See_: [ADR-0022](docs/adr/0022-content-lives-in-a-julia-model-and-determinism-rests-on-the-encoder.md)

**Value type**:
One of the four kinds a column is declared to hold: `int64`, `float64`, `text`
or `bytes`. Each admits the whole of its domain — `float64` includes NaN and
±Inf — and null is not a member of any of them.
_Avoid_: storage class, type (bare), column type, type tag (that is the Julia
type the write builder accepts for a value type)
_See_: [ADR-0025](docs/adr/0025-ops-and-rows-are-typed-values-ordered-by-key-and-apply-re-validates.md)

**Typed value**:
A value of one of the four value types, as a cell holds it. Ops, the local copy
and the state fingerprint carry typed values only, and a typed value is never
converted, rendered or parsed on its way from a transaction record to the
fingerprint. Null is not a typed value: it is the absence a nullable column
allows, read as `missing`.
_Avoid_: literal, raw value, stored value, cell
_See_: [ADR-0022](docs/adr/0022-content-lives-in-a-julia-model-and-determinism-rests-on-the-encoder.md)

**Shape**:
What a table declaration is allowed to state: the columns, their value type,
their nullability, and the primary key. It carries no default. Anything that
constrains which content is *permitted* rather than how it is structured is
policy, and the chain carries none of it.
_Avoid_: schema, structure, layout, DDL
_See_: [ADR-0003](docs/adr/0003-the-schema-declares-shape-never-policy.md)

**Delete rows**:
An op that removes a named row set from the content. Distinct from destroying a
transaction record, which never happens — the chain only ever grows longer.
_Avoid_: bare "delete", drop, remove, purge
_See_: [ADR-0025](docs/adr/0025-ops-and-rows-are-typed-values-ordered-by-key-and-apply-re-validates.md)
