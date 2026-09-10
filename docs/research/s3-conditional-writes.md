# S3 conditional writes and `LastModified` semantics

Research note for [issue #2](https://github.com/jonalm/S3SQLite/issues/2) (map: #1).
Date: 2026-09-10. Sources are primary: the AWS S3 User Guide, the S3 API Reference,
AWS launch announcements, and MinIO's own docs and source.

Throughout, **[G]** marks something AWS states in writing (a guarantee we may build on)
and **[ND]** marks something that is *not documented* — it may well work, but the design
must not rest on it.

---

## Verdict

**Yes — exact first-writer-wins is available, and `If-None-Match: *` is the authority.
`LastModified` is not, and must not be used to arbitrate a race.**

AWS states the arbitration rule explicitly:

> "If multiple conditional writes or copies occur for the same object name, the first
> write operation to finish succeeds. Amazon S3 then fails subsequent writes with a
> `412 Precondition Failed` response."
> — [User Guide, Conditional write behavior](https://docs.aws.amazon.com/AmazonS3/latest/userguide/conditional-writes.html)

That is a documented total order over writers contending for one key, decided by S3
itself. It is exactly the primitive the commit protocol needs.

By contrast, AWS documents **no ordering guarantee whatsoever** for `LastModified`: no
monotonicity, no uniqueness, no promise that it reflects commit order. Its HTTP wire
form is whole seconds (RFC 7231), so two records committed in the same second are not
even distinguishable, let alone ordered. See [§3](#3-lastmodified).

**Consequence for the commit protocol.** Make the record's own key the thing being
contended: derive the key from the chain position (e.g. `<prefix>/<seq>-<hash>` or
`<prefix>/<prev_hash>`), and `PUT` it with `If-None-Match: *`. The winner is whoever
S3 says won; the loser gets a `412`, re-reads the head, rebases its transaction and
retries. No timestamp arbitration, no clock trust, no tie-break rule. The
"lowest `LastModified` wins" sketch in map #1 should be **retired**.

**Use `If-None-Match`, not `If-Match`.** The two are *not* equally well documented. The
first-writer-wins sentence above appears only under `If-None-Match`; AWS never claims
atomicity or CAS for `If-Match` in the documentation, and omits it from `PutObject`'s own
list of features that override last-writer-wins. See [§2](#2-if-match-on-putobject). Since
our records are immutable and write-once, key-creation is the natural fit anyway.

**The catch is not S3, it is our transport.** LazyFiles uploads by shelling out to
`rclone copyto`, which exposes no conditional-write path and retries by default —
see [§6](#6-the-lazyfiles--rclone-gap). That is the real work item this research
surfaces, and it feeds #8.

**Two things that must not be skipped**, both in [§7](#7-open-risks): verify empirically that
the header is actually signed and honoured (the failure mode is a *silent* overwrite, not an
error); and decide how a writer distinguishes "I lost the race" from "my own write succeeded
but the acknowledgement was lost" — both present as `412`.

---

## 1. `PutObject` with `If-None-Match: *`

### Availability

- **[G]** Launched **20 Aug 2024**, for `PutObject` and `CompleteMultipartUpload`, in
  **both general purpose and directory buckets**.
  "This feature is available at no additional charge in all AWS Regions, including the
  AWS GovCloud (US) Regions and the AWS China Regions."
  — [What's New, 2024-08-20](https://aws.amazon.com/about-aws/whats-new/2024/08/amazon-s3-conditional-writes/)
- **[G]** Extended to `CopyObject` in **Oct 2025** —
  [What's New, 2025-10](https://aws.amazon.com/about-aws/whats-new/2025/10/amazon-s3-conditional-write-functionality-copy-operations/);
  the User Guide now lists `PutObject`, `CompleteMultipartUpload` and `CopyObject`.
- **[G]** The header **expects the `*` (asterisk) character** and nothing else.
  — [API_PutObject, If-None-Match](https://docs.aws.amazon.com/AmazonS3/latest/API/API_PutObject.html)
- **[G]** Requires **AWS Signature Version 4**: "To use conditional writes, you must use
  AWS Signature Version 4 to sign the request."
  — [User Guide, Conditional writes](https://docs.aws.amazon.com/AmazonS3/latest/userguide/conditional-writes.html)
- **[G]** Requires only the `s3:PutObject` permission (unlike `If-Match`, which also
  needs `s3:GetObject`). Same source.
- **[G]** **Not supported on S3 on Outposts.**
  — [API_PutObject](https://docs.aws.amazon.com/AmazonS3/latest/API/API_PutObject.html)

### Atomicity across concurrent writers — the load-bearing guarantee

**[G]** The sentence quoted in the verdict is the whole ballgame:

> "If multiple conditional writes or copies occur for the same object name, the first
> write operation to finish succeeds. Amazon S3 then fails subsequent writes with a
> `412 Precondition Failed` response."

Note the precise wording: *the first write operation to **finish***. The order is
decided by completion at S3, not by request issue time, not by client clock, and not by
`LastModified`. AWS does not qualify this with "usually" or "in most cases". This is a
compare-and-set on the existence of the key.

### Outcomes

| Situation | Status | Notes |
|---|---|---|
| Key absent → write lands | `200 OK` | **[G]** |
| Key already present | `412 Precondition Failed` | **[G]** the normal "you lost the race" answer |
| Concurrent delete beat the write | `409 ConditionalRequestConflict` | **[G]** "On a 409 failure, retry the upload." |
| Versioned bucket, current version is a delete marker | `200 OK` | **[G]** treated as absent |
| Versioned bucket, live current version exists | `412` | **[G]** |
| A conditional `PUT` landed mid-MPU, then `CompleteMultipartUpload` | `412` | **[G]** MPU in progress is invisible to conditional writes |

Sources: [Conditional write behavior](https://docs.aws.amazon.com/AmazonS3/latest/userguide/conditional-writes.html),
[API_PutObject](https://docs.aws.amazon.com/AmazonS3/latest/API/API_PutObject.html).

**412 vs 409 mean different things and must be handled differently.** A `412` is a
genuine, settled loss: someone else's record occupies that key, so re-read and rebase.
A `409` is *not* a verdict — AWS explicitly says to **retry the upload**, because the
state was in flux (a concurrent delete). Collapsing the two into one "conflict" branch
would be a bug: retrying a 412 loops forever, and rebasing on a 409 discards work
needlessly.

### Cost

**[G]** Conditional writes carry no premium, but **failed requests are still billed**:

> "There is no additional charge for conditional reads, conditional writes or conditional
> deletes. You are only charged existing rates for the applicable requests, **including
> for failed requests**."
> — [Conditional requests](https://docs.aws.amazon.com/AmazonS3/latest/userguide/conditional-requests.html)

So each lost race costs one PUT. Given the map's "infrequent writes, low concurrent-write
probability" premise this is negligible, but it does mean an unbounded retry loop is a
billing risk as well as a liveness one — cap the retries.

### Versioning

**[G]** `If-None-Match` "only applies to the current version of an object in a version
bucket" ([User Guide](https://docs.aws.amazon.com/AmazonS3/latest/userguide/conditional-writes.html)).
Versioning does **not** weaken the guarantee, but note the interaction: without
conditional headers, a versioned bucket accepts *all* concurrent writes and stores every
one of them —

> "When you enable versioning for a bucket, if Amazon S3 receives multiple write requests
> for the same object simultaneously, it stores all versions of the objects."
> — [API_PutObject](https://docs.aws.amazon.com/AmazonS3/latest/API/API_PutObject.html)

i.e. versioning alone gives you a *fork*, not a winner. Conditional writes are what pick
one. For our purposes versioning is orthogonal: useful as an anti-footgun backstop, not
as the arbitration mechanism.

### Enforcing it bucket-wide

**[G]** A bucket policy can *require* the header, via the `s3:if-none-match` /
`s3:if-match` condition keys, so a buggy or old client physically cannot overwrite a
committed record — [Enforce conditional writes](https://docs.aws.amazon.com/AmazonS3/latest/userguide/conditional-writes-enforce.html).
This is attractive for an append-only chain: it turns "records are immutable" from a
convention into a bucket-enforced invariant.

Caveats, both documented on that page:
- Multipart uploads need `s3:ObjectCreationOperation` in the policy to exempt
  `CreateMultipartUpload` / `UploadPart` / `UploadPartCopy`, which cannot carry
  conditional headers.
- With such a policy in force, **copy operations into the bucket break**: `CopyObject`
  without the header fails `403 Access Denied`, and *with* the header fails
  `501 Not Implemented`. That would block a future server-side compaction step that
  used `CopyObject` — worth remembering against the batching/compaction constraint in #1.

---

## 2. `If-Match` on `PutObject`

- **[G]** Launched **25 Nov 2024** for `PutObject` and `CompleteMultipartUpload`, in
  general purpose and directory buckets, all AWS Regions, no additional charge —
  [What's New, 2024-11-25](https://aws.amazon.com/about-aws/whats-new/2024/11/amazon-s3-functionality-conditional-writes/).
- **[G]** Semantics: the write succeeds (`200 OK`) only if an object with that key exists
  *and* its ETag equals the supplied value; ETag mismatch gives `412 Precondition Failed`;
  a concurrent operation gives `409 ConditionalRequestConflict` ("On a 409 failure you
  should fetch the object's ETag and retry the upload"); and if there is no current
  version, or the current version is a delete marker, the operation fails **`404 Not
  Found`** — [User Guide](https://docs.aws.amazon.com/AmazonS3/latest/userguide/conditional-writes.html),
  [API_PutObject](https://docs.aws.amazon.com/AmazonS3/latest/API/API_PutObject.html).
- **[G]** Needs **both** `s3:PutObject` and `s3:GetObject`.
- **[G]** Conditional **deletes** also exist (`DeleteObject` / `DeleteObjects`, `If-Match`
  with an ETag or with `*`) —
  [Conditional deletes](https://docs.aws.amazon.com/AmazonS3/latest/userguide/conditional-deletes.html).
  Not needed by an append-only design, but it closes the loop if a repair path ever
  wants a guarded delete.

### `If-Match` is documented *more weakly* than `If-None-Match` — this is the key nuance

The decisive first-writer-wins sentence —

> "If multiple conditional writes or copies occur for the same object name, the first write
> operation to finish succeeds. Amazon S3 then fails subsequent writes with a `412
> Precondition Failed` response."

— appears on the User Guide page **only under the `If-None-Match` heading**. The `If-Match`
subsection has no equivalent serialization sentence. Three further asymmetries point the
same way:

- **[ND]** `API_PutObject`'s standing warning ("Amazon S3 is a distributed system. If it
  receives multiple write requests for the same object simultaneously, it overwrites all but
  the last object written. However, Amazon S3 provides features that can modify this
  behavior:") lists **Object Lock, `If-None-Match`, and S3 Versioning — `If-Match` is not in
  that list.**
- **[ND]** AWS never uses the words "atomic" or "compare-and-swap" for `If-Match` in the
  documentation. The nearest thing is announcement prose ("reliably offloading compare and
  swap operations to S3"), which is marketing copy, not a spec.
- **[ND]** The Aug 2024 `If-None-Match` announcement names GovCloud and the China Regions
  explicitly; the Nov 2024 `If-Match` announcement says only "all AWS Regions".

So mutual exclusion under `If-Match` is clearly *intended* and almost certainly *true*, but
**a written guarantee that at most one of N concurrent `If-Match` writes succeeds is not
documented.** Under this note's own rule, that puts `If-Match` in the "happens to work"
column and `If-None-Match: *` in the "guaranteed" column. **That asymmetry, more than
anything else, is why the commit protocol should be built on key-creation, not on ETag CAS.**

### Why `If-Match` is the wrong tool here anyway

It is compare-and-swap on a *mutable* pointer; our records are immutable and write-once,
which is exactly what `If-None-Match: *` expresses. `If-Match` would only enter the picture
if the design grew a mutable "chain head pointer" object — which would add a second, weaker
authority alongside the first, for no gain, since the head is already derivable by listing
(§4 guarantees the listing is complete).

If a head-pointer object is ever proposed anyway, three traps are documented:

- A `PutObject` with `If-Match` against a **nonexistent** key returns **`404 Not Found`**,
  not `412`. A CAS loop must therefore branch on **three** failures — 412, 409 and 404 —
  not two.
- **[ND]** `If-Match: *` on `PutObject` is undocumented (it is documented only for
  `DeleteObject`/`DeleteObjects`). Do not use it.
- An ETag is only an MD5 for single-part, non-SSE-KMS/SSE-C objects. `If-Match` must always
  use an ETag *read back from S3*, never one computed locally.

### Documentation quality caveat

Worth recording, because it bounds how much any of this can be leaned on: the error code
**`ConditionalRequestConflict` has no entry in S3's canonical error-code list** at all. It
appears only in prose in the `If-Match`/`If-None-Match` header descriptions, and the User
Guide and API Reference disagree on its name ("`409 Conflict`" vs
"`409 ConditionalRequestConflict`"). The XML `<Code>` a client will actually receive is
therefore **[ND]**. Any client-side error handling must match on the **HTTP status**
(412 / 409 / 404), not on the error-code string. Relatedly, the consistency-model page
has still not been updated for conditional writes — it continues to say "you must build an
object-locking mechanism into your application" without cross-referencing them.

---

## 3. `LastModified`

### What it is

- **[G]** Server-assigned and **not client-settable**. The User Guide classes it as
  *system controlled*: "Metadata such as the object-creation date is system controlled,
  which means that only Amazon S3 can modify the date value", and its table row for
  `Last-Modified` answers "Can user modify the value?" with **No** —
  [Working with object metadata](https://docs.aws.amazon.com/AmazonS3/latest/userguide/UsingMetadata.html).
  Confirmed negatively by the API: `PutObject`'s request syntax has no `Last-Modified`
  and no `x-amz-*` date-override header.
- **[G]** Defined as "The object creation date or the last modified date, whichever is the
  latest." (same page).
- **[G]** Notably, a successful `PutObject` response does **not** return `Last-Modified`
  at all ([API_PutObject](https://docs.aws.amazon.com/AmazonS3/latest/API/API_PutObject.html)
  response syntax) — so a writer cannot even learn its own record's timestamp without a
  second request. That alone makes it awkward as a protocol primitive.

### Resolution

Two wire forms, and neither helps:

- XML (`ListObjectsV2` → `Contents.LastModified`, `ListObjectVersions`, `CopyObjectResult`)
  is typed only as bare **"Timestamp"**
  ([`Object` data type](https://docs.aws.amazon.com/AmazonS3/latest/API/API_Object.html)),
  rendered ISO8601 with a millisecond field. **Every example across the S3 API Reference
  has a zero millisecond field** — `2009-10-12T17:50:30.000Z`, `2013-09-17T18:07:53.000Z`,
  etc. ([API_ListObjectsV2](https://docs.aws.amazon.com/AmazonS3/latest/API/API_ListObjectsV2.html)).
- The HTTP `Last-Modified` header on `GetObject`/`HeadObject` is documented with one
  line — "Date and time when the object was last modified" — and **no type, format or RFC**.
  The samples are RFC 1123 `HTTP-date`, i.e. whole seconds:
  `Last-Modified: Sun, 1 Jan 2006 12:00:00 GMT`
  ([API_HeadObject](https://docs.aws.amazon.com/AmazonS3/latest/API/API_HeadObject.html)).

**[ND] AWS documents no precision for `LastModified` anywhere, and never states that the
millisecond field carries information.** Treat it as second-resolution. Sub-second content
is neither promised nor forbidden.

### Ordering — the crux

**[ND] AWS documents no ordering guarantee for `LastModified`. None.** Not monotonicity,
not uniqueness, not cross-key order, not any claim that it reflects durable commit order.

Three pieces of documented context make clear this is deliberate, not an oversight:

1. **Listings are ordered by key, never by time.** "For general purpose buckets,
   `ListObjectsV2` returns objects in lexicographical order based on their key names"
   — and for directory buckets, not even that
   ([API_ListObjectsV2](https://docs.aws.amazon.com/AmazonS3/latest/API/API_ListObjectsV2.html)).

2. **Where a timestamp does decide a winner, it is internal and explicitly unpredictable.**
   The consistency section says "If two PUT requests are simultaneously made to the same
   key, the request with the latest timestamp wins", but immediately disclaims any
   client-observable meaning: "Amazon S3 internally uses last-writer-wins semantics to
   determine which write takes precedence. **However, the order in which Amazon S3 receives
   the requests and the order in which applications receive acknowledgments cannot be
   predicted** because of various factors, such as network latency. … The best way to
   determine the final value is to perform a read after both writes have been acknowledged."
   — [Welcome.html#ConsistencyModel](https://docs.aws.amazon.com/AmazonS3/latest/userguide/Welcome.html#ConsistencyModel).
   Crucially, that internal timestamp is never stated to be the exposed `LastModified`.

3. **Where AWS *does* ship an ordering primitive, it pointedly is not a timestamp — and it
   is per-key only.** Event notifications carry an opaque `sequencer`: "Event notifications
   aren't guaranteed to arrive in the same order that the events occurred… If you compare
   the `sequencer` strings from two event notifications on the same object key, the event
   notification with the greater `sequencer` hexadecimal value is the event that occurred
   later. **You can't use the `sequencer` key value to determine the order for events on
   different object keys.**"
   ([Event message structure](https://docs.aws.amazon.com/AmazonS3/latest/userguide/notification-content-structure.html)).
   S3 Metadata tables carry an analogous per-key `sequence_number`
   ([Metadata tables schema](https://docs.aws.amazon.com/AmazonS3/latest/userguide/metadata-tables-schema.html)).

That AWS built two separate opaque per-key sequence tokens, and never told you to sort by
time, is the strongest available signal: **timestamps are not an ordering mechanism in S3,
by design.**

| Question about `LastModified` | Answer |
|---|---|
| Ordered across concurrent PUTs to **different keys**? | **[ND]** — and explicitly ruled out for the analogous `sequencer` |
| Ordered across concurrent PUTs to the **same key**? | **[ND]** |
| Monotonic? | **[ND]** |
| Unique? | **[ND]** — and second-resolution rendering makes collisions structurally likely |
| Reflects durable commit order? | **[ND]** — docs say receive/ack order "cannot be predicted" |

### Two further traps

- **[G]** Multipart uploads: "For multipart uploads, the object creation date is the date of
  **initiation** of the multipart upload" — combined with "creation date *or the last
  modified date, whichever is the latest*", the value for a completed MPU object is
  genuinely ambiguous in the docs. **[ND]** whether it ends up being the
  `CreateMultipartUpload` or the `CompleteMultipartUpload` time.
- **[ND]** What a cross-region-replication replica's `LastModified` is set to was not
  established from a primary source.

**Conclusion: `LastModified` cannot be the authority.** It is unordered by documentation,
whole-second on the wire, ambiguous for MPU, unavailable in the PUT response, and truncated
to seconds by our own client library besides. Any tie-break built on it would be a
coin-flip dressed as a rule — and the failure mode is a silently forked chain, which is
exactly the class of error the `state_fingerprint` exists to catch but which the protocol
should never create in the first place.

---

## 4. Consistency model

**[G] Strong read-after-write, everywhere, including LIST.** Since 1 Dec 2020:

> "After a successful write of a new object or an overwrite of an existing object, any
> subsequent read request immediately receives the latest version of the object. **S3 also
> provides strong consistency for list operations**, so after a write, you can immediately
> perform a listing of the objects in a bucket with all changes reflected."
> — [What's New, 2020-12-01](https://aws.amazon.com/about-aws/whats-new/2020/12/amazon-s3-now-delivers-strong-read-after-write-consistency-automatically-for-all-applications/)

The current User Guide states the operative rule:

> "**Any read (GET or LIST request) that is initiated following the receipt of a successful
> PUT response will return the data written by the PUT request.**"
> — [Welcome.html#ConsistencyModel](https://docs.aws.amazon.com/AmazonS3/latest/userguide/Welcome.html#ConsistencyModel)

with the worked example "A process writes a new object to Amazon S3 and immediately lists
keys within its bucket. **The new object appears in the list.**" The same section covers
HEAD, ACLs, Object Tags and object metadata, and adds that "**Updates to a single key are
atomic**… you will get either the old data or the new data, but never partial or corrupt
data." Applies in all AWS Regions including GovCloud and the China Regions.

**What this buys the design.** After a successful conditional `PUT` of a record, a client's
own subsequent `ListObjectsV2` of the chain prefix is guaranteed to include it. So chain-head
discovery by listing is sound — no polling-for-visibility loop, no "wait a bit" hack. This is
what makes an S3-only append-only log viable at all.

**What it does not buy.**
- **[G]** Strong consistency governs *visibility*, not *ordering*. It says nothing about the
  relative order of two writes by different clients.
- **[ND]** No sentence enumerates which *fields* of a listing entry are strongly consistent.
  That `Contents.ETag`/`Size`/`LastModified` are those of exactly the version just written
  follows from "object metadata … are strongly consistent" plus the announcement's "with all
  changes reflected", but is nowhere spelled out. This matters little for us, since key
  presence is what the protocol reads.
- **[G]** **Bucket configuration remains eventually consistent** — notably, "If you enable
  versioning on a bucket for the first time, it might take a short amount of time for the
  change to be fully propagated. We recommend that you wait for 15 minutes after enabling
  versioning before issuing write operations". Relevant only to bucket provisioning, but a
  real trap for an integration test that creates a bucket and immediately writes.

### For contrast: no conditional header, no defined winner

**[G]** "Amazon S3 is a distributed system. **If it receives multiple write requests for the
same object simultaneously, it overwrites all but the last object written.**"
— [API_PutObject](https://docs.aws.amazon.com/AmazonS3/latest/API/API_PutObject.html), which
then names the three features that modify this: Object Lock, `If-None-Match`, and versioning.

**[G]** "Amazon S3 does not support object locking for concurrent writers… If this is an
issue, you must build an object-locking mechanism into your application. Updates are
key-based. **There is no way to make atomic updates across keys.**"
— [Welcome.html](https://docs.aws.amazon.com/AmazonS3/latest/userguide/Welcome.html#ConsistencyModel)

Two consequences worth carrying into the design session: a plain overwrite silently destroys
a record, so the append-only property must be enforced (bucket policy, §1) rather than
assumed; and **atomicity is per-key only** — no protocol step may require two objects to
change together.

---

## 5. MinIO and other S3-compatible implementations

### Portability summary

| Implementation | `If-None-Match: *` on `PutObject` | Evidence |
|---|---|---|
| AWS S3 | **Yes, guaranteed** | User Guide / API Reference (§1) |
| MinIO ≥ `RELEASE.2024-05-07T06-41-25Z` | Yes — but see caveats | source + PR; **partly undocumented** |
| Cloudflare R2 | Yes, documented | [R2 S3 API](https://developers.cloudflare.com/r2/api/s3/api/), [release notes](https://developers.cloudflare.com/r2/platform/release-notes/) |
| moto ≥ 5.0.15 | Yes | [moto CHANGELOG](https://raw.githubusercontent.com/getmoto/moto/master/CHANGELOG.md) |
| LocalStack | Implemented in source; **docs unverified** | `localstack-core/.../s3/provider.py` |
| Google Cloud Storage XML API | **No** | [Request preconditions](https://docs.cloud.google.com/storage/docs/request-preconditions) — `If-Match`/`If-None-Match` are "Applicable for requests that retrieve data"; create-if-absent exists only as the Google-specific `x-goog-if-generation-match: 0`, which no S3 SDK emits |
| Backblaze B2 S3 API | **Not documented** | [S3 PutObject apidocs](https://www.backblaze.com/apidocs/s3-put-object) lists no conditional headers either way |

### MinIO specifics

- **Supported since `RELEASE.2024-05-07T06-41-25Z`** — the release that added wildcard ETag
  support ([PR #19682](https://github.com/minio/minio/pull/19682): "This supports '*' as per
  behavior to comply with AWS S3 behavior for - 'If-Match: *' - 'If-None-Match: *'").
  Conditional PUT itself landed earlier ([PR #16551](https://github.com/minio/minio/pull/16551),
  Feb 2023) but required an exact ETag. **Older MinIO silently overwrites.**
- **Official compatibility page confirms the headers**, listing `If-None-Match` for
  `PutObject` among others —
  [AIStor S3 API compatibility](https://docs.min.io/aistor/developers/s3-api-compatibility/).
  But that page never mentions the `*` wildcard, the `412` status, or "Precondition": those
  are established only from the PR, the blog and the source. **The exact semantics we depend
  on are undocumented by MinIO.**
- **412 only, never 409.** MinIO has no `409 ConditionalRequestConflict` in its error table
  at all. Retry logic keyed on 409 is dead code against MinIO — which is fine, provided the
  client treats "no 409" as normal rather than assuming AWS's full taxonomy.
- **Trap: send a bare `*`, never a quoted `"*"`.** MinIO tests for the wildcard *before*
  stripping quotes, so `If-None-Match: "*"` is compared as a literal ETag, never matches, and
  **the PUT silently overwrites** — precisely
  [issue #20346](https://github.com/minio/minio/issues/20346), closed as working-as-intended;
  fixed client-side in `minio-go` v7.0.72. A silent overwrite is the single worst failure mode
  for an append-only chain, so this must be covered by an explicit integration test.
- **Serious: conditional PUTs were ignored under lost read quorum.**
  [Issue #21603](https://github.com/minio/minio/issues/21603) (Sep 2025): "A conditional put
  with if-none-match is accepted if the object doesn't exist, the version doesn't exist, **or
  read quorum can't be reached**. Therefore, when there is not read quorum, we may overwrite
  an existing value with a value intended to be used only if there is no existing value."
  Fixed by [PR #21653](https://github.com/minio/minio/pull/21653) — **merged to master only,
  after the last tagged community release** (`RELEASE.2025-10-15T17-29-55Z`).
- **`minio/minio` now declares itself unmaintained.** The master `README.md` states "THIS
  REPOSITORY IS NO LONGER MAINTAINED." and that the community edition is source-only with no
  pre-compiled binaries; fixes flow to AIStor. **So the read-quorum correctness fix is in no
  released community binary, and none is coming.**

**Read this correctly.** MinIO's first-writer-wins is *implemented*, not *specified*, and its
one known correctness bug is exactly the failure our protocol cannot tolerate — a lost
conditional check under degraded quorum, i.e. a silent fork. That is an argument about
self-hosted *production* deployments, not about testing. It does **not** affect the map's
test strategy: the in-process fake behind the LazyFiles interface can make `put_if_absent`
trivially atomic (a single-threaded dictionary insert), which is a *stronger* and more
deterministic guarantee than any real store. MinIO is only needed if self-hosting is a
supported deployment target — and if it is, that should be a stated, caveated support tier,
not an assumed equivalence with AWS.

---

## 6. The LazyFiles / rclone gap

This is the finding with the most immediate consequence, and it is about *our* stack,
not S3.

`LazyFiles.jl` does not speak S3 over HTTP. It shells out to **rclone**
(`/Users/jonalmeriksen/biome/LazyFiles.jl`, `src/LazyFiles.jl`):

```julia
r = _with_rclone(config) do make_cmd
    _run(make_cmd(`copyto --s3-no-check-bucket -- $local_file $RCLONE_REMOTE:$bucket/$name`); verbose)
end
```

Three consequences for a conditional-write commit protocol:

1. **No conditional-write path.** `s3_upload` accepts no headers and no precondition
   argument, and rclone's S3 backend documents no `If-None-Match` / `If-Match` support
   ([rclone S3 docs](https://rclone.org/s3/)). rclone does have a generic
   `--header-upload` flag ("Set HTTP header for upload transactions", `rclone help flags`,
   v1.65.2), but whether an injected `If-None-Match` is included in the SigV4 signature —
   which AWS **requires** for conditional writes — is **[unverified]**. If it is not
   signed, expect either `SignatureDoesNotMatch` or, far worse, a silently ignored
   precondition. **This must be tested against real S3 before any design depends on it.**

2. **rclone retries by default**, and the defaults are aggressive: `--retries` 3 and
   `--low-level-retries` 10 (`rclone help flags`, v1.65.2). A retry of a `PUT` that
   actually succeeded but whose response was lost would come back `412` — *indistinguishable
   from a genuine race loss*. A client would then wrongly conclude it lost, rebase, and
   re-commit an already-committed transaction. Any conditional-write path must disable
   rclone's retries and own the retry policy itself, or bypass rclone entirely.

3. **LazyFiles discards sub-second time anyway.** `_parse_modtime` truncates to 19
   characters, i.e. whole seconds, and the docstring commits to it: "second resolution is
   enough to order and poll listings." So even the weakest timestamp-arbitration scheme is
   unavailable through the current API without a change. (Given §3, that is no loss.)

**The likely conclusion for #8**: LazyFiles needs a real conditional-write primitive —
either an rclone path proven to sign the header, or a native SigV4 `PutObject` for this
one operation. A `put_if_absent(...) -> Bool`-shaped function (or one that raises a
distinguishable `PreconditionFailed`) is the interface the commit protocol wants; it also
maps cleanly onto the in-process fake backend, since "insert into a dict if the key is
absent" is trivially atomic in-process.

---

## 7. Open risks

Ordered by how much they could change the design.

1. **Can we even send the header? (blocking, testable now)**
   Whether `rclone --header-upload 'If-None-Match: *'` reaches S3 *inside the SigV4
   signature* is unverified. AWS requires SigV4 for conditional writes. Two bad outcomes are
   possible, and one is silent: a signature error (loud, fine) or a dropped/unsigned header
   that S3 ignores (**silent overwrite of a committed record**). Until this is answered
   empirically against real S3, the commit protocol has no proven transport. This is the
   first thing the next session should resolve, and it is cheap: one bucket, two PUTs to the
   same key, check for a 412. Feeds #8.

2. **The retry/idempotence hazard (design-level, not just implementation)**
   rclone retries by default (`--retries 3`, `--low-level-retries 10`). A `PUT` that succeeded
   but whose acknowledgement was lost will, on retry, return `412` — **indistinguishable from
   losing a race.** The client then rebases and re-commits a transaction that is already in
   the chain, i.e. applies it twice. This is not fixed by turning off rclone's retries alone,
   because the network can lose an ack regardless. The protocol needs to make a losing writer
   *check whether the record now at that key is its own* (compare the record hash) before
   concluding it lost. Worth writing into the commit-protocol ADR explicitly.

3. **Content-addressed keys make #2 tractable — but interact with key layout**
   If the key embeds the record's own hash, "did I win, or was that me?" is answered by a
   single `HEAD`. If the key is a bare sequence number, it is not. This is a genuine coupling
   between the key-naming decision and the retry-correctness decision, and the two tickets
   should not be decided independently.

4. **MinIO as a supported deployment target (scoping decision)**
   If self-hosting is in scope, the design inherits: undocumented wildcard semantics, no 409,
   the quoted-`"*"` silent-overwrite trap, and an unfixed-in-any-release read-quorum bug in a
   now-unmaintained repository (§5). Recommend either declaring MinIO explicitly unsupported
   for v1, or supporting it as a caveated tier with a documented minimum version and a startup
   self-check that verifies a second conditional PUT to the same key actually gets a 412.

5. **Bucket-policy enforcement vs. future compaction (forward-compat conflict)**
   Enforcing `s3:if-none-match` bucket-wide would make record immutability a bucket invariant
   rather than a client convention — very attractive. But it **breaks `CopyObject` into the
   bucket entirely** (403 without the header, 501 with it, §1). Since the map names
   batching/compaction as a forward-compat constraint and `CopyObject` is the natural
   server-side tool for it, this trade-off should be decided deliberately, not stumbled into.

6. **`409` handling is required for correctness but hard to test**
   AWS documents 409 on `If-None-Match` only for the concurrent-delete case. An append-only
   chain never deletes, so 409 *should* be unreachable — but the API Reference's wording is
   broader ("If a conflicting operation occurs during the upload"), the error code is absent
   from AWS's canonical error list, and the User Guide and API Reference disagree on its name
   (§2). Handle it (bounded retry, distinct from 412), match on **HTTP status not error
   string**, and do not expect to exercise it in tests.

7. **Unresolved documentation gaps (low impact, recorded for honesty)**
   - **[ND]** Whether a completed multipart upload's `LastModified` is the initiation or the
     completion time. Irrelevant if records are small enough to be single-part PUTs — worth
     confirming that assumption holds, including after compaction produces large batch objects.
   - **[ND]** Any interaction between conditional writes and cross-region replication —
     entirely absent from AWS docs. Do not assume conditional writes mean anything across a
     replicated pair; if multi-region is ever considered, this is unexplored ground.
   - **[ND]** Whether `Contents.ETag`/`LastModified` in a listing are strongly consistent
     field-by-field. Immaterial while the protocol only reads key *presence* — but it becomes
     material if chain-head discovery ever starts reading listing metadata rather than keys.

### What this research does *not* answer

Which key layout to use, how a losing writer rebases a transaction, and what happens to the
`state_fingerprint` on retry. Those are commit-protocol design questions; this note only
establishes that S3 can give a truthful, documented answer to "who won" — and that the answer
must be asked with `If-None-Match: *`, never inferred from a timestamp.
