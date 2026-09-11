# PROTOTYPE — write-builder API surface (issue #7)

Throwaway. No S3, no hashing, no persistence. Local state is an in-memory
`SQLite.DB`, because the one thing a builder does that cannot be faked is fail
against real local state.

```
julia --project prototype/write-builder/run.jl     # or: include("run.jl"); report()
```

`OUTPUT.txt` is that run, captured.

## What is here

| file | what it is |
| --- | --- |
| `ops.jl` | the op model + the determinism guard + render/apply. The part worth keeping. |
| `shape_a.jl` | **A** — plain functions over `NamedTuple`s |
| `shape_b.jl` | **B** — do-blocks |
| `shape_c.jl` | **C** — a macro DSL |
| `run.jl` | builds the same two records all three ways, proves they agree, then breaks things |

Two records, in all three shapes: create two tables, load three samples and five
measurements (with `NULL`s and a `BLOB`), then add a column, and delete + update
a row set **the caller found by querying local state first**.

## The same op, three ways

```julia
# A
create_table!(tx, :sample, [
        (name = :id, type = :INTEGER, notnull = true),
        (name = :label, type = :TEXT, notnull = true),
        (name = :note, type = :TEXT),
    ]; primary_key = :id)

# B
create_table!(tx, :sample) do t
    column!(t, :id, :INTEGER; notnull = true)
    column!(t, :label, :TEXT; notnull = true)
    column!(t, :note, :TEXT)
    primary_key!(t, :id)
end

# C
@create_table sample begin
    @required id::INTEGER
    @required label::TEXT
    note::TEXT
    @primary_key id
end
```

All three produce byte-identical op data (`run.jl` §1 asserts it), so the choice
is purely about how the source reads.

## Findings

1. **"Make a non-deterministic write unrepresentable" is not achievable at
   authoring time.** `rand()` returns a perfectly canonical `Float64`, so no
   value-level guard can see it. The macro can — lexically — and is defeated by
   `noise() = rand()`, one function call away. It *has* to be defeated, because
   real callers splice in row sets computed by arbitrary Julia from a query.
   What the builder actually guarantees is that **replay** is deterministic: the
   record holds nothing but literals, so every client writes the same bytes.
   Re-running the author's code and getting the same record is a different
   property, and v1 does not have it.

2. **The guard that does earn its keep is structural**, not moral: storage class,
   identifier shape, explicit `PRIMARY KEY`, uniform column order per op, literal
   defaults only, and applying the record locally before it is allowed to exist.

3. **Every table needs an explicit `PRIMARY KEY`** — a real user-facing
   constraint falling out of #3 (implicit `rowid` is not replayable) and of
   materialized ops (a `DELETE` has nothing to name a row by). Tables are
   emitted `STRICT, WITHOUT ROWID`.

4. **Identifiers are never quoted**, so they must be safe bare — `SQLITE_DQS=3`
   is compiled in and invisible (#18), and a quoted identifier that fails to
   resolve silently becomes a string literal.

5. **A `DELETE`/`UPDATE` matching ≠ 1 row is an error, not a no-op.** The caller
   materialized a row set this database does not have.

## Verdict (2026-09-11, settled with the dev)

- **Shape C is rejected.** `shape_c.jl` stays here as the evidence for why.
- **Shape A is the builder**, with a do-block for `create_table!` only.
- **Transactions stay.** A record is the atom, but a transaction is a unit of
  intent and a future carrier for metadata.
- **`missing` is accepted as NULL.** The fail-fast rule does not ask for a
  refusal here: `missing` is what SQLite.jl returns for a NULL column, so
  refusing it breaks the read-change-write round trip for no gain, and the
  accidental-NULL case it admits is caught by `NOT NULL` in the schema, which
  fails locally before a commit.
- **`Inf` stays excluded** with `NaN`, deliberately. Measurement says `±Inf`
  round-trips through SQLite exactly and has one CBOR encoding, so the ban is
  not forced — but it is cheaper to explain one rule than two, and nothing needs
  it yet. See the resolution comment on #7 for the numbers.

Written up as ADR-0001 on `main`.

## Still open (for #9 / #10)

- **Column order is part of the canonical bytes.** Should the encoder sort
  column names so that the same logical write always hashes the same, or is
  caller order part of the record?
- Float `DEFAULT` literals are rendered with Julia's shortest round-trip `repr`
  and parsed back by SQLite — the one place a value is not a bound parameter,
  and SQLite's text-to-real parser is not documented as correctly rounded.
