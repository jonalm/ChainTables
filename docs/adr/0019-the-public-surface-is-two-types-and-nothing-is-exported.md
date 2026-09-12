---
status: accepted
---

# The public surface is two types, qualified, and nothing is exported

S3SQLite exports no names. Everything is reached as `S3SQLite.sync!(copy)`,
`S3SQLite.commit!(w)`, `S3SQLite.as_of(chain, 40)` — the precedent is SQLite.jl,
which exports only `DBInterface`, `SQLiteException` and `@sr_str`. The names this
package wants most are `open`, `close`, `commit!` and `verify`, three of which
collide with `Base` and all of which are too common to own. `Base.close` is
extended, because the local copy is a handle; `Base.open` is not, because
`S3SQLite.open` reads as documentation at every call site.

## Two types

- **`Chain`** — bucket, prefix, credentials, region, object store, read-ahead
  window, record cache directory, and the assumed guarantees. It is location and
  configuration; constructing it performs no I/O.
- **`LocalCopy`** — one open local copy, bound to a chain.

Two rather than one, because ADR-0015 fixed `as_of(chain, target)`: a
point-in-time rebuild is addressed without any local copy open, so the chain must
be a value in its own right. A side table keyed on the handle — the third option
— was rejected outright as invisible state.

**Amended by ADR-0024**: `LocalCopy` forwards nothing and holds no database.
Reads go through **table views** — `table(copy, :t)` returns a `TableView`, a
Tables.jl table fixed at the head it was taken at, which is the third type with
behaviour. This paragraph first forwarded `DBInterface.execute` and handed out
the plain `SQLite.DB` under `PRAGMA query_only`; both left with SQLite
(ADR-0022).

Two more types exist for values, not for behaviour: **`TransactionHash`** and
**`StateFingerprint`**, each 32 bytes, shown as hex. They are the two things the
glossary works hardest to keep apart and they are structurally identical, so
untyped they are interchangeable at the call site and fail much later, as a
mismatch. `chain_id` stays a `String`: it is a name, it is read by humans in
error messages, and nothing else in the API is base32 text.

## Chain creation is explicit, and it produces no local copy

`S3SQLite.create_chain(chain)` is the only thing that may write slot 0. It mints
the `chain_id`, commits a genesis record carrying **zero ops**, and returns
`(; chain_id, slot, transaction_hash)` — **not** a local copy.

Implicit genesis at the first commit was rejected on one measured fact: ADR-0006
leaves "empty chain" and "missing prefix" deliberately indistinguishable, so a
typo in the prefix would not fail — it would mint a second chain in silence. For
the same reason `sync!` on a copy with no head, against a prefix with no slot 0,
is an error naming both possibilities, rather than ADR-0013's ordinary
`applied = 0`. Once a copy has a head, `applied = 0` stays non-erroring.

Returning no local copy keeps one rule with no exception: **every local copy is
built by replay**. The user opens and syncs like anyone else. A zero-op record is
therefore legal at slot 0 and nowhere else — an empty commit elsewhere is a
caller mistake, and is rejected.

## The write builder is a single-use value

```julia
w = S3SQLite.write_builder(copy)
S3SQLite.insert_rows!(w, :customers, rows)
S3SQLite.commit!(w; comment = "…")   # → (; slot, transaction_hash, state_fingerprint)
```

A do-block form — `commit!(copy) do w … end` — was rejected. Issue #8 fixed that
a builder is a value and not a re-runnable closure, and that a lost race raises
and is never retried; a block invites exactly the reading that the library may
run it again. A second `commit!` on the same builder is an error, since that is
the forbidden retry written by hand.

Checks split by kind. Structural ones run **eagerly, in the call that is wrong** —
unknown table or column, a type tag outside the four, non-uniform columns within
an op, a reserved table name, a duplicate key inside an op — so the stack trace
points at the user's own line. ADR-0001's data gate, *an op matching a row count
other than the one it names is an error*, runs at `commit!` inside the
transaction, where real state is what it is checked against.

