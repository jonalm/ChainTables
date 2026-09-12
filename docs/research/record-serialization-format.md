# Canonical serialization format for transaction records

> **Historical.** Written when the package was S3SQLite and a local copy was a
> SQLite file, so value fidelity is argued against SQLite's storage classes.
> The recommendation stands (ADR-0006); the value domain it must carry is now
> ADR-0025's four value types, and NaN is admitted and canonicalised rather
> than refused ([ADR-0022](../adr/0022-content-lives-in-a-julia-model-and-determinism-rests-on-the-encoder.md)).

Research for [issue #4](https://github.com/jonalm/ChainTables/issues/4), part of the
[v1 design spec map (#1)](https://github.com/jonalm/ChainTables/issues/1).
Sources verified 2026-09-10.

---

## Recommendation

**Use CBOR restricted to the core deterministic encoding requirements of
[RFC 8949 §4.2.1](https://www.rfc-editor.org/rfc/rfc8949#section-4.2), with an
S3SQLite profile that pins the choices RFC 8949 deliberately leaves open, and
implement it as a small encoder/decoder vendored into this repository rather than
by depending on `CBOR.jl`.** Use the same format for the envelope and the ops
payload; carry the payload as a nested CBOR byte string (major type 2) rather
than switching formats.

CBOR is the only candidate whose deterministic encoding is *specified* rather than
merely achievable: RFC 8949 is an Internet Standard (STD 94), §4.2.1 is three
normative MUSTs, and it ships worked byte vectors that an implementation can be
tested against — MessagePack's spec contains the word "canonical" zero times and
relegates determinism to a "Future discussion / Profile" section, Arrow and
Parquet contain no normative determinism statement at all (Parquet's spec
actively *recommends* embedding the writer's build hash), and JSON's only
published canonicalization profile, RFC 8785, is an Informational Independent
Submission that requires 64-bit integers be smuggled through as strings. CBOR's
type system is also a 1:1 fit for SQLite's five storage classes with no coercion
anywhere: major types 0/1 cover the full int64 range exactly, major type 2 is
BLOB, major type 3 is TEXT, `0xf6` is NULL, and major type 7 floats cover REAL —
whereas JSON cannot even distinguish SQLite's `INTEGER 1` from `REAL 1.0`, which
`typeof()` shows are different values. The reason to own the encoder rather than
depend on a package is that for a format whose bytes are the identity, a library
upgrade that changes encoding silently forks every chain — the encoder must be
frozen, and `CBOR.jl` is in any case unusable as-is (it emits map keys in `Dict`
hash order, has no CI, and still documents itself against the obsoleted RFC 7049).
Owning ~200 lines against a published standard gets us the third-party
cross-checking that a purely home-grown format would not have: `cbor2`
(Python, `canonical=True`) and `fxamacker/cbor` (Go, `CoreDetEncOptions()`) can
independently verify our bytes.

---

## Comparison

| | canonical encoding | Julia package health | SQLite value fidelity | schema evolution | batch/compaction fit | verdict |
|---|---|---|---|---|---|---|
| **CBOR, RFC 8949 §4.2.1** | **Specified.** STD 94, three normative MUSTs, spec-supplied byte vectors | `CBOR.jl` weak (v0.2.0, no CI, no determinism) → **vendor ~200 lines** | **Exact.** int64, float64, TEXT≠BLOB, NULL all native; no coercion | Maps with unknown keys are skippable; version field in envelope | **Excellent.** Self-delimiting; RFC 8742 sequences concatenate with no reframing → member hashes survive compaction | **Recommended** |
| **JSON + JCS (RFC 8785)** | Specified but *Informational, Independent Submission*; forces int64→string, BLOB→base64, type tags out-of-band | No Julia JCS exists; `JSON.jl` v1.8.0 is excellent but its floats diverge from ECMA-262 in 4 systematic ways | **Lossy.** No int/real distinction, no binary type, no ±Inf, `-0.0`→`0` | Good (unknown keys ignorable) | Poor — needs explicit array framing; re-canonicalization risk | Rejected as wire format |
| **MessagePack** | **Not specified.** "canonical" appears 0× in spec; smallest-form is a SHOULD | `MsgPack.jl` v1.2.1 (2023), active-ish, 15 open | Weak: `Vector{UInt8}` packs as an *array of integers* by default; str/bin split has a compatibility mode | Fine | Fine | Rejected |
| **Arrow IPC** | **Not specified.** Padding contents undefined; Flatbuffers framing declared producer-dependent by design | `Arrow.jl` v2.8.1, maintenance-mode, 97 open issues | Native types fine; mixed-type rows need unions | Strong read compat (format 1.x, no major bump since 1.0.0) | Great as a *container* — but batch splitting is unconstrained | Rejected as identity; viable later as transport |
| **Parquet** | **Not specified, and not fixable.** `created_by` embeds writer version + build hash by spec recommendation | `Parquet2.jl` 0.2.35 (GitLab, bus factor 1); `Parquet.jl` self-deprecating | NULL is out-of-band (definition levels) | Fine | Natural for bulk — but bytes track codec library version | Rejected |
| **Purpose-built binary** | Whatever we specify — but we write the spec, the vectors, and the bugs, alone | n/a | Exact, by construction | Ours to design | Ours to design | Rejected — CBOR *is* this, with a standard already written |

---

## Detail

### The requirement, restated precisely

Records are SHA-256 hashed, and the map (#1) additionally commits to a
`state_fingerprint` — a canonical hash of the whole logical DB content after
applying a record — that every client recomputes and hard-errors on. So the
encoder is not a serialization convenience; **it is a consensus rule**. Two
consequences follow that reshape the usual evaluation:

1. *Achievable* canonicality is worth much less than *specified* canonicality. A
   format where determinism is a property of one library's current defaults is a
   format where a dependency bump is a chain fork.
2. Package maturity is partly inverted. We want a *frozen, small, auditable*
   encoder, not a feature-rich evolving one. Maturity matters for the *spec*, not
   the implementation.

### The value domain

SQLite's five storage classes ([sqlite.org/datatype3](https://www.sqlite.org/datatype3.html)):

> **NULL**. The value is a NULL value.
> **INTEGER**. The value is a signed integer, stored in 0, 1, 2, 3, 4, 6, or 8 bytes depending on the magnitude of the value.
> **REAL**. The value is a floating point value, stored as an 8-byte IEEE floating point number.
> **TEXT**. The value is a text string, stored using the database encoding (UTF-8, UTF-16BE or UTF-16LE).
> **BLOB**. The value is a blob of data, stored exactly as it was input.

and, in memory, INTEGER is always widened: "as soon as INTEGER values are read off
of disk and into memory for processing, they are converted to the most general
datatype (8-byte signed integer)".

Three empirical facts about the domain, probed against SQLite 3.43.2:

```
sqlite> select typeof(1), typeof(1.0);              -- integer|real   <-- distinct values
sqlite> select typeof(9e999);                       -- real  (Inf is storable)
sqlite> select typeof(9e999 - 9e999);               -- null  (NaN is NOT storable)
sqlite> select typeof(x'00ff');                     -- blob  (arbitrary bytes, incl. NUL)
```

So the target domain is: int64 (full range), float64 **minus NaN but including
±Inf and ±0.0**, arbitrary byte strings, UTF-8 text, and null — and the format
**must keep `INTEGER 1` and `REAL 1.0` distinct**, because SQLite does. That single
fact is decisive against JSON and against dCBOR (below).

### CBOR — RFC 8949

**Status.** [RFC 8949](https://www.rfc-editor.org/info/rfc8949) is an **Internet
Standard, STD 94** (2020), obsoleting RFC 7049 "while keeping full compatibility
with the interchange format".

**§4.2.1 Core Deterministic Encoding Requirements** — three normative rules
([§4.2](https://www.rfc-editor.org/rfc/rfc8949#section-4.2)):

> - Preferred serialization MUST be used. In particular, this means that arguments (see Section 3) for integers, lengths in major types 2 through 5, and tags MUST be as short as possible […] Floating-point values also MUST use the shortest form that preserves the value, e.g., 1.5 is encoded as 0xf93e00 (binary16) and 1000000.5 as 0xfa49742408 (binary32).
> - Indefinite-length items MUST NOT appear. They can be encoded as definite-length items instead.
> - The keys in every map MUST be sorted in the bytewise lexicographic order of their deterministic encodings.

The spec notes the sort always resolves because CBOR is self-delimiting, so no
encoded item is a prefix of another.

**Type fit** (§3.1, Table 1): major type 0 is "An unsigned integer in the range
0..2^(64)-1 inclusive", major type 1 "A negative integer in the range
-2^(64)..-1 inclusive" — int64 is covered exactly, with no float coercion
anywhere. Major type 2 (byte string) and major type 3 (text string, "encoded as
UTF-8 [RFC3629]") are distinct precisely so as to "allow the differentiation
between unstructured bytes and text". `0xf6` is null. This is a 1:1 map onto
SQLite's storage classes.

**What §4.2.2 leaves open** — and which our profile must therefore pin:

- **int vs float for the same numeric value.** The RFC is explicit: "the
  protocol's deterministic encoding needs to specify whether, for example, the
  integer 1.0 is encoded as 0x01 (unsigned integer), 0xf93c00 (binary16),
  0xfa3f800000 (binary32), or 0xfb3ff0000000000000 (binary64)." It offers three
  rules and notes "Rule 1 straddles the boundaries between integers and
  floating-point values, and Rule 3 does not use preferred serialization, so
  Rule 2 may be a good choice" — Rule 2 being *always encode as the preferred
  float representation*. **Rule 2 is what our domain needs**: it keeps REAL in
  major type 7 and INTEGER in major types 0/1, permanently.
- **NaN payloads** — "the protocol needs to pick a single representation,
  typically 0xf97e00". We sidestep this entirely by rejecting NaN, which is sound
  because SQLite cannot store one.
- **Negative zero** — the application "might decide to represent all zero values
  with a positive sign, disallowing negative zero". We preserve it (SQLite does).
- **Tag presence/absence**, bignum tags vs major types 0/1, subnormals, decimal
  fractions. Our profile forbids all tags outright.
- **Unicode normalization.** The string "normaliz" appears nowhere in RFC 8949.
  NFC and NFD of the same logical text hash differently. Our profile must state a
  policy (see below).
- **Duplicate map keys** are a *validity* matter, not a determinism one — §3.1:
  "A map that has duplicate keys may be well-formed, but it is not valid, and thus
  it causes indeterminate decoding", and §5.6: "A CBOR-based protocol MUST define
  what to do when a receiving application sees multiple identical keys in a map."

**The RFC 7049 legacy hazard.** §4.2.3 documents an *alternative* length-first
ordering: "The core deterministic encoding requirements (Section 4.2.1) sort map
keys in a different order from the one suggested by Section 3.9 of [RFC7049]
(called 'Canonical CBOR' there)." The same key set sorts differently under each.
Any pre-2020 implementation advertising "canonical CBOR" may mean the old one.
**The profile must name §4.2.1 explicitly, never "canonical CBOR".**

**Draft landscape as of 2026-09-10** (IETF datatracker, authoritative):

- [`draft-ietf-cbor-cde`](https://datatracker.ietf.org/doc/draft-ietf-cbor-cde/)
  (Common Deterministic Encoding) — rev 13, **expired 2026-04-17, state "Parked WG
  Document"**, never published. Its abstract states it "does not make technical
  changes to RFC 8949". Web summaries will claim it is active; the datatracker
  states are `Expired` + `Parked`.
- [`draft-ietf-cbor-serialization`](https://datatracker.ietf.org/doc/draft-ietf-cbor-serialization/)
  — rev 08, 2026-07-30, **In WG Last Call**. This is the successor to track. §5:
  "Deterministic serialization is the same as described in Section 4.2.1 of
  [STD94] except for the encoding of floating-point NaNs." Since we forbid NaN,
  **it is a no-op for us** — a good sign that §4.2.1 is a stable base.
- [`draft-mcnally-deterministic-cbor`](https://datatracker.ietf.org/doc/draft-mcnally-deterministic-cbor/)
  (dCBOR) — rev 18, Aug 2026, active but an *individual* submission.
  **Do not adopt.** Its mandatory §2.5 Numeric Reduction: implementations "MUST
  check whether floating point values to be encoded have the numerically equal
  value in DCBOR_INT = [-2^63, 2^64-1]. If that is the case, it MUST be converted
  to that numerically equal integer value". That collapses `REAL 2.0` into
  `INTEGER 2` and destroys the distinction SQLite maintains.

**[RFC 8742](https://www.rfc-editor.org/rfc/rfc8742) CBOR Sequences** — "A CBOR
Sequence consists of any number of encoded CBOR data items, simply concatenated in
sequence", media type `application/cbor-seq`, with no marker between items because
CBOR items are self-delimiting. This is the compaction story: a batch object is
the concatenation of member records, **byte-for-byte unchanged, so every member's
hash survives compaction and remains verifiable inside the batch**. No other
candidate offers this.

**Third-party cross-checking.** [`fxamacker/cbor` v2](https://pkg.go.dev/github.com/fxamacker/cbor/v2)
is "a CBOR codec in full conformance with IETF STD 94 (RFC 8949)" and exposes
`CoreDetEncOptions()` for "RFC 8949 Core Deterministic Encoding" (and, tellingly,
a *separate* `CanonicalEncOptions()` for the old RFC 7049 ordering).
[`cbor2`](https://cbor2.readthedocs.io/en/latest/api.html) exposes
`dumps(..., canonical=False)` — "when `True`, use 'canonical' CBOR
representation". Our conformance suite can be differential-tested against these.

**`CBOR.jl` — why we do not depend on it.**
[JuliaIO/CBOR.jl](https://github.com/JuliaIO/CBOR.jl), the only native CBOR
package in the General registry (verified by scanning the registry snapshot;
the only other CBOR entry is the `libcbor_jll` binary wrapper):

- Registered versions: `0.1.1` and `0.2.0` only. GitHub tags stop at `v0.1.1`
  (2019-12-09); `0.2.0` was registered untagged. Last commit **2025-02-13**.
- 5 open issues, 4 open PRs (19 stars). Oldest open PR from 2019. Open issue #20
  (2022): "There seems to be a problem with the handling of signed numbers."
- **No CI.** `repos/JuliaIO/CBOR.jl/actions/workflows` returns `total_count: 0`;
  README badges point at the dead travis-ci.org under the original personal repo.
- README still describes the format as **RFC 7049**, not RFC 8949.
- **No deterministic encoding.** The map encoder is, in full:

  ```julia
  function encode(io::IO, map::Dict)
      encode_length(io, TYPE_5, map)
      for (key, value) in map
          encode(io, key); encode(io, value)
      end
  end
  ```

  Keys are emitted in `Dict` iteration order. Julia's own docstring for `keys`
  says: *"When the keys are stored internally in a hash table, as is the case for
  `Dict`, the order in which they are returned may vary."* That order is a
  function of `hash` and table capacity, neither of which is a stability
  guarantee across Julia releases. Fatal for a hashed record.
- Further §4.2.1 violations: `encode(io, num::Unsigned)` writes the *native*
  width, so `UInt64(5)` emits 9 bytes rather than `0x05`; floats are written at
  native width with no shortest-form search.
- Any Julia struct without a specific method is encoded as **tag 27 wrapping a
  Julia `Serialization` blob** — non-portable across Julia versions. A record
  format must never be able to reach that path.

The good news is that its *type mapping* is the right one (`Vector{UInt8}` →
major type 2, `String` → major type 3, `Nothing` → `0xf6`), which confirms the
domain mapping is natural; the encoder is simply not built for this job.

**Feasibility check.** A restricted encoder for exactly this domain was prototyped
at ~40 lines and reproduces the RFC's own §4.2.1 vectors:

```
1.5              -> f93e00                    (RFC 8949 §4.2.1: 0xf93e00)      ✓
1000000.5        -> fa49742408                (RFC 8949 §4.2.1: 0xfa49742408)  ✓
{10,100,-1,"z","aa"} -> a5 0a00 186400 2000 617a00 62616100
                        ^ key order 10, 100, -1, "z", "aa" — matches §4.2.1's worked example
INTEGER typemax  -> 1b7fffffffffffffff
INTEGER typemin  -> 3b7fffffffffffffff
REAL 1.0         -> f93c00        INTEGER 1 -> 01        (distinct, as required)
REAL Inf         -> f97c00
REAL -0.0        -> f98000        REAL 0.0  -> f90000    (distinct, as SQLite stores them)
TEXT "ab"        -> 626162
BLOB 0x00ff      -> 4200ff
NULL             -> f6
row [1, 1.0, "ab", 0x00ff, NULL] -> 8501f93c006261624200fff6
```

The float-shortening rule that looks like the fiddly part is ~10 lines: try
`Float32`, then `Float16`, accepting each only if the round-trip is exact *and*
the sign bit is preserved (the sign check is what makes `-0.0` come out as
`f98000` rather than collapsing to `f90000`). Decoding always widens to `Float64`,
which is exact.

### JSON, and RFC 8785 (JCS)

**JSON's data model cannot carry the domain.**
[RFC 8259 §3](https://www.rfc-editor.org/rfc/rfc8259): "A JSON value MUST be an
object, array, number, or string, or one of the following three literal names:
false / null / true". There is no binary type, and the grammar has **no
syntactic distinction between integer and float** — `1` and `1.0` are both
`number`. §6: "Numeric values that cannot be represented in the grammar below
(such as Infinity and NaN) are not permitted", and:

> Note that when such software is used, numbers that are integers and are in the range [-(2**53)+1, (2**53)-1] are interoperable in the sense that implementations will agree exactly on their numeric values.

**JCS's status is weaker than its reputation.**
[RFC 8785](https://www.rfc-editor.org/rfc/rfc8785) is an **Independent
Submission, Informational** (June 2020) — not IETF Standards Track, not a WG
product. It is a genuinely careful spec with a
[test corpus](https://github.com/cyberphone/json-canonicalization), but it is not
a standard in the sense RFC 8949 is.

**JCS forces three workarounds, each of which hands us back a canonicalization
problem we then own:**

1. **int64 must become a string.** §3.1: "JSON number data MUST be expressible as
   IEEE 754 double-precision values. For applications needing higher precision or
   longer integers than offered by IEEE 754 double precision, it is RECOMMENDED
   to represent such numbers as JSON strings". Appendix D uses `int64Max:
   9223372036854775807` as its worked example of exactly this, concluding
   "numbers that do not have a natural place in the current JSON ecosystem MUST
   be wrapped using the JSON string type." (Same in
   [RFC 7493 §2.2](https://www.rfc-editor.org/rfc/rfc7493), which JCS normatively
   requires: "An example would be 64-bit integers".)
2. **BLOB must become base64** (RFC 7493 §4.4 recommends base64url) — and
   canonical base64 (alphabet, padding, no line breaks) becomes our rule to write.
3. **TEXT vs BLOB, and INTEGER vs REAL, must be tagged out of band.** JCS
   Appendix E warns this is brittle: subtypes "MUST" be treated as "pure"
   immutable strings, and shows `{"big":"055"}` canonicalizing to `{"big":"55"}`
   under reviver-based parsing, "presumably making an application depending on
   JCS fail."

**Number formatting is the hard part, and Julia has none of it.** §3.2.2.3:
"Such data MUST be serialized according to Section 7.1.12.1 of [ECMA-262],
including the 'Note 2' enhancement" — i.e. ECMAScript `Number::toString`, pinned
to ECMAScript 2019. Both `JSON.jl` and `JSON3.jl` use `Base.Ryu.writeshortest`,
which is shortest-round-trip but **not** ECMA-262. Measured divergences:

| value | `JSON.jl` / `JSON3.jl` | JCS requires |
|---|---|---|
| `1.0` | `1.0` | `1` |
| `1e21` | `1.0e21` | `1e+21` |
| `1e-6` | `1.0e-6` | `0.000001` |
| `2.0^68` | `2.9514790517935283e20` | `295147905179352830000` |
| `-0.0` | `-0.0` | `0` |

Four systematic causes: `e` vs `e+`, a different decimal-notation window, Julia
always emitting `.0` on integral floats, and `-0.0`. Note the last one is also a
**fidelity loss** for our domain, and that JCS mandates a hard error on NaN and
Infinity — SQLite stores Infinity happily.

**Sorting is also not what Julia does.** §3.2.3: "Property name strings to be
sorted are formatted as arrays of UTF-16 [UNICODE] code units", with an explicit
warning that "sorting of data encoded in UTF-8 or UTF-32 would also work, but the
outcome […] would differ and thus be incompatible with this specification."
`JSON.jl`'s `sort_keys` sorts Julia `String`s, i.e. UTF-8 order, which diverges
above the BMP. It also only sorts `Dict` by default — `NamedTuple`s and structs
are emitted in declaration order.

**Julia package status.** [`JSON.jl`](https://github.com/JuliaIO/JSON.jl) is the
healthiest package in this whole survey — **v1.8.0 released 2026-09-05**, 12 open
issues, 357 stars, actively developed. [`JSON3.jl`](https://github.com/quinnj/JSON3.jl)
is **deprecated**; its README's third line reads "⚠️ This package has been
deprecated. Please migrate to JSON.jl v1 ⚠️". But **no Julia package implements
JCS**: a full scan of the General registry snapshot (2026-09-10) finds 35
JSON-named packages and no canonicalizer; `gh search code --language=julia
"rfc8785"` returns 0 results. Adopting JCS means writing an ECMA-262
`Number::toString` and a UTF-16 code-unit collator from scratch — strictly more
novel code than the CBOR encoder, for a lossier result.

**Human-inspectability, the one real argument for JSON**, is addressed below.

### MessagePack

The [spec](https://github.com/msgpack/msgpack/blob/master/spec.md) (last modified
2017-08-09) **does not contain the word "canonical"**. The only mention of
determinism is under *Future discussion → Profile*:

> Applications which use hash (digest) of serialized data may sort keys of maps to make the serialized data deterministic.

Determinism is explicitly out of scope and delegated to undefined "profiles".
Multiple valid encodings are resolved only by a SHOULD: "If an object can be
represented in multiple possible output formats, serializers SHOULD use the format
which represents the data in the smallest number of bytes" — which for floats
actively *encourages* narrowing float64 to float32 on a per-implementation basis.

The str/bin split is a 2013 retrofit and the old spec still ships alongside the
new one. The upgrade guidance concedes the ambiguity: serializers "should offer
'compatibility mode' which doesn't use bin format family and str 8 format" — so a
conforming client may encode a BLOB as `str 16` and never emit `str 8`. Different
bytes for the same record, from a conforming implementation. That is
disqualifying on its own.

[`MsgPack.jl`](https://github.com/JuliaIO/MsgPack.jl) is in reasonable health —
registered v1.2.1 (2023-12-15) but last commit 2026-06-11 with recent performance
work, 9 open issues / 6 open PRs. But `msgpack_type(::Type{<:AbstractArray}) =
ArrayType()` means a bare `Vector{UInt8}` packs as a msgpack **array of integer
items**, not `bin`; BLOB support requires a wrapper type. And maps are packed in
native iteration order with no sort — the same fatal issue as `CBOR.jl`.

MessagePack is CBOR without the specification. There is no reason to prefer it.

### Arrow IPC

Arrow's [columnar spec](https://arrow.apache.org/docs/format/Columnar.html)
contains **no normative statement about deterministic serialization**. The
degrees of freedom are structural:

- **Padding.** "Implementations are recommended to allocate memory on aligned
  addresses (multiple of 8- or 64-bytes) and pad […] Unless otherwise noted,
  **padded bytes do not need to have a specific value**." Both 8 and 64 are
  conformant.
- **Null slot contents.** "Array slots which are null are not required to have a
  particular value; any 'masked' memory can have any value and need not be
  zeroed."
- **Validity bitmap presence.** "Arrays having a 0 null count may choose to not
  allocate the validity bitmap; how this is represented depends on the
  implementation."
- **Dictionary encoding** is optional, writer-chosen, and the spec itself shows
  two valid encodings of the same logical data.
- **Compression** is optional and per-buffer, with no specified codec level.
- **Batch splitting** is unconstrained; dictionary and record batches "may be
  interleaved".
- **The metadata framing is non-canonical by design.** Arrow uses Flatbuffers,
  whose own [internals doc](https://github.com/google/flatbuffers/blob/master/docs/source/internals.md)
  states: "On purpose, the format leaves a lot of details about where exactly
  things live in memory undefined […] **This may mean two different
  implementations may produce different binaries given the same input values, and
  this is perfectly valid.**"

The last point is the one that closes the question: even a fully pinned Julia
writer cannot promise byte-equality with a future Python or Rust writer, because
Arrow's framing layer disclaims it.

Arrow's *read* compatibility guarantees are genuinely strong ("Since version
1.0.0, there have been five new minor versions and zero new major versions"), and
[`Arrow.jl`](https://github.com/apache/arrow-julia) is a real project — v2.8.1
(2026-01-14), under the Apache org — but it is in maintenance mode: 97 open
issues, 22 open PRs, last substantive commit 2026-06-11, recent history dominated
by dependabot. Its writer also defaults to `ntasks` unbounded (multithreaded
partitioned writes), which is a batching-nondeterminism source unless pinned.

**Arrow is not rejected forever.** It is a good candidate for the *compactor's
transport container*, provided the identity remains our canonical hash of the
logical content rather than the container's bytes. That is precisely the split
every comparable system landed on (below).

### Parquet

Parquet is not merely non-canonical; it is un-canonicalizable, by spec
recommendation. From [`parquet.thrift`](https://github.com/apache/parquet-format/blob/master/src/main/thrift/parquet.thrift),
`struct FileMetaData`:

> /** String for application that wrote this file.  This should be in the format `<Application> version <App Version> (build <App Build Hash>)`. e.g. impala version 1.0 (build 6cf94d29b2b7115df4de2c06e2ab4326d721eb55) **/
> `6: optional string created_by`

The writer's version and build hash are *recommended file content*. A library
upgrade changes the bytes for identical logical data. On top of that: encodings
are writer-chosen with content-dependent, unspecified fallback thresholds ("If the
dictionary grows too big, whether in size or number of distinct values, the
encoding will fall back to the plain encoding"); compression codec and level are
writer-chosen with the spec noting codec specs are "maintained externally by their
respective authors"; row group and page sizes are recommendations ("We recommend
large row groups (512MB - 1GB)"); statistics are optional at three levels; and as
of December 2025 the spec still says "there is no agreed upon consensus of what
constitutes version 2 of the file."

NULL is also out-of-band: "Nullity is encoded in the definition levels […] NULL
values are not encoded in the data."

Julia support is the weakest of the survey: [`Parquet2.jl`](https://gitlab.com/ExpandingMan/Parquet2.jl)
has **moved to GitLab** (the GitHub URL 404s), is at 0.2.35 (registered
2026-09-01) with 21 open issues and a bus factor of 1;
[`Parquet.jl`](https://github.com/JuliaIO/Parquet.jl) is reader-only and
self-deprecating — its README's second line points users at Parquet2.jl and DuckDB.

### Prior art: nobody content-addresses columnar files

This is worth recording because it is the strongest external evidence for the
recommendation. Both major table formats identify data files by **path**, not by
content hash:

- **Delta Lake** ([PROTOCOL.md](https://github.com/delta-io/delta/blob/master/PROTOCOL.md)):
  "The primary key for the entry of a logical file in the set of files is a tuple
  of the data file's `path` and a unique id describing the DV." The `add` action
  carries `path`, `size`, `modificationTime` — **no checksum or content-hash field
  at all**.
- **Apache Iceberg** ([spec](https://iceberg.apache.org/spec/)): the `data_file`
  struct carries `file_path` and `file_size_in_bytes` and, again, **no content
  hash**.
- **PyArrow's content-defined chunking** ([docs](https://arrow.apache.org/docs/python/parquet.html))
  exists precisely because Parquet bytes are unstable. Its own note: "To make the
  most of this feature, you should ensure that Parquet write options remain
  consistent across writes and files. Using different write options (like
  compression, encoding, or row group size) […] may prevent proper deduplication."
  And critically, "the chunk size is calculated on the **logical values before
  applying any encoding or compression**" — a rolling sub-file hash, which is an
  admission that whole-file hash equality is unattainable.

The consistent industry answer is: **hash the logical content with a canonical
encoding you control; let the columnar container be a container.** That is exactly
the recommendation here.

### Purpose-built binary encoding

A from-scratch format would need to pin, exhaustively: a type tag per value;
fixed-width, fixed-endian integers (no varints, or varints plus a minimal-length
rule); a canonical float64 policy covering `-0.0`, NaN and subnormals;
length-prefixed byte strings; a TEXT validity and normalization policy;
deterministic field order; forbidden indefinite-length forms; duplicate-key
rejection; a *rejecting* decoder (canonicality is unenforceable without one); a
version and domain-separation prefix; and a frozen corpus of
(value, bytes, SHA-256) vectors.

That list is, item for item, **RFC 8949 §4.2.1 plus §4.2.2's open choices**. The
work is the same; choosing CBOR means the hard thinking was done by the CBOR
working group, the vectors partly ship in the RFC, and independent implementations
exist to differential-test against. A bespoke format buys nothing and forfeits all
three.

Protobuf is worth citing as the cautionary counter-example, since it is the format
people reach for by habit
([protobuf.dev](https://protobuf.dev/programming-guides/serialization-not-canonical/)):

> Unfortunately, protobuf serialization is not (and cannot be) canonical. […] **Deterministic serialization is not canonical.** […] This means that hashes of serialized protos are fragile and not stable across time or space.

Its recommended alternative is exactly what we are doing: "when you need to
fingerprint a message, we recommend writing out the fingerprinting function
yourself naming all fields."

---

## Verdict on the hybrid (readable envelope, opaque payload blob)

The ticket asks directly whether the envelope and the ops payload should use the
same format, and names a human-readable envelope wrapping an opaque payload blob
as a legitimate hybrid.

**Verdict: reject the two-*format* hybrid; adopt the two-*layer* structure inside
one format.**

Against two formats:

- It doubles the consensus surface. The record hash covers both layers, so a
  JSON envelope means JCS's number formatting, string escaping, base64 profile
  and UTF-16 collation *all* become chain-forking rules — in addition to CBOR's.
  Two canonicalization rule sets, two encoders, two conformance corpora, two
  places for a client to disagree.
- It puts the weaker format where the stakes are highest. The envelope holds
  `prev_hash`, `state_fingerprint`, the schema version and the future
  server-asserted identity slot. Giving *that* layer JSON's int/float ambiguity
  and 2^53 number ceiling — while the payload gets exact typing — is backwards.
- The readability is smaller than it looks. A JSON envelope wrapping a base64
  payload blob is not human-readable in any useful sense; you can read six header
  fields and then hit a wall. The operational question ("what did this record
  *do*?") is answered by the payload, which is opaque under the hybrid by
  definition.

For the two-layer structure, which is the part of the idea worth keeping — make
the record a deterministic-CBOR map whose payload field holds a **CBOR byte string
(major type 2) whose contents are themselves deterministic CBOR**. This preserves
every benefit the hybrid was reaching for, at zero extra rule cost:

- The payload is opaque at the envelope layer, so `payload_hash` is computable and
  verifiable without decoding it, and a compactor can move payload bytes verbatim.
- The envelope can be parsed and validated cheaply without materializing a large
  ops payload.
- One canonicalization rule set, one encoder, one conformance corpus.
- It leaves room to later store the payload compressed at rest (with a codec field
  and the hash defined over the *uncompressed* canonical bytes) without touching
  the envelope's rules.

**Human inspectability is solved by tooling, not by the wire format.** RFC 8949 §8
defines a diagnostic notation "used to present well-formed CBOR values to humans"
(`h'aabbccdd'` for byte strings, JSON-like syntax for maps), every mature CBOR
library can render it, and a `S3SQLite.inspect(key)` that prints diagnostic
notation is a small amount of code. Buying inspectability by weakening the
consensus rule is a bad trade; buying it with a subcommand is a good one.

---

## The S3SQLite CBOR profile — choices to pin

RFC 8949 §4.2.2 requires the application to close these. Recording them here so
the ADR that follows can lift them directly:

1. **Base**: RFC 8949 §4.2.1 core deterministic encoding. Never RFC 7049 §3.9
   length-first ordering (§4.2.3) — name the section explicitly in the ADR.
2. **INTEGER**: major type 0/1, preferred (shortest) argument. Full int64 range.
   Never a bignum tag.
3. **REAL**: major type 7 float, §4.2.2 **Rule 2** — always the preferred float
   representation that exactly represents the value (binary16/32/64 as
   applicable), **never** reduced to an integer. Decoders always widen to
   `Float64`. This is what keeps `INTEGER 1` (`0x01`) distinct from `REAL 1.0`
   (`0xf93c00`).
4. **NaN**: rejected at encode time with a hard error. Justified because SQLite
   converts NaN to NULL on store, so a NaN reaching the encoder is a bug.
5. **`-0.0`**: preserved as `0xf98000`, distinct from `0xf90000`. Note this needs
   an explicit sign-bit check in the float-shortening path.
6. **±Inf**: permitted (`0xf97c00` / `0xf9fc00`) — SQLite stores them.
7. **TEXT**: major type 3, must be well-formed UTF-8, rejected otherwise.
   **No Unicode normalization** — bytes are preserved as-is (matching JCS's
   stance; normalization would make the hash depend on an ICU version). Note the
   consequence: NFC and NFD spellings of the same text are different values.
8. **BLOB**: major type 2. No base64 anywhere.
9. **NULL**: `0xf6`. `0xf7` (undefined) is forbidden.
10. **Tags**: forbidden entirely in v1. Reserved for a future extension.
11. **Maps**: definite length, keys sorted per §4.2.1, **duplicate keys rejected**
    (not last-wins) — RFC 8949 §5.6 requires the protocol to say.
12. **Decoder**: MUST reject non-canonical input — non-minimal arguments,
    indefinite-length items, unknown simple values, trailing bytes. Canonicality
    is unenforceable without a rejecting decoder.
13. **Domain separation**: the record hash is over a version-prefixed byte string,
    so a v1 record and a future v2 record of the same logical content cannot
    collide, and a record hash cannot collide with a `state_fingerprint`.
14. **Conformance vectors**: a frozen corpus of (value, hex bytes, SHA-256)
    committed to the repo, differential-tested against `cbor2(canonical=True)`
    and `fxamacker/cbor` `CoreDetEncOptions()`.
15. **Schema evolution**: unknown envelope keys are *preserved verbatim* when
    re-hashing (they are part of the hashed bytes and cannot be dropped). Whether
    an old client refuses or tolerates an unknown `record_version` is a separate
    open question in #1 — but the format itself makes both possible, since a
    decoder can skip any well-formed item without understanding it.

---

## Risks of the recommended choice

**We own the encoder, so we own its bugs.** This is the central risk and it is
mitigated rather than eliminated. Mitigations: keep the encoder small and
restricted to the closed value domain (no generic Julia object fallback — the path
that makes `CBOR.jl` dangerous must not exist); commit a conformance corpus;
differential-test against `cbor2` and `fxamacker/cbor`; and freeze the encoder
behind a version-tagged entry point so any change is a deliberate format version
bump rather than a silent one.

**The float-shortening rule is the sharpest edge.** §4.2.1's "shortest form that
preserves the value" means a `Float64` may legitimately land in binary16. The
round-trip check must test the sign bit as well as numeric equality, or `-0.0`
silently becomes `+0.0` and two records that SQLite considers different hash the
same. This is a two-line bug with chain-forking consequences; it needs a named
test.

**Unicode normalization is a real, unfixable-by-format hazard.** RFC 8949 says
nothing about it, and our profile chooses "preserve bytes". A client that
normalizes text upstream (some input paths, some editors, macOS filesystem APIs)
will produce a different record for what a user considers the same string. This
is the correct choice — the alternative makes the hash depend on an ICU
version — but it must be documented in `CONTEXT.md` as a property of the system,
not left to be discovered.

**Human inspectability regresses versus JSON**, and the mitigation (a diagnostic
notation dump subcommand) is unwritten work with a real cost the day someone is
debugging a production bucket at 2am with only `aws s3 cp` and `xxd`. This should
be scoped as part of the observability question already listed as open in #1, not
deferred indefinitely. Partial mitigation available immediately: `python3 -c
"import cbor2,sys;print(cbor2.load(open(sys.argv[1],'rb')))"` works on any machine
with `pip install cbor2`.

**Julia CBOR ecosystem risk is accepted, not avoided.** If we ever want a *reader*
richer than our own decoder, `CBOR.jl` is not it, and there is no alternative in
the registry. We are committing to maintaining both directions ourselves. The
offsetting fact is that our decoder is also small, and that non-Julia clients have
excellent, actively maintained CBOR libraries — which is the direction that
matters if this ever grows a second-language client.

**§4.2.1 could in principle be superseded.** `draft-ietf-cbor-serialization`
(rev 08, in WG Last Call) is the live successor and, for our profile, is a no-op —
its only stated divergence from §4.2.1 is NaN encoding, and we forbid NaN. The
residual risk is that a future revision diverges further. Mitigation: our profile
cites §4.2.1 of a *published Internet Standard* by section number, and the
conformance corpus pins the bytes regardless of what later drafts say. Our chain
does not follow the IETF.

**Compaction interacts with the payload-as-byte-string choice.** Concatenating
records as an RFC 8742 sequence preserves member hashes, which is the property we
want. But if we later compress payloads at rest, the batch object contains
compressed payloads while the hashes are defined over uncompressed bytes — the
compactor must not be able to conflate the two. The codec field belongs in the
envelope, and the ADR should state that the hash input is always the uncompressed
canonical payload.
