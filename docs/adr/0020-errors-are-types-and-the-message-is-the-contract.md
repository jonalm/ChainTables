---
status: accepted
---

# Errors are types, and the message is the contract

Every failure S3SQLite raises is a concrete type under one abstract supertype,
`S3SQLite.S3SQLiteError <: Exception`, and every type's **message** is held to a
three-part contract: what happened, the evidence, and the next move — naming the
function to call, where there is one.

| error | raised by | the user's next move |
|---|---|---|
| `StaleHeadError` | commit | sync, recompute the row set, build again |
| `LostRaceError` | commit | the same — another client took the slot |
| `WriteBuilderError` | the write builder | fix the call |
| `PinnedCopyError` | sync, commit | `unpin!`, or use a live copy |
| `FingerprintMismatchError` | apply, commit pre-check | `repair!(copy)` |
| `DivergenceError` | repair | this machine cannot reproduce the chain |
| `UnsupportedStoreError` | commit | use AWS, or set `assume_first_writer_wins` |
| `ForeignLibraryError` | commit | use `SQLite_jll`, or set `assume_sqlite_is_equivalent` |
| `RewrittenChainError` | fetch of an applied slot | stop; the bucket was written from outside the protocol |
| `ChainNotFoundError` | sync | wrong bucket or prefix, **or** a truncated chain |
| `NotALocalCopyError` | open | this file is not ours |
| `LayoutVersionError` | open | a newer client wrote it; rebuild, or upgrade |
| `WrongChainError` | open | this copy belongs to another chain |
| `LocalCopyInconsistentError` | open | the head and the applied log disagree |

ADR-0008 and ADR-0014 both closed by saying each failure must be
*distinguishable* and that the names were issue #16's. This is that list.

## Why types at all, when the message is the target

The project's standing rule is that a message which explains the problem to a
user is a better test target than an exception type. That rule decides what goes
*in* the message; it does not decide how many types there are. The types here are
not documentation — they are the axis a caller branches on, and the table's last
column is what distinguishes them. A single type carrying `kind::Symbol` was
rejected for that reason: it makes the branch a value comparison that no method
table checks, and it makes a typo in a `kind` silently match nothing.

The four `open`-time failures are kept apart rather than folded into one
`LocalCopyError`, even though their messages would already distinguish them:
`LayoutVersionError` is recovered by rebuilding, `WrongChainError` means the
wrong file was opened, and those are different actions.

**There is no `isrecoverable` predicate.** Nothing in this design retries
automatically — ADR-0002 raises on a lost race and never re-runs a builder — so
the type is the whole signal, and a predicate would only invite a retry loop
around the one thing that must not have one.

## The message contract

Three parts, in order:

1. **What happened**, in the glossary's words — *state fingerprint mismatch*,
   *rewritten chain*, *divergence*.
2. **The evidence**, as both message text and fields on the exception: chain id,
   slot, expected against computed, and for a fingerprint mismatch the record's
   `sqlite_version` and `build_profile` against this machine's — ADR-0007's
   named forensics, which are useless if only the type carries them.
3. **The next move**, naming the function: `repair!(copy)`, `unpin!(copy)`,
   `sync!(copy)`, or the field to set.

Two messages are deliberately uncertain and must stay that way.
`ChainNotFoundError` cannot tell a wrong prefix from a truncated chain — ADR-0006
left "empty chain" and "missing prefix" indistinguishable on purpose — so it
names both and claims neither. `DivergenceError` reports that this machine cannot
reproduce the chain; it does not guess which side is right.

Every error type carries a `@test_throws "…"` test against its message text, not
only against its type. A message is only a contract if something fails when it
rots.

## `verify` raises rather than returning a `Bool`

`verify(copy)` returns `nothing` on success and raises
`FingerprintMismatchError` otherwise. A `Bool` return is ignorable, and an
ignored verification is exactly the silent divergence the whole design exists to
prevent. `verify(copy; full = true)` puts the bisected first bad slot in the
exception's fields and in its message, rather than returning it, for the same
reason.

`repair!` is the one function that returns a report —
`(; rebuilt_to_slot, indexes_recreated)` — because it succeeded at something the
user asked for and the counts are what they will want to see. It raises
`DivergenceError` when the fresh replay reproduces the mismatch.

## Considered options

- **One type with a `kind::Symbol`.** Rejected above.
- **Grouping by action** — five types, one per "what you must do now". Rejected:
  the actions are not stable (a future `repair!` variant would move a condition
  between groups, changing a type), and two conditions sharing an action still
  differ in what the user must go and look at.
- **Reusing `ArgumentError` and friends** for builder rejections. Rejected: a
  builder rejection is the error a user meets most often, and it is where the
  most specific message in the package lives.

## Consequences

- **Adding a condition adds a type**, which is additive and breaks no caller. A
  condition removed is a breaking change, correctly.
- **The taxonomy is testable as a whole**: every type in the table has a test
  that provokes it, which is also the list of failures the build effort owes.
- **Messages are part of the public surface.** Rewording one is a documented
  change, not a cosmetic edit.