The four type tags are `Int64`, `Float64`, `String` and `Vector{UInt8}`, one per
storage class. `Int`, `Bool`, `DateTime` and `AbstractString` are refused by
name. This is the one place the project's "do not over-restrict argument types"
rule is deliberately inverted: a tag mapping to two storage classes, or to none,
is the divergence the design exists to prevent. Row sets are any Tables.jl row
table, because that is what a query over the local copy returns.

## No read-only mode

ADR-0016 declined to gate at `open` partly so as not to force a read-only mode
into existence, and handed the decision here. There is none. A local copy is
already read-only until a commit is attempted, and ADR-0015's pinned copy is the
one permanent form. A flag meaning "I promise not to commit" buys nothing that
the commit-time gate does not already give, and would need its own error.

## The object-store port is public, and so is the double

ADR-0010's four verbs are documented public API — `fetch_object`,
`put_object_if_absent`, `stat_object`, `list_objects`, one request each, no
delete — with the contract stated in their docstrings: **absent is `nothing`,
failure raises**. That is the distinction a store which conflates them breaks
silently, and the one ADR-0010 requires of the double.
`put_object_if_absent` returns `false` only for a genuine `412`; ADR-0016's `409`
is retried inside the commit layer and never surfaces. Listing order is not
promised, because ADR-0012 left nothing in the protocol reading it.

`S3SQLite.Testing.InMemoryObjectStore` ships in the package rather than living in
`test/`. A user testing their own S3SQLite-backed code needs a store that never
reaches AWS, and rebuilding the faithful one — refuse a put to an existing key,
keep absent and failed distinct, shuffle listings, tie whole-second `modified`
values — is precisely what they would get wrong. It also stops our own double
from drifting away from the documented port. The submodule holds that store and
nothing else: any fixture helper added there becomes a second API to keep stable.

## Considered options

- **One type carrying chain and copy together.** Rejected: ADR-0015's `as_of`
  has no local copy to carry.
- **A `do`-block commit.** Rejected above, on the re-run reading.
- **Implicit genesis.** Rejected above, on the typo'd prefix.
- **A `readonly = true` open mode.** Rejected above.
- **Exporting the common verbs.** Rejected: `commit!`, `verify` and `open` in a
  user's namespace is a collision waiting for a second package.
- **The double in `test/` only.** Rejected: users testing their own code need it,
  and a private double drifts from the public port.

## Consequences

- **Every call is qualified.** This is verbose by design, and it is what lets the
  package own short, ordinary verbs without owning them in anyone's namespace.
- **A builder held across a `sync!` fails.** ADR-0002's stale-head check catches
  it at `commit!`, which is the right place: the row set was computed against a
  state that has moved.
- **`open` requires a path**; only `as_of` may take `path = nothing` for a
  temporary file deleted on close. A live copy you cannot find again is a
  footgun, and a throwaway live copy is `as_of` at the head.
- **`open` creates the file when it is absent**, initialized-but-empty —
  ADR-0008 already names that a legitimate state, and binding happens at the
  first `sync!`.
- **The two open-time warnings** (ADR-0016's non-AWS store, ADR-0018's foreign
  `libsqlite3`) are `@warn` with `maxlog = 1` per process per condition, and
  `as_of` warns through the same path. The refusal at `commit!` never has
  `maxlog`: a suppressed warning must not become a suppressed refusal.
- **Credentials resolve at `Chain` construction and error if absent**, and the
  field also accepts a callable, because ADR-0010's signer sends
  `x-amz-security-token` and a long-lived reader outlives an aws-vault session.
  Region is required: SigV4 signs it, and guessing produces a signature error
  instead of a useful message.
- **The record cache defaults to `first(DEPOT_PATH)/s3sqlite/records`**,
  overridable per chain and by `S3SQLITE_CACHE_DIR`. Depot-based is machine-wide
  in ADR-0008's sense and needs no dependency, which `Scratch.jl` would have been.
- **v1 documents one process and one thread per local copy** without implementing
  locking. SQLite's own locking makes a second process block rather than corrupt,
  and ADR-0008's re-read of the head inside the transaction hard-errors if it
  moved. The locking policy itself stays open.
