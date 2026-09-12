---
status: accepted
---

# A transaction record is one CBOR map, hashed as stored bytes

A transaction record is a single deterministic-CBOR map, encoded under the core
deterministic requirements of RFC 8949 §4.2.1 with the profile below. Every byte
of the object is inside the hash: `transaction_hash = SHA-256("chaintables/v1/txn" ‖
the object's bytes exactly as stored)`. There is no unhashed region and no nested
payload blob.

```
{
  "format_version":    1,                 ; uint
  "chain_id":          h'<16>',           ; minted at slot 0, identical in every record
  "slot":              0,                 ; uint
  "prev_hash":         h'<32>',           ; ABSENT at slot 0, per ADR-0002
  "state_fingerprint": h'<32>',           ; content after this record is applied
  "client": { "host": tstr?, "user": tstr?, "lib": tstr, "julia": tstr, "time_ms": int },
  "comment":           "…",               ; optional free text, no semantics
  "ops":               [ … ]              ; at least one op, per issue #9; op encoding in ADR-0025
}
```

Text keys, named from `CONTEXT.md`. Keys are sorted by the encoder per §4.2.1, so
the order above is expository only. The field is `slot`, not `seq` — **this
supersedes ADR-0002's spelling** of the envelope field; the rest of that ADR,
including the 12-digit key, stands.

## The argument for hashing stored bytes

Issue #4 recommended deterministic CBOR on the grounds that "the bytes are the
identity, so a library upgrade that changed encoding would silently fork every
chain". That reason is wrong, and getting it right changes what is fragile.

Two properties were conflated. **Fidelity** — a reader recovers the values the
writer put in — is what replay determinism needs, and it is what disqualifies
JSON: an `int64` above 2⁵³ loses precision, `int64 1` and `float64 1.0` collapse
into one, `bytes` needs an out-of-band base64 convention, `-0.0` becomes `0`, and
±Inf has no spelling. **Byte-identity** is a separate property, and it is load-bearing
only where a hash is taken over a *re-encoding* of decoded values.

Hashing the stored bytes means no client ever reproduces another's bytes: fetch
the parent object, hash the bytes received, compare to `prev_hash`. Cache
verification is rehash-the-file. ADR-0002's idempotent-commit check compares
against the bytes still in hand. A record is therefore verifiable forever,
whatever encoder wrote it.

Canonicality is still mandatory, but the obligation lives elsewhere.
`state_fingerprint` has no stored bytes — every client computes it independently
from its own local copy — so it is by definition a hash over a re-encoding of
logical content, and its encoder must be specified, vendored and frozen for the
life of the format. Once that encoder exists, using a different format on the
wire means writing and freezing a second one: two specifications, two conformance
corpora, two fork vectors, to buy nothing. So the wire format question collapses
into the fingerprint's, and there the canonicality criterion is fully live —
§4.2.1 is the only candidate with normative MUSTs, spec-supplied vectors, and
third-party implementations (`cbor2`, `fxamacker/cbor`) to differential-test
against.

The practical difference this makes: changing the *wire* encoding is a
`format_version` bump, while changing the *fingerprint* encoding is a chain break.

## The CBOR profile

Pinning what §4.2.2 leaves open, per issue #4:

- `float64` always uses preferred float representation (§4.2.2 Rule 2), never
  reduced to an integer. Decoders widen to `Float64`. **Do not adopt dCBOR** —
  its mandatory numeric reduction collapses `float64 2.0` into `int64 2`.
- `NaN` is encoded as `f97e00`, the builder having canonicalised every NaN to
  that pattern; sign bit and payload are not preserved (*amended by ADR-0025*,
  which first had it refused). `-0.0` preserved; ±Inf permitted.
- TEXT is well-formed UTF-8 with **no Unicode normalization**, so NFC and NFD
  spellings are different values. Normalizing would make the hash depend on an
  ICU version.
- No tags. Definite-length maps and arrays. Duplicate map keys rejected (§5.6
  requires the protocol to say).
- A **rejecting** decoder — canonicality is unenforceable without one — with no
  generic-object fallback, which is the path that makes `CBOR.jl` dangerous.
- Name §4.2.1 by section, never "canonical CBOR": §4.2.3 documents an alternative
  RFC 7049 length-first ordering that sorts the same keys differently.

## Considered options

- **Hash over re-encoded values, wire format free** (so identity survives a wire
  format change). Rejected: it makes the frozen encoder permanently load-bearing
  for records too, forbids verification without a full decode, and creates a new
  failure mode where two clients that parse the same bytes differently disagree
  about *chain structure* rather than content — a much worse failure than a
  content divergence, which the fingerprint catches one record later.
