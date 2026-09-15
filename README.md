*STATUS* this package is under development - which means that even architectural
decisions are subject to changes. There are no data that stored with this
package, beyond testing data, and none of it needs backwards compatability for now.

# ChainTables

Several independent Julia clients agree on the content of a set of tables
without a server. The agreed content is an append-only, hash-chained sequence of
immutable *transaction records* under one key prefix in an S3 bucket. Each
client keeps a *local copy*, a directory it builds by replaying that sequence,
and reads it through *table views*. A commit is one conditional PUT to the next
slot: the first writer wins, and a lost race raises rather than retries.

It fits read-heavy data with infrequent writes, low concurrent-write
probability, and a total size that fits on every client.

**Status: v1 is built.** The docstrings are the reference: every public name
is qualified (`ChainTables.commit!`, nothing is exported) and documented, so
`?ChainTables.commit!` at the REPL is the surface. The design behind them is
[`CONTEXT.md`](CONTEXT.md), the glossary, and [`docs/adr/`](docs/adr/), the
decisions; the design map is issue #1 and the build map is issue #34.

## The worked example

This narrative is the front door and an acceptance test: `test/readme.jl` runs
the same sequence against `ChainTables.Testing.InMemoryObjectStore`, asserting
every commented value, and drift between the two is a bug.

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

## Gateway buckets

On a plain bucket every writer holds `PutObject`, and a record's author is
whatever the client wrote. A **gateway bucket** ([ADR-0028](docs/adr/0028-a-gateway-bucket-verifies-the-author-and-nothing-else.md))
has one writer, a Lambda function behind a function URL, that fills a slot only
after checking that the caller may write under the chain's prefix and that the
record's author *is* the caller. Reads stay direct. The chain is the same; the
store is chosen by one keyword, and the credentials are an `aws sso login`
session handed over as a callable:

```julia
credentials = ChainTables.sso_credentials("my-profile")   # after: aws sso login --profile my-profile
chain = ChainTables.Chain("my-gateway-bucket", "experiments/run-7";
                          gateway = "https://<id>.lambda-url.eu-north-1.on.aws",
                          region = "eu-north-1", credentials)
```

Everything else in the worked example is unchanged, except that a refused
write raises `WriteRefusedError` naming its reason, and a record is capped at
4 MiB. Deploying the gateway, the IAM contract a writer or reader must satisfy,
the policy config, how the author name is derived and how a writer is
onboarded are in [`docs/gateway-setup.md`](docs/gateway-setup.md); the code is
under [`gateway/`](gateway/README.md).
