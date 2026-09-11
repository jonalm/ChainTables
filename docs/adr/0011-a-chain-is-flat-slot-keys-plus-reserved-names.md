---
status: accepted
---

# A chain is flat slot keys plus reserved names, and its identity is a chain id

Under a chain prefix, a key is a **slot key** if and only if the remainder after
the prefix is exactly twelve decimal digits — `<prefix>/000000000123`, flat, no
intermediate directories. **Every other name under the prefix is reserved**, and a
v1 client ignores it rather than erroring on it. A chain's identity is a `chain_id`
minted once at chain creation; the bucket and prefix are only where it currently
lives.

## Compaction owes the record format nothing

The map carried "past periods get merged into batch objects" as a forward-compat
constraint every format decision had to satisfy. It is struck. The replacement,
raised during issue #9, is to cache a materialized local copy in the bucket and
verify it against the `state_fingerprint` of the record it was taken at — and
because that is *derived data*, it constrains the record format not at all. There
is no merge semantics to design (ADR-0003's whole-table rewrite, `drop_table` +
`create_table` + `insert`, is exactly the case op-merging handles worst), and
retention survives untouched because nothing is ever replaced.

It is not designed here either. The record count at which cold start stops being
acceptable is unmeasured — the map has it parked, and issue #15 warned the number
may have fallen now that cold start is many ordinary GETs rather than rclone's
bulk transfer. Designing a cache for a cost nobody has measured is the wrong order.

What v1 owes the future is therefore one rule, not a mechanism: **an unrecognized
name under the chain prefix is ignored.** Stating it now costs a sentence; leaving
it unstated makes the first derived object a format break, because a client with no
stated behaviour on an unknown key is a client that may reasonably have chosen to
fail on one.

## Considered options

**Hierarchical slot keys** (`<prefix>/000000/000123`) were considered for the
record cache's directory fanout — realistic commit rates put on the order of 10⁵
files in one directory. Rejected: the cache mirrors keys to paths by a mapping that
is ours, local and disposable, so it can split on its own if a filesystem ever
complains. A local concern must not shape the bucket layout, which is permanent.
The other pull was giving a compactor a range unit, and 10⁶ records is far too
coarse to be one.

**A sibling prefix for derived objects**, outside the chain prefix, would honour
ADR-0002's "no unconditional PUT or delete against a chain prefix" literally. It
scatters one chain across two locations and doubles the bucket policy a caller must
grant. ADR-0012 removes the mutability that rule was actually guarding against, so
reserved names inside the prefix are safe, and a chain stays one addressable place.

**`chain_id` as the prefix string itself** was the cheaper option and is wrong for
the same reason ADR-0008 gave for the local copy: bucket and prefix are location,
not identity. A chain that is copied elsewhere is still the same chain, and a
record dropped into a foreign chain at a matching slot must still be convicted.

**Chain discovery under a bucket** — enumerating the chains a bucket holds — is out
of scope for v1. The caller supplies bucket and prefix. It needs delimiter listing,
which ADR-0010 deliberately left out of the port, and nothing in v1 wants it.

## Consequences

- **`_` sorts after the digits** (`0x5F` against `0x30`–`0x39`), so a lexicographic
  listing of a chain prefix yields every slot key first and every reserved name
  after, never interleaved. Reserved names should be given a leading underscore for
  that reason — `<prefix>/_snapshots/…` if a cached local copy ever ships.
- **Twelve digits is the whole address**, so a key with eleven or thirteen is not a
  malformed slot — it is a reserved name, and it is ignored. There is no "invalid
  slot key" error, by construction.
- **LazyFiles' old filename rules are kept by choice**, not inherited: no `:`, no
  Windows reserved device names, no trailing dot or space in any segment. The record
  cache still mirrors keys to filesystem paths, so the reason survives its author.
  Twelve-digit slots satisfy them trivially; an ISO-8601 timestamp in a key would
  not, so a future compactor must encode periods some other way.
- **`chain_id` is 128 random bits, rendered base32** — 26 characters, no separators,
  no case sensitivity to lose in a filesystem or a URL. It is minted at chain
  creation, fixed in slot 0, and carried in every record thereafter (ADR-0006).
