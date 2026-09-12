# ChainTables

Several independent Julia clients agree on the content of a set of tables
without a server. The agreed content is an append-only, hash-chained sequence of
immutable *transaction records* under one key prefix in an S3 bucket. Each
client keeps a *local copy*, a directory it builds by replaying that sequence,
and reads it through *table views*. A commit is one conditional PUT to the next
slot: the first writer wins, and a lost race raises rather than retries.

It fits read-heavy data with infrequent writes, low concurrent-write
probability, and a total size that fits on every client.

**Status: the v1 design is locked (tag `spec-v1`) and not yet implemented.**
The contract is [`CONTEXT.md`](CONTEXT.md), the glossary, and
[`docs/adr/`](docs/adr/), the decisions. The build effort is tracked in the
epic linked from the map, issue #1. Nothing below runs yet.

## The worked example

This narrative is the spec's front door and the build's first acceptance test:
the test suite runs the same sequence against
`ChainTables.Testing.InMemoryObjectStore`, and drift between the two is a bug.
Names marked *proposed* in the epic's surface inventory may still change before
docstrings freeze; the sequence of events will not.

```julia
import ChainTables
using Tables

# A chain is location and configuration. Constructing it performs no I/O;
# credentials resolve now and error if absent (ADR-0019, ADR-0010).
chain = ChainTables.Chain("my-bucket", "experiments/run-7"; region = "eu-north-1")

# Only create_chain writes slot 0. It mints the chain id, commits a zero-op
# genesis record, and returns no local copy (ADR-0019).
ChainTables.create_chain(chain)          # (; chain_id, slot = 0, transaction_hash)

# open creates the directory if absent, does no network I/O, and binds the
# copy to the chain at the first sync (ADR-0023, ADR-0013).
copy = ChainTables.open(chain, "/data/run-7")
ChainTables.sync!(copy)                  # (; applied = 1, slot = 0, transaction_hash)

# A write builder is a value used once. Structural checks fail in the call
# that is wrong; the state check runs at commit (ADR-0001, ADR-0019).
w = ChainTables.write_builder(copy)
ChainTables.create_table!(w, :samples) do t
    ChainTables.column!(t, :id, Int64)
    ChainTables.column!(t, :label, String)
    ChainTables.column!(t, :mass, Float64; nullable = true)
    ChainTables.primary_key!(t, :id)
end
ChainTables.insert_rows!(w, :samples, [
    (id = 1, label = "a", mass = 1.5),
    (id = 2, label = "b", mass = missing),   # missing is null (ADR-0025)
])
ChainTables.commit!(w; comment = "first samples")
# (; slot = 1, transaction_hash, state_fingerprint)

# A second client on another machine replays the same records and reaches
# the same state fingerprint, or raises FingerprintMismatchError.
copy2 = ChainTables.open(chain, "/scratch/run-7")
ChainTables.sync!(copy2)                 # applied = 2
v = ChainTables.table(copy2, :samples)   # TableView fixed at slot 1
v[2].mass                                # missing
Tables.columns(v).label                  # ["a", "b"]

# Read, change, write: the row set is computed here, against this copy,
# and the record carries the rows found, never the condition (ADR-0005).
w2 = ChainTables.write_builder(copy2)
ChainTables.update_rows!(w2, :samples, [(id = 2, mass = 2.5)])
ChainTables.commit!(w2)                  # slot = 2
v[2].mass                                # still missing: a view never moves (ADR-0024)

# The first client is now behind. Commit does not sync; it raises.
w3 = ChainTables.write_builder(copy)
ChainTables.delete_rows!(w3, :samples, [(id = 1,)])
ChainTables.commit!(w3)                  # StaleHeadError: head is slot 1, chain is at 2; sync!(copy)
ChainTables.sync!(copy)                  # applied = 1, slot = 2
# Build again from the fresh state; w3 is spent and is never re-run (ADR-0002).

# History is addressed by slot or transaction hash, never by time (ADR-0015).
old = ChainTables.as_of(chain, 1)        # a pinned temporary copy at slot 1
ChainTables.table(old, :samples)[2].mass # missing
close(old)

# Local integrity is checked on demand and never healed silently (ADR-0014).
ChainTables.verify(copy)                 # nothing, or FingerprintMismatchError
close(copy); close(copy2)
```

What the example does not show, and the ADRs do: the record bytes and their
hash (ADR-0006), the two-level state fingerprint (ADR-0007), the local copy's
files (ADR-0023), galloping head discovery (ADR-0012), the backend gate on
non-AWS stores (ADR-0016), and the error taxonomy (ADR-0020).
