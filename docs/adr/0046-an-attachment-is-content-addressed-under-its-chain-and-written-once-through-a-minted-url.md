---
status: accepted
---

# An attachment is content-addressed under its chain and written once through a minted URL

Every client holds the whole chain locally, by design. Some data a chain must
refer to is too large for that: immutable files of megabytes to gigabytes,
often over 4 MiB. A `bytes` cell would put them in every local copy, and a
gateway record is capped at 4 MiB (ADR-0028). They still need
the chain's retention, encryption, access policy and author attribution, at
sizes up to 5 GiB. Issue #90.

A downstream package cannot add them by itself: on a gateway bucket, locked or
not, only the gateway may PUT (`OnlyTheGatewayPuts`), and the gateway refuses
any key that is not a slot.

## Decision

An **attachment** is an immutable object stored at
`<prefix>/_attachments/<h>` (`_attachments/<h>` for the chain at the bucket
root), where `<h>` is the SHA-256 of its bytes in lowercase hex, 64 characters.
A row refers to one by holding `<h>` in a plain `text` column. What the
attachment means, and which columns refer to one, is the downstream package's
(ADR-0003). ChainTables promises only that a key and its bytes match and that
the key is written once.

**Per chain, not per bucket.** The policy rules decide who may write
attachments with no change, a chain stays one addressable place (ADR-0011), and
copying a chain copies its attachments. Deduplication across chains is given
up.

### The key

A key is an **attachment key** if it matches
`^(<prefix>/)?_attachments/[0-9a-f]{64}$`. The client refuses any hash that is
not 64 lowercase hex.

*Amended by #92*: **no chain prefix may have a segment `_attachments`.** The
client's `check_prefix` and the gateway's `prefix_problem` both refuse one; this
reverses the first version of this ADR, which let a chain at `x/_attachments`
stand because its slots (12 digits) cannot collide with an attachment of chain
`x` (64 hex). They cannot, but such a chain makes a key both an object and a
"directory" (`x/_attachments/<h>/_attachments/<h2>`), and it opened a gap in the
bucket policy: a slot key like `p/_attachments/<51 characters>/<12 digits>`
matches the attachment pattern `*/_attachments/<64 × ?>`, so
`DenyPresignedSlotPuts` misses it. With the segment refused, every key that
matches the pattern is under a prefix no client or gateway accepts. No chain had
such a prefix when it was refused.

The gateway classifies the key **before** the policy check, and checks an
attachment key against its `<prefix>`, to which `prefix_problem` also applies.
The key up to its last `/`, which is what the slot path uses, would be
`x/_attachments`: a writer of that nested chain could then write chain `x`'s
attachments, and root `_attachments/<h>` would never match rule `""`. Any other
key is handled as before.

### Writing on a gateway bucket

A function URL takes at most 6 MB per request, streaming or not, so the bytes
never pass through the gateway. Instead it gains a **mint route**. Every
gateway bucket uses it; a locked one adds the KMS and lock headers.

1. The client hashes the attachment and asks the mint route for its key, with
   a declared size: `POST /mint?key=<attachment key>&size=<bytes>`, signed
   like the slot route, with an empty body. The checksum is derived from the
   key and is not sent. A gateway without the route answers `400 bad_request`.
