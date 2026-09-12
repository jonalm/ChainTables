---
status: accepted
---

# ChainTables owns its S3 client and its record cache

ChainTables talks to S3 through four operations of its own, over an HTTP client of
its own, and caches transaction records in a directory of its own. It does not
depend on LazyFiles.jl.

The port is generic — keys and bytes, not slots and records:

```julia
abstract type AbstractObjectStore end

fetch_object(store, key)                    -> Vector{UInt8} | Nothing   # nothing ⟺ absent
put_object_if_absent(store, key, bytes)     -> PutOutcome
stat_object(store, key)                     -> ObjectMeta | Nothing
list_objects(store, prefix; start_after)    -> Vector{ObjectMeta}
```

There is **no delete**. ADR-0002 forbids a client removing anything under a chain
prefix, and a port without the operation makes that unrepresentable rather than
merely forbidden. The slot-to-key mapping lives above the port, in one function,
so the key layout can be redrawn without touching the transport.

## The chain decides a commit's outcome, not the HTTP status

Issue #5 and issue #8 both named one constraint the hardest thing this decision
had to satisfy: `412` must be available as a value, which the rclone CLI cannot
do — it exits `1` for a lost race and `1` for a broken socket, with
`PreconditionFailed` only as English on stderr.

That constraint does not exist. ADR-0002 already requires the committer to read
the slot back after a failed PUT, to tell a lost acknowledgement from a lost
race, and that read-back answers the whole question from chain state alone:

| The slot then holds | The commit outcome |
| --- | --- |
| our `transaction_hash` | success — only the acknowledgement was lost |
| a different `transaction_hash` | lost the race; raise, carrying identity only |
| nothing | the request never landed; retry, bounded |

So the transport owes the protocol only *the PUT succeeded* or *it did not*, plus
text for the error message. The read-back is promoted from a disambiguation to
**the authority**. Owning the client means we get a real status anyway, and
`PutOutcome` carries it — but nothing depends on it.

No status protects against a transport that silently *drops* the
`If-None-Match: *` header: that PUT simply succeeds and forks the chain. The
guard for that is a real-S3 integration test asserting the second conditional PUT
fails, which issue #8 has already measured once by hand.

## The transport

A vendored SigV4 signer over stdlib `Downloads`, `SHA` and `Base64` — no
dependency added. `Downloads.request(url; method, headers, input, throw=false)`
returns a response carrying `.status`, and libcurl does not retry on its own,
so ADR-0002's "transport-level retry must be off" is obtained rather than
configured. Vendoring matches ADR-0006's call on the CBOR encoder.

- **One request per port call.** The commit layer owns the retry loop, because
  ADR-0002's read-back has to happen *between* attempts and only the commit layer
  can perform it. Retry on connect failure, timeout, `5xx` and `409`; never on
  `412`, which is terminal; never on an auth `4xx`.
- **`409 Conflict` is a documented third outcome** of a conditional write — a
  delete landing on the key mid-flight — and AWS's guidance is to retry the
  attempt. It is not a lost race and must not be reported as one.
- **Virtual-hosted URLs**, `https://<bucket>.s3.<region>.amazonaws.com/<key>`.
  Path-style still works but is the deprecated direction, and a bucket name
  containing a dot breaks certificate matching under virtual-hosted, so such a
  name is rejected fail-fast with a message that says why.
- **Our own config** reads the same `AWS_*` variables and carries region, key id,
  secret, an optional session token, and an optional endpoint with a path-style
  flag. The endpoint field costs nothing now and is what the S3-compatible-store
  question will need.
- **`If-None-Match` need not be a signed header** (only `host` and `x-amz-*` are
  required), but signing every header we send is free and is what the reference
  implementations do.

## The record cache

Keyed by bucket and key under `first(DEPOT_PATH)/chaintables/records`,
overridable per chain and by `CHAINTABLES_CACHE_DIR` (ADR-0019 fixed the
default: depot-based is machine-wide and needs no dependency), so tests point at
a `mktempdir()`. Fetch to a unique temp file in the destination
directory, then `mv` it in, so an interrupted run never caches a truncated record
and concurrent fetches of one record do not clobber each other.

Two properties are load-bearing and are recorded as such:

- **A cached record is never re-validated, and that is correct** — not because
  keys are content-addressed, but because ADR-0002 gives every slot at most one
  record for all time, so a key's bytes are immutable by protocol. Any object
  whose key-to-bytes mapping could change must never be read through this cache.
- **Absence is never memoized.** A client polling a slot that is still empty must
  see the transaction record the moment it lands.

## Considered options

