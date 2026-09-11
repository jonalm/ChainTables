---
status: accepted
---

# v1 claims AWS S3 only, and the gate is on commit

S3SQLite v1 supports **AWS S3 general purpose buckets** and nothing else. A
client configured against any other object store warns at `open`, syncs and reads
normally, and **raises on commit** — unless the user has set
`assume_first_writer_wins = true`.

## Why the claim is this narrow

The commit protocol (ADR-0002) rests on one promise: a PUT carrying
`If-None-Match: *` creates the key or fails, and never overwrites. AWS documents
that promise, and issue #6 measured it live. Every other store offers weaker
evidence, or none:

- **Cloudflare R2** documents it. We have never run against it.
- **Google Cloud Storage**'s XML API cannot express it at all — create-if-absent
  exists only as `x-goog-if-generation-match: 0`, which no S3 client sends.
- **Backblaze B2** documents neither support nor refusal.
- **MinIO** implements it without specifying it; compares a quoted `"*"` as a
  literal ETag and so **silently overwrites** (minio#20346, closed as
  working-as-intended); ignored the precondition entirely whenever read quorum was
  lost (minio#21603, fixed in master only, after the last tagged community
  release); and now declares itself unmaintained.

A store that breaks the promise does not report an error. Both racing clients are
told they won, and the second record replaces the first in a slot ADR-0002
guarantees is written once. The damage is asymmetric, and neither half is
tolerable: a client that had already applied the lost record meets a **rewritten
chain** and, by ADR-0014, hard-errors forever with no repair path; a client that
never saw it adopts the survivor with no signal at all, and the committed
transaction record is simply gone.

So the default is refusal. A store we cannot name is not a store we warn about.

## What counts as AWS

Supported when S3SQLite builds the URL itself — ADR-0010's virtual-hosted form,
no endpoint configured — or when the configured endpoint's host ends in
`.amazonaws.com` or `.amazonaws.com.cn`. That admits the FIPS, dual-stack,
GovCloud and China endpoints, which are AWS and would otherwise be refused merely
for being spelled out. It is a suffix test on a host and not a security control:
the config is the user's own, and a user who wants past it has the override.

## The gate is on commit

`open` warns; it does not refuse. A fetch and a stat need no promise, so a client
that only reads is untouched by this question, and gating at open would force a
read-only mode into existence solely to escape a check that never applied to it —
a decision that belongs to the public API surface, not here. The refusal
therefore lands on the one operation that needs the guarantee, and lands **before
the local transaction opens**: nothing is applied, no slot is attempted, and
ADR-0009's window never starts.

The accepted cost is stated plainly: a reader against a broken store that
overwrote a slot it had not yet applied has no way to know. Verifying the chain
proves each record consistent with its parent, and the survivor of a silent
overwrite is exactly that.

## The override, and what it asserts

`assume_first_writer_wins = true` is a config field, set once, named for the
promise the user makes rather than for the rule it lifts. The commit-time message
names four things: the endpoint, the promise S3SQLite requires, the consequence
if the store breaks it (a second record in a written slot — a rewritten chain for
clients that applied the first, silent data loss for those that did not), and the
field that permits it.

The promise, in full, is the **minimum backend contract**, and it is the same
contract ADR-0010's in-process fake must satisfy to be faithful:

1. A PUT carrying a bare `If-None-Match: *` either creates the key or fails. It
   never overwrites an existing key, under any degraded condition.
2. That failure is reported as `412`. (`409` is a documented AWS outcome and is
   retried by the commit layer; a store that never emits one is fine.)
3. A quoted `"*"` is never sent — the header value is the bare asterisk.
4. A GET of a key a PUT has just created returns that object.

No rule concerns deletion: the object store port carries no delete verb
(ADR-0010), so the prohibition is unrepresentable rather than merely stated.

## No start-up self-test

The ticket proposed racing two conditional PUTs at open to prove the endpoint
honours the contract. Rejected. MinIO's quorum defect fires only when quorum is
degraded, so a healthy store passes the probe and breaks the promise later —
a pass proves the store was working, never that it is correct. The probe also
writes objects into the user's bucket to answer a question the user has already
answered by setting the override. False assurance is worse than none. Nothing in
the format forbids adding it later.

## Directory buckets are not claimed

AWS documents `If-None-Match: *` for S3 Express One Zone as well, so the
conditional write is not the obstacle. The endpoint form and the session-token
authentication flow are: ADR-0010's vendored SigV4 signer does not obtain a
session, and building one to reach a bucket class nothing in this design needs is
scope for its own sake.

## Tests are unchanged

Issue #15's two rungs stand: the in-process fake for all logic, one real AWS
integration test for what only S3 can answer. No MinIO, LocalStack or moto. The
fake makes `put_object_if_absent` a single-threaded dictionary insert, which is a
stronger and more deterministic guarantee than any real store — and standing up
MinIO locally would teach the behaviour of the one implementation whose failure
modes this ADR exists to exclude.