2. The gateway checks, first failure wins:
   1. the method, path, `key` and `size` are present and the body is empty
      → else `400 bad_request`;
   2. the caller is allowed on `<prefix>` → else `403 not_allowed`;
   3. the key is an attachment key with a prefix `prefix_problem` passes
      → else `400 not_a_slot`, which now means "neither a slot nor an
      attachment";
   4. the declared size is a decimal count of at most 11 digits (5 GiB has
      10; a leading zero is allowed) → else `400 bad_request`, refused before
      it is parsed, since Python's `int()` raises past about 4300 digits
      (#92); and at
      most 5 GiB, 5,368,709,120 bytes, S3's limit for one PUT → else
      `413 too_large`. A size of 0 is allowed.
3. The gateway HEADs the key.
   - **Present**: on a locked bucket it moves the version's COMPLIANCE
     retain-until to `now + N + margin` with `PutObjectRetention`, unless the
     current date is later. It replies `200 present`, and nothing is
     uploaded; on a locked bucket the reply carries `retain_until`. The
     current date is read with `GetObjectRetention`, never inferred from a
     refused `PutObjectRetention`, so a role that lacks the grant is
     `502 s3_refused`, not taken as "already later". A 4xx to
     `PutObjectRetention` is followed by a second `GetObjectRetention` (#92):
     a concurrent touch whose later date landed between the read and the put
     makes COMPLIANCE refuse the earlier one with 403. If the date read again
     is at or past the target, the reply is `200 present` with it; else the
     refusal stands, so a role lacking the grant is still `502 s3_refused`
     unless another writer has meanwhile retained the version long enough.
   - **Absent**: it replies with a presigned PUT, signed under its own role,
     whose signed headers are `x-amz-checksum-sha256` = the **base64** of the
     digest (as the slot put sends it, not the hex), `If-None-Match: *`,
     `Content-Type: application/octet-stream`, an `x-amz-tagging` that marks
     the object an attachment, `Content-Length` = the declared size, and on a
     locked bucket a slot write's SSE-KMS and COMPLIANCE headers with
     retain-until `now + N + margin`. boto3's presigner signs all of them from
     `put_object`'s own parameters (`ChecksumSHA256`, `IfNoneMatch`,
     `ContentLength`, ...) and adds no default checksum. The S3 client
     presigns with `addressing_style = "virtual"`: by default botocore signs
     the global host `<bucket>.s3.amazonaws.com`, which answers a young bucket
     outside us-east-1 with `307`. In us-east-1 virtual addressing alone
     still signs the global host, which the gateway refuses to hand out, so
     it also sets `us_east_1_regional_endpoint = "regional"`. The reply is
     `200 minted` with `url`, `expires` and `headers`: a flat JSON object of the lowercase names and
     values the URL signs, in botocore's own serialization, `host` excepted.
     The client reads it as it reads every reply, with no JSON parser; every
     value is ASCII with no quote. On a locked bucket it also carries
     `retain_until`. A failed HEAD, `GetObjectRetention` or
     `PutObjectRetention` is mapped as for the put: an S3 4xx is
     `502 s3_refused`, a 5xx or transport failure `502 s3_error`.
   - A slot route `PUT /` given an attachment key checks the policy against
     `<prefix>`, then answers `400 not_a_slot` naming the mint route.
4. The gateway logs the caller, the key, the declared size and which of the
   two it did.
5. Before sending a byte, the client checks the URL: https, host the chain's
   bucket on its **regional** endpoint, path the expected key, method PUT,
   and a query (the signature). That holds whatever AWS endpoint or
   addressing the chain reads with (path-style, FIPS, dual-stack): the
   upload goes where the gateway signed it. Only a store that is not AWS (a
   test's loopback) is expected at its own URL. It checks the headers too,
   each exactly once: `x-amz-checksum-sha256` the hash in base64,
   `if-none-match: *` and `content-length` the size. Without them S3 would
   store bytes no hash vouches for, overwrite the key, or take a body of
   another length; a header minted twice leaves it to S3 which one counts.
   Otherwise `GatewayMismatchError`, and nothing is sent. A URL elsewhere
   means the gateway fronts another bucket or region: pair the bucket with its
   own gateway. A URL with no query, or headers missing, wrong or repeated,
   mean the gateway's mint is broken: redeploy it. China regions (`cn-*`) are
   not supported: `is_aws` accepts `.amazonaws.com.cn`, but the expected host
   is `<bucket>.s3.<region>.amazonaws.com`, so every upload there is refused
   with `GatewayMismatchError` before a byte is sent. Supporting them cannot
   be tested live.
6. The client PUTs the bytes from the file with the reply's headers and no
   other `x-amz-*` header: S3 refuses one that is not signed (`403`, "headers
   present in the request which were not signed"). It follows no redirect. A
   `412` means another writer won the race; the client asks the mint route
   again, which finds it present and extends the retention. A second
   `minted` is `GatewayMismatchError`, as in `touch_attachment`: the gateway
   checks another bucket than its URLs write.
7. The client HEADs the key in the chain's bucket. Absent:
   `GatewayMismatchError`, as for a slot (ADR-0029).

**The margin** is the URL's lifetime plus one day, an allowance for the time
between upload and commit. **The URL's lifetime** grows with the declared size
from a 15-minute floor and is capped at what remains of the role's session,
since a presigned URL dies with the credentials that signed it. Lambda exposes
no expiry to the function, so the gateway records when its execution
environment started, at import, and caps the lifetime at 12 h minus the
environment's age minus 1 h; the hour covers the credentials being issued
somewhat before the import. Below the 15-minute floor it mints nothing and
refuses with `503 session_ending`, which the client retries, since another
environment may be younger. The present path is never capped: it mints no URL.
The lifetime is 15 minutes plus the declared size at 1 MiB/s, about 100 minutes
at 5 GiB, so a slow link does not rely on an upload surviving its URL's expiry.
The present path's margin uses the same uncapped lifetime of the declared size. The 12 h is probed, not
documented by AWS. S3 checks the
expiry when a request starts, so an upload that has begun survives it
(per AWS; not yet probed).

S3 enforces what the gateway cannot see. A body that does not hash to `<h>` is
refused (`400 BadDigest`). A missing or altered signed header, a body whose
length is not the declared size included, fails the signature (`403
SignatureDoesNotMatch`), so the 5 GiB check at mint binds the upload.
`If-None-Match` refuses every write after the first (`412`), so a URL used
again, as AWS allows until it expires, stores nothing more. An expired URL is
`403` "Request has expired", raised as `AttachmentURLExpiredError`: putting the
attachment again mints a new URL. The request runs as the
gateway role, so `OnlyTheGatewayPuts` and the lock-header denies hold
unchanged. The gateway checks no author and reads no content; attribution comes
from the record whose row holds the hash.

**The bucket policy denies a presigned PUT** (any `s3:authType` but
`REST-HEADER`: a presigned URL or a browser-form POST) to any key outside
`_attachments/<64 × ?>` and `*/_attachments/<64 × ?>` (`DenyPresignedSlotPuts`,
written by `deploy.sh`; `?` is one character in an IAM resource pattern). A
gateway bug can then never mint a working URL for a slot, which would bypass the
author check. It names `s3:PutObjectRetention` and `s3:PutObjectTagging` as well
as `s3:PutObject`, since S3 authorizes those too for a put carrying lock headers
or a tag. The role is denied every other action not signed in a header
(`DenyGatewayPresignedNonPuts`), and a locked bucket caps every retention at
N + 3 days (`DenyLongRetention`), so whatever signs as the role cannot lock an
object for longer (#92). The
pattern cannot spell "lowercase hex": a slot under a contrived prefix whose last
64 characters span a `/` (`p/_attachments/<51 characters>/<12 digits>`) still
matches. Such a prefix has the segment `_attachments`, which no client accepts
and the gateway refuses (#92, above), so no chain's slot is ever such a key. The role's
`s3:GetObject`, `s3:PutObjectTagging` and, on a locked bucket,
`s3:GetObjectRetention` are scoped to the same patterns; `s3:ListBucket`, so that
an absent key HEADs 404, is on the bucket.

### Writing on a plain bucket

A plain bucket, one with no gateway, takes the PUT directly, with the checksum
and `If-None-Match: *`; `412` is success. There is no retention to extend.

The difference is internal dispatch, `put_attachment(store, key, io)`, as for
`record_author(store)`, together with a streaming GET to a file.
`Testing.InMemoryObjectStore` gets both. The transport gains a streaming PUT
from a file and a streaming GET to a file. Neither holds the body in memory or
has a total timeout, since how long 5 GiB takes depends on the link: the
store's `timeout` is libcurl's stall window, seconds in which no byte moves,
after which the transfer is a `TransportError` with no status. No redirect is
followed: S3 redirecting a bucket's request means the region or host is wrong,
which a retry elsewhere would hide. `touch_attachment(store, key)` dispatches
the same way.

### Retention

On a locked bucket an attachment's retain-until is `now + N + margin`, set when
it is minted, and extended when a mint finds it present. It never gains a
second version. A row committed within the margin of the mint therefore never
outlives its attachment.

A row that reuses a hash must first call `touch_attachment(chain, hash)`, which
takes the mint route's *present* path and needs only the hash. ChainTables
cannot enforce that order, nor that an upload comes before its commit: it does
not know which columns hold references. Both are the downstream package's to
keep.

### The client surface

- `put_attachment(chain, path_or_io) -> hash` hashes, then mints and uploads.
  It takes a path or a seekable IO and refuses a non-seekable one: the hash
  must be known before the upload, and 5 GiB must not be held in memory.
  A retryable `TransportError` (ADR-0010's rule: no status, `5xx` with
  `503 session_ending`, `409`, `429`) runs the whole put again, up to the
  commit's four attempts and backoff. That is safe because a put whose upload
  landed finds the key present; the cost is that a failure partway through an
  upload sends the file again.
- `touch_attachment(chain, hash)` extends the retention of an attachment the
  chain's store holds, and fails if it is absent. It HEADs the key in the
  chain's bucket first: absent fails with no mint, and the HEAD's size is the
  declared size the present path's margin needs. On a gateway bucket it then
  mints, which must answer `present`; a `minted` reply is
  `GatewayMismatchError`, and nothing is uploaded. A plain bucket keeps no
  retention, so the HEAD is all. Retried as `put_attachment` is.
- `attachment(copy, hash) -> path` is the path of the cached file. It is
  fetched lazily, never on `sync!`, and nothing checks that a row of the copy
  refers to the hash.

### The cache

An attachment is cached at `cache_dir/attachments/<h[1:2]>/<h>`, inside the
record cache's directory beside the store namespaces (`cache_dir` defaults to
`…/chaintables/records`), shared by every chain and bucket. `record_path`
refuses a store whose `cache_namespace` is `attachments`, so the two never
meet. A directory beside `cache_dir` instead would put the cache at
`/attachments` for `CHAINTABLES_CACHE_DIR=/x`. Mirroring the key, as the record
cache does, would leave about 10 characters for `cache_dir` under ADR-0034's
budget; content addressing makes the files safe to share. The longest path
below `cache_dir`, a sidecar's temporary file, is 106 characters, under the
record cache's 198, so the record cache's budget binds first.

A download goes to `<h>.<16 hex>.part` beside its place, is checked against
`<h>` (else `AttachmentDigestError`, with the download deleted: at 5 GiB it is
not kept as evidence, as a record would be), and made read-only. Then the
sidecar `<h>.meta`, holding `"<size> <mtime>"`, is written to a `.tmp` and
renamed, and last the file is renamed into place. A rename keeps size and
mtime, so the file appearing is the commit: a sidecar without its file, or a
file without its sidecar, is an absent entry, filled again. On Windows, which
refuses to rename over a read-only file, the old one is removed first. An
entry another process completed meanwhile is kept. A `.part` an interrupted
download leaves is never swept; deleting it, or any entry, is always safe.

A read checks the file against the sidecar, not against the hash: hashing 5 GiB
on every read costs too much. That is weaker than the record cache's check
(ADR-0040), and `verify(copy; full = true)` makes up for it by hashing the
files. A file that differs from its sidecar is hashed, once, on that read. Two
processes filling one hash at once can pair one's sidecar with the other's
file, and a cache copied without its mtimes makes every entry differ; in both
the file hashes to `<h>`, and its sidecar is rewritten from it, `.tmp` and
rename, and the read goes on. Raising instead wedged the entry: every read in
every copy raised, and `verify` with them, until `repair!` or a delete. The hash
and the sidecar's size and mtime come from one open file, stat before and after
the hash, so a file renamed in meanwhile leaves only another mismatch, healed by
the next read. A file whose size or mtime changed while it was hashed is not
healed: a read raises `AttachmentCacheError`, since something other than
ChainTables writes the read-only cache, and `repair!` fetches it again. Every
file a fill renames in was hashed first, so no race heals a wrong file. A file
that does not hash to `<h>` is `AttachmentCacheError`, not fetched again in place as a
record is (ADR-0040): a re-fetch can be 5 GiB inside a read, and the store may
no longer hold the key. `verify(copy; full = true)` counts a file that hashes
right as sound whatever its sidecar says, and an entry that is gone as no
damage, since deleting one is always safe and the next read fetches it again;
it writes nothing. On Windows,
Julia opens a file without delete sharing, so while a heal, a `verify` or a
reader holds the file open, a concurrent fill's removal of the old file fails
and that fill raises; running it again settles it.

A shared file must not stand in for the chain's word, so the **first read of an
attachment through a copy HEADs its key in that chain's store**, even on a
cache hit, and records the hash as confirmed for the copy, as an empty file
`<copy>/confirmed/<h>` (ADR-0023); a miss is confirmed by its download. The
HEAD's size must be the cached file's. When it is not, one side is wrong, and the
cached file is hashed to say which: if it hashes to `<h>`, the store is wrong
(`AttachmentDigestError`); if not, the cache is (`AttachmentCacheError`), and
the hash is not confirmed either way. Raising `AttachmentCacheError` without
hashing would send a reader to `repair!`, which finds the file sound and changes
nothing, so the same error would come back every time. The hash costs a read of
the file, and only on a mismatch, which the protocol never produces. A copy
with no head has no chain to confirm against and is refused. Otherwise a file
cached from another chain, or by the uploader itself, would hide an attachment
this chain's store lacks, and every other client would fail. `verify(copy;
full = true)` and `repair!(copy)` cover only the hashes confirmed through the
copy, and `repair!` fetches them from its chain's store: it hashes each, heals
one that hashes right as a read does, fetches the rest, and counts both in its
report's `attachments_repaired`. `attachment` and `repair!` retry as
`put_attachment` does.

### Errors

Each has a message test (ADR-0020); the names are settled with the code.
`chain_id` is filled only by the calls on a local copy, `attachment` and
`repair!`: `put_attachment` and `touch_attachment` work on a `Chain`, whose id
is known only by reading the chain, which a write does not need.

- The file changed between hashing and upload: `AttachmentChangedError`, for
  S3's `BadDigest` on a minted URL and its `XAmzContentSHA256Mismatch` on a
  plain bucket's signed PUT.
- A mint refused: `WriteRefusedError`, now also raised by `put_attachment` and
  `touch_attachment`.
- A URL elsewhere or with no signature, minted headers missing, wrong or
  repeated, a key absent after the upload, a `412` whose second mint does not
  answer `present`, or a touch whose mint finds absent what the chain's bucket
  holds: `GatewayMismatchError`. The message says to redeploy the gateway for
  a URL with no signature or bad headers, else to pair the bucket with its own
  gateway.
- A URL that expired before the upload started: `AttachmentURLExpiredError`,
  carrying the gateway's `expires`; the message says to put the attachment
  again. The client does not mint again by itself: a fresh URL lives at least
  15 minutes, so an expiry means a stalled caller or a wrong clock.
- The attachment is absent from the chain's store, which is common once a
  retention ends: `AttachmentAbsentError`.
- A download that does not hash to `<h>`, or a cache hit whose HEAD gives a
  size other than that of a cached file that hashes to `<h>`:
  `AttachmentDigestError`, never retried.
- A damaged cache file: `AttachmentCacheError`, from a read or `verify(copy;
  full = true)`, including a cache hit whose HEAD gives another size and whose
  file does not hash to `<h>`, and a file that changed while a read hashed it.
  A read's message says to delete the file and
  its `.meta` and read again, not `repair!`: `repair!` covers only confirmed
  hashes, so on a copy that never confirmed `<h>` it would change nothing and
  the same error would come back.
- `attachment` on a store that lacks the hash: `AttachmentAbsentError`, whose
  message tells a reader that only someone holding the file can put it again.
  `repair!` raises it too, once, after finishing its pass, naming every
  confirmed hash the store no longer holds. It removes their markers once the
  pass has run to its end — a pass that raises before has removed none, so the
  next `repair!` names them again:
  keeping them would make every later `repair!` raise and stop at the first,
  and every `verify(copy; full = true)` fail, with nothing the reader can do.
- A gateway with no mint route: `WriteRefusedError` with `reason =
  "no_mint_route"`, recognised by the old gateway's `400 bad_request` text "is
  not the gateway's one route"; the message says to redeploy it. Any other
  `400` from the mint route is a `TransportError` carrying its code.

## Why a presigned PUT is right here when ADR-0028 refused it

ADR-0028 refused presigned PUTs for records on two grounds. The minter can check
the caller but not the record, and the author check needs the record's body.
And the minter could not enforce `If-None-Match`. An attachment has no author
field, and its key is fixed by its content, which S3 checks. `If-None-Match` is
a signed header, which S3 enforces like any other.

## Considered options

- **Chunks through the gateway**: split an attachment into 4 MiB chunks, each
  content-addressed, plus a manifest whose hash is the reference. One write
  path and no presigned URL, but about 1,300 calls for 5 GiB, base64 overhead,
  and reassembly on every read. Rejected.
- **A hole in the lock policy for attachment keys.** It loses the gateway's
  check of the caller and weakens the retention guarantees. Rejected.
- **A second locked bucket for attachments.** It duplicates
  `setup-locked-bucket.sh` and the policy, which then drift apart. Rejected.
- **Always PUT, with no `If-None-Match`.** A hash-named key can only hold
  identical bytes, so it is safe for the content. But a presigned URL works
  any number of times until it expires, and on a locked bucket each use is a
  new COMPLIANCE version nobody can delete; every reuse also uploads again.
  It would break ADR-0002/0012's write-once rule too. Rejected.
- **Skip the upload when the key is present, with no extension.** A row
  committed today could refer to an attachment whose retention ends next week.
  Rejected.
- **One key per bucket** (`_attachments/<h>` at the root for every chain):
  deduplication across chains, but a policy rule no longer decides who may
  write an attachment, and a chain is no longer one place. Rejected.
- **Multipart upload, for attachments over 5 GiB.** S3 gives only a composite
  SHA-256 for multipart, so it could not check that the bytes hash to `<h>`.
  Out of scope.
- **`_blobs`** as the reserved name. The glossary avoids "blob". Rejected.

## Consequences

- **ADR-0002 and ADR-0012 are amended in place**: attachments are written once
  too, by `If-None-Match`, but through a second write path, so
  `put_object_if_absent` is no longer the only write.
- **ADR-0010 is amended in place**: attachments use internal streaming put and
  get, not new verbs of the port, and are cached apart from the records, in
  `cache_dir/attachments/` beside the stores' namespaces, with a first read
  that asks the store.
- **ADR-0011 is amended in place**: `_attachments/<h>` is a reserved name the
  gateway admits.
- **ADR-0020's table** gains the new types; `WriteRefusedError` and
  `GatewayMismatchError` gain `put_attachment` and `touch_attachment`.
- **ADR-0028 is amended in place**: the gateway gains a second kind of write
  and the mint route; `not_a_slot`'s meaning and the order of classification
  and policy check change; presigned PUTs are refused for records and admitted
  for attachments.
- **ADR-0029 is amended in place**: the client checks a minted URL and HEADs
  after the upload.
- **ADR-0034 is amended in place**: the attachment cache path, and why it is
  not mirrored.
- **ADR-0023 is amended in place**: a copy's `confirmed/` directory.
- **ADR-0040 is not changed, but departed from**: a damaged attachment cache
  file raises rather than heals, for the reasons under "The cache".
- **ADR-0038 and ADR-0042 are amended in place**: an attachment's retention
  runs from its mint plus a margin and is extended on reuse. Deletion after a
  retention ends is a break-glass change, as for a record. Per-chain keys rule
  out a key-prefix lifecycle filter; the signed tag leaves a tag filter
  possible. The gateway role needs `s3:PutObjectTagging`.
- **What is not promised**: that a committed row refers to an attachment that
  exists. The reference is plain text, and after retention ends records and
  attachments are deleted independently.
- **Orphans are accepted.** An upload whose commit is lost is kept until its
  retention ends, and S3 attributes it to the gateway role. So any allowed
  writer can store up to 5 GiB per mint that no row refers to. The mint log
  names the caller. A rate limit or alarm is deferred.
- **The live gateway test (ADR-0030) proves**, on a locked bucket:
  - a wrong body is refused with `BadDigest`;
  - an omitted or altered signed header is refused;
  - a correct body is stored with COMPLIANCE retention, SSE-KMS and the tag;
  - a second PUT to the same URL is refused with `412`;
  - a mint of a present attachment moves its retain-until later and mints no
    URL;
  - a presigned PUT to a slot is denied;
  - `x/_attachments/<h>` is checked against `x`.

  `test/live/attachments.jl` (`run.sh attachments`) proves all but the slot
  item, which no gateway mints a URL for: `gateway/probe/attachment_probe.py
  slot` proves it with a URL signed under the gateway role. `attachment_probe.py
  policy` proves #92's statements: the retention cap, a presigned retention
  call, a presigned GET and a form POST, each signed under the gateway role.
- **Probed on 2026-10-28** (`gateway/probe/attachment_probe.py`, a locked
  bucket, URLs signed in Lambda under the gateway role, botocore 1.43.93):
  - a correct PUT is stored with COMPLIANCE, the key, the Bucket Key and the
    checksum; the same URL again, or a fresh URL for a present key, is `412`
    and leaves one version;
  - a wrong body is `400 BadDigest`;
  - an omitted `If-None-Match` or checksum, an altered retain-until, and a
    body one byte short of a signed `Content-Length` are each `403
    SignatureDoesNotMatch`; an unsigned `x-amz-meta-*` header is `403
    AccessDenied`;
  - a signed tag is `403` until the role holds `s3:PutObjectTagging`;
  - the lock-header denies apply to a presigned PUT;
  - an expired URL is `403 AccessDenied`, "Request has expired";
  - the default presigned host is global and answered `307` for a bucket a
    few minutes old;
  - a URL signed at a fresh execution environment's start was still valid
    after 11.25 h and refused with `400 ExpiredToken` at 12.08 h: the role's
    credentials last about 12 h from the environment's start. Lambda exposes
    no expiry to the function.
- **Proved on 2026-11-06** on the same bucket, redeployed with a `live/*`
  policy rule:
  - `run.sh attachments` passed, 53 of 53;
  - the probe's `slot` case: a URL signed under the gateway role, with every
    lock and KMS header, is `403 AccessDenied` "explicit deny in a
    resource-based policy" for a slot key and stores nothing, while the same
    headers for an attachment key in the same run are stored.
- **Still unverified**:
  - whether an upload that starts before its URL expires survives the
    expiry.
