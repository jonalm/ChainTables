# LazyFiles.jl API gap analysis

> **Historical.** Written when the package was S3SQLite. LazyFiles was dropped
> entirely ([ADR-0010](../adr/0010-s3sqlite-owns-its-s3-client-and-its-record-cache.md));
> the two properties the chain depended on are now ChainTables's own rules
> there, and the rest of this analysis constrains nothing.

Research for [#5](https://github.com/jonalm/ChainTables/issues/5), part of the
[#1](https://github.com/jonalm/ChainTables/issues/1) design map.

**Question**: what does LazyFiles.jl already give an S3-backed hash-chain design,
and what is missing?

**Primary source**: the local clone at `/Users/jonalmeriksen/biome/LazyFiles.jl`,
version `0.4.1`, commit `4f3f312` (clean tree). Every line reference below is to
`src/LazyFiles.jl` or `test/runtests.jl` at that commit. This is a code-reading
result, not a web-search one; nothing here is inferred from documentation that
the source does not back.

LazyFiles is modifiable by this effort, so each gap carries a **LazyFiles** or
**S3SQLite** verdict and a sketch of the addition.

---

## 1. The shape of the package

The whole package is one 674-line module with two distinct halves, and the split
between them is the single most important fact for this design:

**Half A — the generic, extensible lazy-blob framework.** `AbstractLazyBlob`
(`src/LazyFiles.jl:274`), `resolve` (`:340`), the functor `b()` (`:367`),
`local_path` (`:328`), `clear_from_cache` (`:473`), and the two-method extension
interface `cache_subpath` (`:294`) + `fetch!` (`:306`), with optional
`config_type` (`:285`) and `validate_config` (`:319`). This half is
backend-agnostic and genuinely open for extension.

**Half B — the S3 operations.** `s3_upload` (`:482`), `s3_list_with_stats`
(`:573`), `s3_list` (`:610`). These are **plain functions with concrete
`S3Config` arguments that shell out to rclone directly** — they dispatch on
nothing, take no blob, and have no generic fallback. They are not part of the
extension interface and cannot be overridden per-backend.

The transport for all of half B (and for `LazyS3Blob`'s `fetch!`) is the **rclone
CLI**, via `Rclone_jll` pinned to `1.74.3` (`Project.toml` `[compat]`).
`_with_rclone` (`:663`) writes a temporary rclone config file and hands back a
`make_cmd` closure; `_run` (`:627`) runs the command and returns
`(; ok, code, out, err)`. There is no HTTP client, no request/response object,
and no place in the call chain where an HTTP header or status code exists as a
value.

That transport choice is the root cause of most of the gaps below.

### What the chain design gets for free today

- **Content-addressed immutable record fetch.** `LazyS3Blob` (`:380`) keyed by
  `(bucket, name)`, caching at `<cache>/<bucket>/<name>` (`:385`). For immutable
  hash-named records this is exactly right — see §7.
- **Atomic, concurrency-safe cache writes.** `resolve` fetches to a unique temp
  in the destination directory and `mv`s it in (`:352`–`:363`), so an interrupted
  run never caches a truncated record and concurrent resolves of the same record
  do not clobber each other.
- **A real absent/failed distinction.** `fetch!`'s documented contract (`:296`–
  `:305`) is that a missing `dest` means "genuinely absent" and anything else
  raises. `LazyS3Blob.fetch!` (`:389`) honours it, and `resolve` deletes a
  partial `dest` if `fetch!` throws (`:355`–`:359`).
- **Recursive listing with size and server last-modified time.** `S3Entry`
  (`:510`) = `@NamedTuple{blob::LazyS3Blob, size::Int, modified::DateTime}`.
- **Credential plumbing** — `S3Config` (`:78`), `config_from_env` (`:118`),
  `config_from_profile` (`:177`), `default_config!` (`:109`).
- **Cross-OS key portability checking** — `_check_portable_name` (`:219`),
  applied both at resolve time and at upload time (`:492`). See §9: this
  constrains the S3SQLite key layout.

---

## 2. Conditional PUT

**Not supported, and not expressible without a new code path.**

`s3_upload` (`:482`–`:500`) builds a fixed command:

```julia
_run(make_cmd(`copyto --s3-no-check-bucket -- $local_file $RCLONE_REMOTE:$bucket/$name`); verbose)
```

There is no keyword for headers, no `if_none_match`, no passthrough of extra
rclone flags. `make_cmd` (`:669`) only prepends the binary and `--config`. The
live test at `test/runtests.jl:530` ("re-uploading the same name replaces the
object") confirms the observable semantics are **unconditional last-writer-wins
overwrite**.

**Can a caller distinguish "lost the race" from a genuine failure?** No, and this
is worse than it first looks. The only failure signal is:

```julia
r.ok || error("upload failed (rclone exit $(r.code)): $(strip(r.err))")   # :498
```

- The exception type is a bare `ErrorException` — the module raises `error(...)`
  everywhere and defines **no exception types at all** (`grep` for `struct.*<:
  Exception` finds nothing).
- `r.code` is *rclone's* process exit code (`:638`), which is a small coarse
  space of its own; it is not an HTTP status. A `412 Precondition Failed` and a
  `403 Forbidden` do not land on distinguishable codes.
- `r.err` is rclone's stderr text. Discriminating a lost race would mean
  string-matching stderr — fragile, and not a contract anything promises.

So even if a header could be smuggled through, **the outcome could not be read
back reliably**. Any conditional-write commit protocol needs the failure mode to
be a typed, first-class value.

> Whether S3 conditional writes give exact first-writer-wins at all is
> [#4 / `research/s3-conditional-writes`](https://github.com/jonalm/ChainTables/issues/4)'s
> question, not this one. This ticket answers only: *LazyFiles cannot express it
> or observe its outcome today.*

**Verdict: LazyFiles.** Conditional PUT is a generic remote-object concern, not a
chain-specific one, and the failure taxonomy must live where the transport lives.

**Sketch:**

```julia
# A typed outcome, not a bare bool, so the caller cannot silently ignore a race.
struct PreconditionFailed <: Exception
    bucket::String
    name::String
    detail::String
end

"""
    s3_put_if_absent(data, bucket, name; config) -> LazyS3Blob

Upload only if `name` does not already exist (`If-None-Match: *`).
Throws `PreconditionFailed` iff the object already existed; any other failure
raises a different exception. Never overwrites.
"""
function s3_put_if_absent end
```

This almost certainly cannot be built on `rclone copyto` — see §10.

---

## 3. ETag / version metadata

**Nothing returns it. Anywhere.**

- `s3_upload` returns `LazyS3Blob(; bucket, name)` (`:499`) — the handle only,
  no upload result.
- `S3Entry` (`:510`) has exactly three fields: `blob`, `size`, `modified`.
- `_LsObject` (`:515`–`:519`) parses only `Path`, `Size`, `ModTime` from
  `lsjson`; the comment at `:512`–`:514` says the rest is deliberately ignored.
- The `lsjson` invocation (`:582`) passes `--files-only -R --use-server-modtime`
  and no `--hash`, so rclone is not even asked to emit hashes.
- `resolve` (`:340`) returns `String | Nothing` — a path, with no metadata.

`grep -ni "etag\|version\|if-none\|precondition"` over `src/LazyFiles.jl` matches
only unrelated prose ("precedence order", "the `region=` keyword").

For a hash chain this is less costly than it sounds — records are *named* by
their own content hash, so the ETag is redundant for integrity. It matters for
two other things: (a) reading back the result of a conditional write, and (b)
re-validating a mutable pointer object, if the design ever has one (§7).

**Verdict: LazyFiles.**

**Sketch:** add an optional `etag::Union{String,Nothing}` field to `S3Entry`
(populated by passing `--hash` / reading `lsjson`'s `Hashes`, or by whatever
transport replaces rclone), and have a conditional-put return the new ETag.
Beware: an S3 ETag is only an MD5 for single-part uploads; for multipart it is a
composite. Do not let anything in S3SQLite treat it as a content hash.

---

## 4. Listing

### Pagination past 1000 keys

**Correct, but by delegation and untested.** LazyFiles issues one
`rclone lsjson ... -R` (`:582`) and parses whatever comes back
(`_parse_lsjson`, `:532`). Paginating S3's 1000-key `ListObjectsV2` response is
entirely rclone's job; there is no continuation-token handling in LazyFiles
because there is no HTTP layer for it to live in. rclone does paginate, so this
is very likely fine — but note that the offline test (`test/runtests.jl:347`)
feeds `_parse_lsjson` a two-element fixture, and the live tests
(`test/runtests.jl:442`–`:529`) list a handful of objects. **Nothing in the test
suite exercises more than 1000 keys.** For a design whose bucket accumulates one
object per transaction, that boundary will be crossed routinely and is currently
unverified.

Two consequences of the "one shot, then parse" shape (`:581`–`:585`):

- **The entire listing is materialized twice in memory** — once as a JSON
  `String` in `r.out` (`:638`), once as a `Vector{S3Entry}`. No streaming, no
  incremental consumption.
- **No early termination.** You cannot stop after the first N keys. Combined
  with §5 this means head-of-chain discovery costs a full sweep of the prefix.

### Is `prefix` truly server-side?

**Partly — and its semantics differ from S3's in a way that matters.**

It is genuinely server-side in the sense that the whole bucket is not fetched:
`:579`–`:580` build the remote path

```julia
pfx = strip(prefix, '/')
remote = isempty(pfx) ? "$RCLONE_REMOTE:$bucket" : "$RCLONE_REMOTE:$bucket/$pfx"
```

and rclone lists that subtree. But this is a **`/`-delimited directory path, not
a raw byte prefix.** The docstring is precise about it (`:555`: "keys under that
`/`-delimited key prefix"), and the leading/trailing slashes are stripped.

So `prefix = "logs/2024"` selects `logs/2024/…`, but `prefix = "logs/20"` does
**not** select `logs/2024/…` — it names a directory that does not exist, and
yields an empty vector (the behaviour asserted at `test/runtests.jl:502` for a
non-matching prefix). S3's own `ListObjectsV2` `prefix` is a plain byte prefix
with no such restriction.

**This is a hard constraint on the S3SQLite key layout**: any prefix-scan the
design wants must fall on a `/` boundary. A scheme like
`records/00001234-<hash>` cannot be narrowed by leading digits; it would need
`records/00/00/1234-<hash>` or similar.

Note also that keys come back *relative* to the listed directory and are
re-prefixed by `_parse_lsjson` (`:536`), so `blob.name` is always the full key —
asserted at `test/runtests.jl:498` and `:500`.

### Is listing order documented?

**No.** The `s3_list_with_stats` docstring (`:548`–`:571`) and the `s3_list`
docstring (`:596`–`:609`) say nothing about order. `_parse_lsjson` (`:532`–
`:546`) `push!`es in JSON-document order and never sorts. So the order is
whatever `rclone lsjson -R` emits — an implementation detail of a recursive,
potentially concurrent directory walk, not a guarantee this package makes.

**A caller must sort. Never index into a listing and assume anything.**

### `s3_list_with_stats` vs `s3_list` cost

**Identical. There is no cheap variant.** `s3_list` is literally a projection:

```julia
s3_list(bucket::AbstractString; kwargs...) =
    [e.blob for e in s3_list_with_stats(bucket; kwargs...)]   # :610-611
```

Same rclone process, same `--use-server-modtime`, same full JSON parse, plus one
extra allocation for the projection. Choosing `s3_list` to "avoid paying for
stats" saves nothing. Similarly the `pred` and `Regex` overloads (`:590`–`:594`,
`:612`–`:613`) filter **client-side, after the full listing returns** — the
docstring is explicit (`:560`). A regex is not a server-side narrowing.

### Timestamp resolution

`--use-server-modtime` (`:582`) makes `modified` the S3 `LastModified` value, but
`_parse_modtime` (`:526`) truncates to the first 19 characters — **whole seconds,
sub-second part and zone suffix dropped**, as the comment at `:521`–`:525`
states, and as asserted at `test/runtests.jl:362`–`:363`.

If the ordering rule under consideration in #1 ("lowest `LastModified` wins among
records sharing a `prev_hash`") is ever adopted, **two records written in the
same second are indistinguishable through this API.** That is a direct argument
against the LastModified tiebreak and in favour of conditional writes.

**Verdicts:**

| Item | Verdict |
| --- | --- |
| Streaming / bounded listing (`limit`, early stop) | **LazyFiles** |
| Documenting (or imposing) listing order | **LazyFiles** — cheapest fix here is to sort by key in `_parse_lsjson` and document it |
| Raw byte-prefix listing, not directory-path | **LazyFiles**, if the transport is replaced; otherwise a **S3SQLite** key-layout constraint to design around |
| Sub-second `modified` | **LazyFiles** — but S3SQLite should not depend on it either way |
| >1000-key correctness test | **LazyFiles** (test-suite gap) |

**Sketch:**

```julia
s3_list_with_stats(bucket; prefix="", start_after="", limit=nothing,
                   sorted=true, config=default_config(S3Config))
```

with `sorted=true` documented as ascending by full key, and `limit` genuinely
stopping the sweep rather than truncating a completed one.

---

## 5. Cheap head-of-chain discovery

**None of the three primitives exist.**

- **`start_after` / `StartAfter`** — no such keyword. `s3_list_with_stats`
  (`:573`–`:576`) accepts only `bucket`, `prefix`, `config`, `verbose`.
- **Delimiter / common prefixes** — unreachable. `:582` hardcodes
  `--files-only -R`: `-R` forces a flat recursive walk (no delimiter, so no
  common prefixes come back) and `--files-only` discards directory entries. The
  non-recursive rclone mode that *would* surface common prefixes is not exposed.
- **`HEAD` on a known key** — there is no stat/exists/head operation at all. The
  only way to ask "does key K exist?" is to `resolve` the blob, which
  **downloads the entire object** (`:340`–`:365`) or lists its prefix. There is
  no `s3_exists`, no `s3_stat`.

So the cheapest head-of-chain discovery available today is a **full recursive
listing of the chain prefix, parsed in full, unordered, then sorted and scanned
client-side** — cost linear in the number of records in the chain, on every
single head lookup. For a read-heavy design with infrequent writes, that is the
wrong cost curve: reads pay for the whole history to learn there is nothing new.

This also interacts badly with the #1 forward-compat constraint that batching /
compaction must not break head discovery — a scheme that depends on "list
everything and take the max" is precisely the one compaction disturbs.

**Verdict: both, at different layers.**

- The **primitives** (`start_after`, a bounded/reverse listing, `s3_stat`) are
  generic remote-object operations → **LazyFiles**.
- The **discovery strategy** built on them (what the head key looks like, how a
  reader confirms it is at the tip, how that survives compaction) is
  chain-specific → **S3SQLite**, and it feeds the commit-protocol ticket.

**Sketch (LazyFiles):**

```julia
"""
    s3_stat(blob; config) -> @NamedTuple{size::Int, modified::DateTime, etag::String} | Nothing

Metadata for a single object without downloading it (`HEAD`). `nothing` iff the
object does not exist; a genuine failure raises.
"""
function s3_stat end

"""
    s3_common_prefixes(bucket; prefix="", config) -> Vector{String}

The immediate "subdirectories" under `prefix` (S3 delimiter listing). One request
per 1000 prefixes rather than one per 1000 keys.
"""
function s3_common_prefixes end
```

`s3_common_prefixes` is what makes a hierarchical key layout (`records/<year>/
<month>/…`) navigable in O(depth) instead of O(records), and it is the primitive
a compaction scheme would lean on.

---

## 6. Negative caching

**Absence is not memoized. This is correct behaviour for a chain head, and the
ticket's worry does not materialize.**

Tracing `resolve` (`:340`–`:365`) on a miss:

1. `isfile(lp) && return lp` (`:347`) — no cache file, fall through.
2. `fetch!` writes nothing (`LazyS3Blob.fetch!`, `:389`, when rclone `copyto`
   exits 0 having transferred nothing).
3. `isfile(tmp) || return nothing` (`:362`) — **returns before the `mv` at
   `:363`.** Nothing is written to the cache, and no in-memory record of the miss
   is kept.

There is no memo table in the module: the only mutable process state is
`CACHE_DIR::Ref{String}` (`:26`) and `DEFAULT_S3_CONFIG::Ref{S3Config}` (`:90`).
So a handle to a not-yet-existing chain head can be resolved repeatedly and will
pick up the object the moment it appears. `test/runtests.jl:437` asserts the
`nothing`, and `:431` asserts that a cleared, then deleted, blob resolves to `nothing` again.

**Had it been memoized, it would indeed have been a bug** for exactly the reason
the ticket suspects — a poller for a head expected to appear later would never
see it. Worth recording as a **property S3SQLite depends on**, so that a future
"optimization" adding a negative cache to LazyFiles does not silently break the
chain reader.

**The real cost is the opposite one**: because nothing is memoized *and* nothing
is cheap (§5), every "is there a new head?" poll spawns a fresh rclone process
and does a full download attempt. Process-spawn-per-poll is a poor polling loop.

**One genuine fail-fast concern here.** The absent signal is *structural* — "the
file isn't there" — not a positive 404. The comment at `:393`–`:396` is candid:
rclone `copyto` exits 0 and writes nothing when the object is absent. Any other
future path where rclone exits 0 without writing `dest` would be read as "object
does not exist" with no way to tell. For a hash chain, a spurious "record absent"
is a truncated-chain error, which is precisely the class of thing that must
fail loudly. A positive existence signal (`s3_stat`, §5) removes the ambiguity.

**Verdict:**
- Guarantee "absence is never memoized" in the `resolve` docstring →
  **LazyFiles** (documenting an existing property).
- A positive-existence check instead of an inferred one → **LazyFiles**
  (`s3_stat`).
- Polling strategy and the truncated-chain error → **S3SQLite**.

---

## 7. Cache re-validation semantics

**A cached blob is never re-validated. Not by ETag, not by size, not by mtime,
not ever.**

The whole of the cache-hit path is one line:

```julia
isfile(lp) && return lp    # :347
```

`local_path` (`:328`) → `cache_subpath` (`:385`) → `(bucket, name)`. **The cache
key is the S3 key and nothing else.** Once a byte sequence is cached under a key,
that key resolves to those bytes forever in that cache root, regardless of what
the bucket now holds. The only escape is `clear_from_cache` (`:473`).

This is not incidental — it is tested as intended behaviour. `test/runtests.jl:406`
("cache serves the blob after the remote is deleted") uploads, resolves, deletes
the remote, resolves again, and asserts the same content comes back. And
`test/runtests.jl:530` ("re-uploading the same name replaces the object") has to
call `clear_from_cache(blob)` explicitly (`:538`) before the new content is
visible.

**For the S3SQLite design this splits cleanly:**

- **Immutable, content-addressed transaction records: correct, and free.** If a
  record's key contains its own hash, the key→bytes mapping is immutable by
  construction, the cache can never be stale, and the "persist cached immutable
  records" premise in #1 is satisfied by LazyFiles as-is with no work.
- **Any mutable pointer object: a silent, permanent correctness bug.** A
  `chain/HEAD` key that gets overwritten on each commit, resolved through a
  `LazyS3Blob`, would pin the first value read on that machine forever. Not a
  staleness window — a permanent stale read that survives process restarts,
  because the cache is on disk. It would present as a client stuck at an old
  head with no error.

**This is the sharpest single finding in this ticket.** It should become a
recorded constraint, not a footnote:

> **Every object S3SQLite reads through a `LazyS3Blob` must be immutable and
> content-addressed.** If the design ever needs a mutable pointer object, it must
> not be read through the blob cache — it needs an explicit uncached read.

**Verdict:**
- The rule above → **S3SQLite** (a design constraint / candidate ADR).
- An opt-out for callers that genuinely need a mutable object → **LazyFiles**.

**Sketch (LazyFiles):**

```julia
resolve(b; revalidate=false, ...)   # or, more honestly, a separate entry point:

"""
    fetch_uncached(b; config) -> String | Nothing

Fetch `b` to a caller-owned temporary path, bypassing the cache entirely. For
objects whose key→bytes mapping is *not* immutable — the cache assumes it is.
"""
function fetch_uncached end
```

A separate entry point is the better shape: it makes "this object is mutable" a
visible, greppable decision at the call site rather than a keyword that is easy
to forget.

---

## 8. The custom-backend extension interface, and the in-process fake

### What the interface actually is

Required (both documented at `:256`–`:272` and in README "Extending"):

| Method | Line | Contract |
| --- | --- | --- |
| `cache_subpath(b) -> Tuple` | `:294` | path components under the cache root |
| `fetch!(b, dest; config, verbose)` | `:306` | write `dest`, or leave it absent **iff** genuinely absent; raise on any real failure |

Optional:

| Method | Line | Default |
| --- | --- | --- |
| `config_type(b) -> Type` | `:285` | `NoConfig` |
| `validate_config(config, b)` | `:319` | no-op |
| `local_path(b; cache_dir)` | `:328` | `_checked_path(cache_dir, cache_subpath(b)...)` |
| `default_config(::Type{C})` | `:100` | must be added for a new config type |

Implement those and `b()`, `resolve`, `local_path`, `clear_from_cache` all work.
The test suite demonstrates both shapes — a no-config `LocalBlob`
(`test/runtests.jl:94`) and a `TokenBlob` with its own config type
(`test/runtests.jl:114`), exercised at `test/runtests.jl:306`.

The interface is clean and sufficient — **for reading one object.**

### What a faithful in-process fake S3 would have to implement

This is where the half-A/half-B split (§1) bites. #1 names an "in-process fake S3
backend behind the LazyFiles extension interface" as the test substrate for *all*
logic. **The extension interface does not reach far enough to support that.**

A `FakeS3Blob <: AbstractLazyBlob` can fake `fetch!`, so **GET is fakeable**.
Everything else the commit protocol needs is not:

| Operation the chain needs | Reachable through the extension interface? |
| --- | --- |
| GET object | **Yes** — `fetch!` (`:306`) |
| PUT object | **No** — `s3_upload` (`:482`) is a concrete function hardcoded to rclone + `S3Config`; it dispatches on nothing |
| Conditional PUT | **No** — does not exist at all (§2) |
| LIST with prefix | **No** — `s3_list_with_stats` (`:573`) likewise concrete and hardcoded |
| HEAD / stat | **No** — does not exist at all (§5) |
| DELETE | **No** — there is no public delete operation anywhere in the module. The test suite defines its own `delete_remote` helper by reaching into the private `_with_rclone` (`test/runtests.jl:41`) |

So today the fake would have to be installed by **method piracy on the concrete
`s3_upload` / `s3_list_with_stats` functions**, or S3SQLite would have to define
its own storage interface and treat LazyFiles as one implementation of it. The
former is not viable; the latter is a real architectural option and worth naming.

Additionally, to be a *faithful* double rather than merely a working one, the
fake must reproduce the real backend's awkward properties, all of which this
research pins down:

1. **Unconditional overwrite** on plain PUT (`test/runtests.jl:530`).
2. **Conditional PUT** raising a distinguishable "precondition failed" that is
   *not* confusable with an auth/network failure (§2) — the property the whole
   commit protocol will rest on.
3. **Absence returns `nothing`, failure raises** — never conflate them
   (`:296`–`:305`).
4. **Unordered listings** (§4), so tests catch any accidental reliance on order.
   A fake that returns insertion order would hide exactly the bug it should
   expose; it should deliberately shuffle.
5. **Second-resolution, server-assigned `modified`** (`:526`), including the
   ability to produce *ties* — the case a LastModified-based ordering rule breaks
   on.
6. **Directory-boundary prefix semantics**, not byte-prefix (§4), or the fake
   will accept key layouts real S3-via-rclone rejects.
7. **Key portability rejection** (`:219`, §9), so a key layout that fails on the
   real backend fails in tests too.
8. **A read-through cache that never re-validates** (§7) — the fake must not
   accidentally be fresher than the real thing.

**Verdict: LazyFiles**, and this is the highest-leverage addition in this
document. The generic fix is to give half B the same treatment half A already
has: make the S3 operations dispatch on a backend value rather than being
hardcoded to rclone.

**Sketch:**

```julia
abstract type AbstractBlobStore end

struct S3Store <: AbstractBlobStore          # the rclone-backed real thing
    config::S3Config
end

# The operation set, each dispatching on the store:
get!(store, key, dest)                        -> Nothing        # today's fetch!
put(store, key, data)                         -> PutResult
put_if_absent(store, key, data)               -> PutResult      # throws PreconditionFailed
stat(store, key)                              -> ObjectMeta | Nothing
list(store; prefix, start_after, limit)       -> Vector{S3Entry}
delete(store, key)                            -> Bool
```

with `LazyS3Blob` becoming a handle that carries (or is resolved against) a
store. Then an in-process `FakeStore <: AbstractBlobStore` backed by a `Dict` is
a first-class, supported test double, and the S3SQLite test substrate premise in
#1 holds without piracy.

This is a larger change than the other items and is properly a decision, not a
finding — it feeds the "LazyFiles API additions" decision that this ticket was
chartered to inform.

---

## 9. Two constraints S3SQLite must design around regardless

### 9a. Key characters — `:` is forbidden

`_check_portable_name` (`:219`–`:239`) rejects, per `/`-delimited segment:

- backslash (`:223`)
- control characters and `< > : " | ? *` (`:226`)
- leading space, trailing space, trailing dot (`:232`)
- Windows reserved device names `CON`, `PRN`, `AUX`, `NUL`, `COM1..9`,
  `LPT1..9`, with or without an extension (`:235`, set at `:208`)

and it runs on **both** paths — `local_path` via `_checked_path` (`:245`) and
`s3_upload` before uploading (`:492`), so an object cannot be stranded under a
key the handle could never read back (`test/runtests.jl:281`).

**Concretely: an ISO-8601 timestamp cannot appear in a key.**
`records/2024-01-02T12:00:00Z/…` is rejected on the colons. Hex hashes,
`-`-separated dates, and zero-padded integers are all fine.

**Verdict: S3SQLite** — a key-layout constraint, to record wherever the bucket
layout is decided. (Loosening it in LazyFiles would trade away the cross-OS
caching guarantee, which is a real feature; better to design keys within it.)

### 9b. Upload requires a file on disk

`s3_upload` (`:482`–`:487`) takes `local_file::AbstractString` and asserts
`isfile(local_file)`. There is no way to upload an in-memory buffer. Every
committed record would have to be written to a temp file first — an extra
round-trip through the filesystem on the write path, and one more failure mode
(temp-dir permissions, disk full) in the commit protocol.

**Verdict: LazyFiles.** `s3_put(data::AbstractVector{UInt8}, bucket, name)`
alongside the file form. Note this is another thing the rclone CLI transport
makes awkward — `copyto` wants paths.

---

## 10. The structural conclusion

Items §2 (conditional PUT), §3 (ETag), §5 (`start_after`, HEAD, common
prefixes), and §9b (in-memory PUT) share one root cause: **the transport is a
CLI, and a CLI has no request headers, no response headers, and no status
codes.** Every one of these gaps is a request or response *field* that the rclone
process boundary discards.

`--s3-no-check-bucket` (`:496`) is the shape of the workaround available —
rclone-specific flags for rclone-specific behaviours — and it does not generalize
to reading a `412` back out of an exit code.

So the honest framing for the decision this ticket feeds is not "add a few
keywords to LazyFiles". It is:

> **A hash-chain commit protocol needs an HTTP-level S3 client. rclone can serve
> the read path — bulk GET and recursive LIST, which is exactly what it is good
> at — but the write path needs conditional PUT with a readable status.**

That suggests LazyFiles grows a second, HTTP-based S3 path (SigV4-signed requests
for PUT/HEAD/conditional-PUT) while keeping rclone for bulk transfer, behind the
`AbstractBlobStore` seam sketched in §8. Whether that is worth it — versus
S3SQLite owning its own thin S3 client and using LazyFiles only for cached
immutable record reads, which it does *very* well — is the decision, and it
depends on what
[#4 / `research/s3-conditional-writes`](https://github.com/jonalm/ChainTables/issues/4)
concludes about S3's conditional-write guarantees.

---

## Gap summary

| # | Gap | Evidence | Verdict |
| --- | --- | --- | --- |
| 1 | No conditional PUT (`If-None-Match`) | `:482`–`:500` fixed command; `test/runtests.jl:530` | **LazyFiles** |
| 2 | Lost-race indistinguishable from real failure; no exception types, only rclone exit code + stderr text | `:498`, `:638` | **LazyFiles** |
| 3 | No ETag/version returned by any call | `:499`, `:510`, `:515`–`:519`, `:582` | **LazyFiles** |
| 4 | No bounded/streaming listing; whole listing materialized, no early stop | `:581`–`:585`, `:638` | **LazyFiles** |
| 5 | Listing order undocumented and unsorted | `:532`–`:546`, `:548`–`:571` | **LazyFiles** (sort + document) |
| 6 | `prefix` is a `/`-delimited directory path, not an S3 byte prefix | `:579`–`:580`, `:555` | **S3SQLite** key layout (or LazyFiles if transport changes) |
| 7 | `s3_list` costs exactly the same as `s3_list_with_stats`; `pred`/`Regex` filter client-side | `:610`–`:613`, `:560`, `:590`–`:594` | Documentation only — no gap, but a trap |
| 8 | `modified` truncated to whole seconds; ties unresolvable | `:526`, `test/runtests.jl:362` | **LazyFiles**; argues against a LastModified ordering rule in **S3SQLite** |
| 9 | No `start_after` | `:573`–`:576` | **LazyFiles** |
| 10 | No delimiter / common-prefixes listing (`-R --files-only` hardcoded) | `:582` | **LazyFiles** |
| 11 | No HEAD/stat/exists — existence can only be tested by downloading | `:340`–`:365`; no such function | **LazyFiles** |
| 12 | Head-of-chain discovery therefore costs a full prefix listing every time | §5 | **S3SQLite** strategy on **LazyFiles** primitives |
| 13 | Absence **is not** memoized — the feared bug does not exist; record it as a depended-on property | `:362` before the `mv` at `:363`; no memo table (only `:26`, `:90`) | **LazyFiles** (document the guarantee) |
| 14 | Absence is inferred structurally ("no file") rather than from a positive 404 | `:362`, `:393`–`:396` | **LazyFiles** (`s3_stat`) |
| 15 | **Cached blobs are never re-validated** — mutable pointer objects would be a permanent stale read | `:347`; `test/runtests.jl:406`, `:530` | **S3SQLite** constraint (records must be content-addressed) + **LazyFiles** uncached read |
| 16 | Extension interface covers GET only; `s3_upload`/`s3_list` are concrete, unhookable functions | `:482`, `:573` vs `:294`, `:306` | **LazyFiles** — blocks the #1 fake-S3 test-substrate premise |
| 17 | No public DELETE (tests pirate `_with_rclone`) | `test/runtests.jl:41` | **LazyFiles** |
| 18 | Keys cannot contain `:` (nor `\ < > " \| ? *`, trailing dot/space, `CON`/`NUL`/…) | `:219`–`:239`, `:492` | **S3SQLite** key layout |
| 19 | Upload requires a file on disk; no in-memory PUT | `:482`–`:487` | **LazyFiles** |
| 20 | No >1000-key listing test anywhere in the suite | `test/runtests.jl:347`, `:442`–`:529` | **LazyFiles** (test gap) |

**What LazyFiles already gives, free and correct:** cached content-addressed
immutable-record reads with atomic, concurrency-safe cache writes
(`:352`–`:363`); a sound absent-vs-failed distinction (`:296`–`:305`); recursive
prefix listing with size and server modification time; credential plumbing; and a
clean two-method extension interface **for the read path**.

**What is missing, in one line:** everything on the *write* path, every *cheap*
metadata primitive, and any seam through which a fake backend could replace
upload and listing.