- **LazyFiles grows an `AbstractBlobStore` seam and an HTTP write path** — the
  ticket's option (a). Rejected once the seam moved: issue #5 argued for it mainly
  to make an in-process fake possible, and a port in ChainTables does that without a
  breaking change to a working package.
- **LazyFiles keeps the read path, we own only the writes** — two transports, two
  credential paths, two failure taxonomies, and the rclone version floor retained
  for reads alone.
- **LazyFiles keeps only its cache, reached through its own extension interface**
  by defining a blob type whose `fetch!` does our signed GET. This was the
  leading option and is the one the chosen answer differs from by a hair: it uses
  the genuinely extensible half of LazyFiles exactly as designed, and needs no
  changes to it either. It loses on the dependency — LazyFiles hard-depends on
  `Rclone_jll`, pinned to `1.74.3`, so every ChainTables install would download an
  rclone binary it never executes and inherit that artifact's platform matrix.
  Forty lines of cache is not worth it.
- **`AWS.jl`** can send arbitrary headers and return a status as a value, but
  carries sixteen direct dependencies, builds path-style URLs with no endpoint
  option, and wraps every request in a hardcoded four-attempt retry layer that
  cannot be disabled — the one thing ADR-0002 forbids.
- **`AWSS3.jl`** cannot send `If-None-Match` at all: `s3_put` builds its header
  dictionary internally and passes keyword arguments past it.
- **`CloudBase.jl`** has a clean, tested `awssign!`, but hard-depends on three
  jlls including `minio_jll`.
- **`HTTP.jl`** would work with `retry=false`, which is mandatory rather than
  optional: its default retryable set includes `409`, and it treats PUT as
  idempotent, so out of the box it would re-issue the very request whose
  ambiguity the read-back exists to resolve.

## Consequences

- **ChainTables has no non-stdlib dependency** — stdlib plus the vendored encoder
  and the vendored signer (ADR-0022; this ADR first said *reduce to SQLite.jl*).
  No rclone binary, no version pin inherited from another package, and nothing
  between the chain and the bytes on the wire that we did not write.
- **The rclone ≥ 1.74 floor is no longer ours.** Issue #8 found that system rclone
  1.65.2 cannot reach the test bucket (`400 MissingNamespaceHeader`). AWS
  documents `x-amz-bucket-namespace` as a CreateBucket header and states that
  applications need no change to use an account-regional bucket, so that failure
  was most likely rclone's own bucket check rather than the data plane. Either
  way it leaves ChainTables's transport, and the platform question inherits nothing.
- **Issue #6's `--no-session` requirement is retired for ChainTables.** It existed
  because LazyFiles never reads `AWS_SESSION_TOKEN`; a signer of our own signs
  `x-amz-security-token`, so aws-vault sessions, SSO and MFA all work.
- **The key layout is free of filename rules.** LazyFiles rejected `:`, the
  Windows reserved device names, and trailing dots and spaces in any cached key,
  because its cache path had to be portable across operating systems. Our cache
  keeps the same directory shape, so the rule may be worth keeping by choice for
  the same reason — but it is now a choice, not a constraint, and the bucket
  layout question owns it.
- **The test substrate premise changes shape.** The in-process fake implements
  *our* port, not LazyFiles' extension interface, and is a supported test double
  rather than method piracy. To be faithful rather than merely working it must:
  refuse `put_object_if_absent` on an existing key; return `nothing` for absent
  and raise for failure, never conflating them; return listings **shuffled**, so
  a test that relies on order fails; report whole-second `modified` values that
  can **tie**; and match prefixes by bytes.
- **Cold-start replay loses rclone's parallel bulk transfer.** Fetching many
  records now means many ordinary HTTP GETs. That matters only if cold start turns
  out to be download-bound, which is the performance-envelope question the map has
  parked.
- **MinIO cannot be the double for the one behaviour the commit protocol rests
  on**: it supports `If-None-Match` but rejects the `*` wildcard, closed upstream
  as working as intended. Cloudflare R2 honours it; Backblaze B2 documents no
  conditional-write support at all. This is a fact for the S3-compatible-store
  scope question, and it is why the faithful double is an in-process fake rather
  than a local S3 server.
- **Issue #5's twenty gaps mostly stop being gaps rather than getting fixed.**
  ETag is not needed anywhere — there is no `If-Match`, and ADR-0006 verifies a
  cached record by rehashing it. Delimiter listing is wanted only by a future
  compactor. `start_after` is ours to provide. The one finding that survives
  intact is the sharpest one, and it is now our own rule: a never-re-validated
  cache is safe only for objects whose bytes cannot change.