- **A sealed core plus an unhashed `attestation` region**, so a future
  server-mediated write path could annotate a client's record without moving the
  chain hash. Rejected in favour of the simpler shape: a server changes who
  *authors* a record, not who annotates one. The client sends ops, the server
  builds and hashes the record, the client receives what was committed.
- **MessagePack, BSON, Avro.** All three carry the four value types exactly, and
  once byte-identity stopped being required of the wire they became admissible on
  fidelity. Avro is the interesting one — positional fields mean the key-ordering
  question does not arise. All rejected by the one-encoder argument above.
- **A database file as the record** (a SQLite file, when the local copy was
  one). Exact fidelity by construction, and it dragged issue #3's entire
  version-hazard list into the record format; with no engine on the replay path
  (ADR-0022) there is no such file to consider.
- **`ops` wrapped in a nested CBOR byte string** with a separate `payload_hash`,
  as issue #4 proposed. Rejected: with the whole object hashed, the remaining
  gain is refusing a large record without decoding it, and records are capped at
  64 MiB. A wrapped form can arrive as `format_version` 2 if compaction wants it.
- **A `fingerprint_alg` field.** Rejected: `format_version` is the single
  negotiation point. Two version numbers can disagree, and then a client must
  decide which one wins.
- **Integer keys** instead of text. Rejected: a record holds a whole row set, so
  key bytes are noise, and text keys make a record readable with any CBOR tool.

## Consequences

- **A record never carries its own `transaction_hash`** — a field cannot hold the
  hash of the bytes it sits in. A record's hash is always computed from its
  bytes, so a client **keeps the original bytes it fetched and never re-encodes a
  record**. This is load-bearing, not an optimisation.
- **The transaction level is removed.** Issue #7 kept a transaction inside a
  record as a unit of intent and a carrier for future metadata. Under the strict
  decoder below, adding a field inside a transaction map is exactly as much of a
  format break as adding one at the top, so the reserved level bought nothing;
  with the free-text label moved to the record it carried nothing either. The
  record is the atom, and now also the only grouping. `CONTEXT.md` loses the term
  **Transaction**.
- **Unknown is fatal, in both directions.** A `format_version` above the client's
  maximum is a hard error, and so is an unknown field name — symmetric with issue
  #9's unknown op tag. A client never reads part of a record. The cost is
  explicit: every format addition is a `format_version` bump requiring every
  client to update.
- **The server era is `format_version` 2.** No `server` field is reserved in v1,
  because a v1 client could do nothing with a server assertion it cannot check.
  The map's forward-compatibility constraint is met by intent recorded here, not
  by a mechanism.
- **`client.lib` and `client.julia` are advisory** and gate nothing. Their
  job is forensic: when a fingerprint mismatch fires, the record names the
  suspect — the package name and version, and the Julia version. *Amended by
  ADR-0022*: this slot originally held `sqlite_version` and `build_profile`,
  which left the envelope when SQLite left the replay path; no chain had been
  written, so `format_version` stays 1.
- **`comment` is free text with no semantics**, hashed like everything else,
  validated only as well-formed UTF-8 without U+0000. It is the one cheap piece
  of observability available on day one, and under the strict decoder it could
  not be added later without a version bump.
- **64 MiB cap, enforced at build time**, failing with the byte count. The
  binding constraint is not S3's 5 GiB single-PUT limit but ADR-0003's whole-table
  rewrite, which materialises every row of a table in one record, in memory, on
  every client. No compression in v1 — worth noting that compression would be
  safe even from a non-deterministic compressor, since the hash covers the
  compressed bytes and only decompression need be deterministic.
- **`chain_id` is minted at slot 0 and repeated in every record.** It costs 16
  bytes and detects a record copied or relocated between chains. "Empty chain"
  and "missing prefix" remain indistinguishable — S3 answers 404 to both — and
  the distinction is discarded rather than engineered: a mistyped prefix is an
  empty chain you write into, and `chain_id` convicts those records the moment
  they meet the real chain.
- **`client.time_ms` is int64 milliseconds since the Unix epoch, UTC**, not RFC
  3339 text: no formatting ambiguity, no float, no timezone spelling. `host` and
  `user` are individually suppressible by configuration, because they write
  identity into a permanently immutable object; the `client` map is always
  present.
- **Required named test: `-0.0`.** The float-shortening path needs an explicit
  sign-bit check or `-0.0` silently encodes as `+0.0` — two lines, with
  chain-forking consequences. It is a named test, not prose. The frozen
  conformance corpus is differential-tested against `cbor2` (`canonical=True`)
  and `fxamacker/cbor` (`CoreDetEncOptions()`).
- **Human inspectability regresses versus JSON** until an `inspect` tool exists,
  rendering RFC 8949 §8 diagnostic notation. That belongs to the observability
  work the map still holds.
