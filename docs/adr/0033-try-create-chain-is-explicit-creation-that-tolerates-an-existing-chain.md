---
status: accepted
---

# `try_create_chain` is explicit creation that tolerates an existing chain

`ChainTables.try_create_chain(chain)` runs `create_chain(chain)` and returns what
it returns, or `nothing` when slot 0 is already taken. It swallows the
`LostRaceError` that `create_chain` raises at slot 0 and nothing else: an
unsupported store, a refused or mismatched gateway write, a record over the cap
and a transport failure all propagate unchanged. Issue #67.

## Why this does not reopen ADR-0019's implicit genesis

ADR-0019 rejected implicit genesis **at the first commit**: a creation hidden
inside another verb, so a typo'd prefix would mint a second chain in silence.
`try_create_chain` keeps creation a verb of its own, named at the call site. What
it adds is tolerance of the other outcome: "a chain is already there" is not an
error for this caller.

The typo hazard is not removed. A typo'd prefix still mints a chain, and this
function says nothing about it. That is accepted, because the caller chose this
function over `create_chain`, and `create_chain` stays the strict form. The use
is setup that runs more than once: a deployment script, a notebook cell, a test
fixture. Each of these would otherwise write the same `try`/`catch` by hand, and
the hand-written one is easy to get wrong. The first version of this function
returned `true` from its `catch`, and a broad `catch` would swallow a refused
write as well.

## What `nothing` does not say

`nothing` does not say whose chain is there, or whether its genesis is
well-formed. A slot 0 that does not decode is still a `LostRaceError` from
`create_chain`, and so `try_create_chain` returns `nothing` for it as well. The
first `sync!` from that prefix raises `MalformedRecordError`, so the fault is
reported, but one call later. A caller who needs the chain id calls
`create_chain` and reads it from the `LostRaceError`.

## Considered options

- **Remove it.** This was the issue's first option. Rejected: the hand-written
  equivalent is what every repeatable setup needs, and leaving it to users is how
  the `true` return happened.
- **Return the existing chain's id instead of `nothing`.** Rejected: it would
  make the two outcomes look the same at the call site. Also, a malformed
  genesis has no id to return.

## Consequences

- **ADR-0019 is amended**: chain creation is explicit, and there are two
  explicit forms, the strict one and the tolerant one. Only `create_chain`
  writes slot 0, and `try_create_chain` writes it only through `create_chain`.
- The return type is `Union{Nothing, NamedTuple}`, and `nothing` means only "slot
  0 was taken". It does not mean "it worked".
