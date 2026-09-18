---
status: accepted
---

# A gateway bucket verifies the author, and nothing else

A **gateway bucket** is a bucket whose only writer is a **gateway**: one Lambda
function, behind a function URL with `AuthType=AWS_IAM`, that fills a slot only
after checking that the caller may write under that chain's prefix and that the
transaction record names the caller as its **author**. Readers and writers both
log in with the organisation's identity provider through AWS IAM Identity
Center. Reads never touch the gateway. The gateway **validates and never
authors**: the client builds the transaction record exactly as it does for a
plain bucket, and the gateway either does the conditional put under its own role
or refuses. The record format stays `format_version` 1, with no field for the
server.

A plain bucket is unchanged and stays supported. Whether a bucket is gated is a
property of the **bucket** — who holds `PutObject` on it, and which gateway
fronts it — and never of the chain: a chain copied from a gateway bucket to a
plain one is the same chain (glossary: chain id), and it carries no trace of
having been gated.

## The problem

On a plain bucket, `client.user` is whatever the committing process says it is:
ADR-0006 made it advisory, forensic, and individually suppressible. Any
principal with `PutObject` on the prefix can fill a slot with a record naming
anybody. That is fine for a bucket shared among clients that trust each other,
and it is not fine for one where the chain is the record of who did what. What
is wanted is a bucket where a slot's record can be trusted to name the
principal that filled it, and where filling a slot under a chain's prefix is
something a principal is *allowed* to do or not, per prefix.

Nothing in the format can supply that: a record is bytes hashed as stored, so a
claim inside it is only as good as whoever put it there. The guarantee has to
come from the write path, and the narrowest write path is one function.

## The checks, in order

The first failure wins; the gateway reports it as an HTTP status and a JSON
body `{"code", "message"}` (the wire contract is issue #54 §5 and the top of
`gateway/handler.py`).

1. The caller is an IAM user or an assumed role, and its name is allowed for
   the key's prefix by the gateway's policy → else `403 not_allowed`.
2. The key is a slot — `<prefix>/<12 digits>`, or `<12 digits>` at the bucket
   root — and never a reserved name (ADR-0011) → else `400 not_a_slot`.
3. The body decodes, under a strict CBOR decoder, as a map → else
   `400 not_cbor_map`.
4. `client.user` is present and non-empty text → else `400 no_author`.
5. `client.user` equals the caller's name → else `403 author_mismatch`.
6. The body is at most **4 MiB** → else `413 too_large`.
7. `PutObject` with `If-None-Match: *` under the gateway's own role, mapped by
   HTTP status alone: `200 created`, `412 slot_taken`, `409 conflict`, and
   anything else — an S3 5xx, a transport failure, a misconfigured deployment —
   `502 s3_error`. The gateway never retries S3; ADR-0010's rule that the commit
   layer owns the whole retry budget holds across the extra hop.

**Deliberately not checked**: `prev_hash`, `chain_id`, the ops, and
`format_version`. Checking any of them would make the gateway a ChainTables
client — it would have to fetch the parent, decode ops, and track the format —
and then every format change would be a gateway deployment and the gateway's
version would gate every commit. The chain's integrity is already the clients'
job (ADR-0002, ADR-0014); the gateway adds one fact the clients cannot
establish for themselves, and only that one.

The map check (3) exists so that (4) and (5) have something to read; it is not
content validation. A record that decodes but is malformed in ADR-0025's sense
is committed and is the committer's bug, as on a plain bucket.

## The author rule

**Author = the text after the last `/` of the caller's ARN**, on both sides:

- the client takes it from `sts:GetCallerIdentity`'s `Arn`;
- the gateway takes it from the function URL's request context
  (`requestContext.authorizer.iam.userArn`).

For an Identity Center session the ARN is `assumed-role/<permission-set
role>/<session name>`, and the session name is the Identity Center user name —
with Entra ID federated over SAML and SCIM, the user principal name. That
equality is **documented nowhere** by AWS and was verified live during
provisioning (issue #58); it is the empirical fact this ADR rests on, and the
live gateway test (`test/live/gateway.jl`, ADR-0030) re-verifies it. Only the tail is compared, so the two sides
need not agree on whether the full ARNs are identical, which AWS also leaves
undocumented. The gateway refuses any principal that is neither a user nor an
assumed role (the account root, a service principal) as `not_allowed`.
Comparison is exact and case-sensitive, as is the policy's name match.

On the client, the author is fetched **lazily at the first write** — in
`create_chain` or `commit!`, before anything is applied, next to ADR-0016's
refusal — never at `Chain` construction, which does no I/O (ADR-0019). It is
memoized per access key id, so refreshed credentials for another identity fetch
again. It reaches `client.user` through an internal `record_author(store)`,
whose default is today's `USER` environment lookup and whose gateway method
returns the STS name; `ENV` is ignored on a gateway store, and no keyword for an
explicit author name exists. This is an internal dispatch, not a fifth verb on
the object-store port (ADR-0010).

`record_user = false` with a gateway is refused at `Chain` construction: the
gateway always refuses a record with no author, so the combination can never
commit and there is no reason to let it be built.

## Identity, and where policy lives

The login path is: Entra ID → AWS IAM Identity Center (SAML for sign-in, SCIM
for provisioning) → `aws sso login` → temporary AWS credentials → ADR-0010's
existing SigV4 signer, signing for service `lambda` against the function URL.
The client has **no new login code**: it signs a request as it already does,
with the region and credentials the `Chain` already holds. A function-URL
caller needs both `lambda:InvokeFunctionUrl` and `lambda:InvokeFunction`; a
403 that arrives with no gateway `code` in its body is AWS refusing the
invocation, and the client reports it as `reason = "forbidden"`.

**Reads stay direct.** A reader permission set grants `GetObject` and
`ListBucket` on the bucket; only the gateway's execution role holds
`PutObject`. A writer holds both the reader rights and the right to invoke the
function. So the gateway is on the path of exactly one of the port's four verbs
— `put_object_if_absent` — and `fetch_object`, `stat_object` and `list_objects`
run against S3 as on a plain bucket, including the read-back that ADR-0010 makes
the authority on a commit's outcome. A put whose reply was lost is resolved by
that read-back with no new logic.

**Policy is the gateway's configuration**, a JSON file deployed with it: a list
of rules, each a prefix glob and the names allowed to write under it. Creating a
chain under an allowed prefix needs no separate right. One gateway per bucket.
The chain carries no policy, in ADR-0003's sense and by the same argument: who
may write is a rule about what is *permitted*, and the chain records only what
*is*. A policy that lived in the chain would also have to be read by the
gateway, which is the ChainTables-client role refused above.

## The client surface

```julia
ChainTables.Chain(bucket, prefix; gateway = function_url, region, credentials, …)
```

`Chain` builds a `GatewayObjectStore` from its own bucket, region, credentials,
endpoint and path-style flag, so the bucket is named once and cannot mismatch
the gateway's. **Amended by ADR-0029**: that holds for the store and not for the
deployment — a gateway fills the bucket of its own environment whatever the
client named — so a `200` is believed only after a stat finds the slot in the
bucket the chain reads, else `GatewayMismatchError`; and the bucket, region,
gateway and profile are held as one `Bucket` value, `Chain(bucket, prefix)`. `gateway` together with `store` is an `ArgumentError` (two
stores), as is a `region` that disagrees with the one in the function URL's
host. The store type exists for dispatch and tests; users do not build it.

The **record cap on a gateway store is 4 MiB** (`4 · 1024 · 1024`), against
ADR-0006's 64 MiB on a plain bucket. A function URL carries at most 6 MB each
way on the base64-encoded event, so 4 MiB of record leaves 683 KiB of headroom
after encoding and the break-even is about 4.5 MiB. The cap is checked in the
client after `encode_record`, before the put, and raises `WriteBuilderError`
naming the byte count, the cap and the store, and saying to split the write
into more than one commit; the gateway checks it again. The cap is the design,
not a stopgap: one transaction record of 4 MiB is a large one, and the
whole-table rewrite that motivated 64 MiB (ADR-0003) is a rare event a writer
can plan around.

## Errors

**`WriteRefusedError(msg; chain_id, slot, key, caller, reason)`** is the
fifteenth `ChainTablesError`, amending ADR-0020's table. It is raised by
`commit!` and `create_chain`, never retried, and `caller` is the name the client
resolved for itself. One type with a `reason` rather than three types, because
the user's next move is the same in every case — stop, and have a person act —
and what differs is who that person is:

| `reason` | cause | next move |
|---|---|---|
| `"not_allowed"` | the policy has no entry for this name on this prefix, or the principal is not a user or assumed role | ask the bucket's operator to add the name to the gateway policy |
| `"author_mismatch"` | `client.user` ≠ the caller's name | a bug, or credentials changed between the STS call and the put; report it |
| `"forbidden"` | AWS returned 403 before the handler ran | the principal lacks `lambda:InvokeFunctionUrl` and `lambda:InvokeFunction`; ask the operator for the writer permission set |

The other gateway statuses map onto ADR-0010's retry loop without a new rule:
`412` is a lost race as today, `409` and `5xx` (including Lambda's own 502 and
504) are `TransportError` and retried, `400` and `413` are `TransportError` not
retried, carrying the gateway's code and message. **`429` joins the retryable
set for every store**: Lambda throttles with it, S3 throttles with `503`, so
the plain store's behaviour is unchanged. This amends ADR-0010's retry rule.

## Considered options

- **The server authors the record, `format_version` 2.** ADR-0006's
  "server era" note, and the shape its attestation-region discussion settled
  on: the client sends ops, the server builds and hashes the record. Rejected.
  The server would then be a ChainTables client — it must know the parent, the
  fingerprint, the encoder — so every format change is a server deployment, the
  server's version gates every commit, and a server bug forks every chain it
  fronts. It also forces the format bump before any client can use a gated
  bucket. Validating instead leaves the format alone, keeps every client-side
  guarantee where it is, and makes the gateway a few hundred lines that never
  need to change when the format does. ADR-0006's note is superseded in place.
- **Stage-then-promote for large records**: the client puts the bytes to a
  reserved `staging/` name directly and the gateway copies them into the slot,
  lifting the 4 MiB cap. Rejected: a second write path, a reserved name the
  client must have `PutObject` on (which reopens the bucket to unchecked
  writes), and a cap that is plenty. Out of scope for the format, not deferred.
- **Cognito, or direct Entra OIDC on the client.** Rejected: Identity Center
  already covers the writers and yields ordinary AWS credentials, so the client
  keeps one auth path and zero new login code. A second identity path would
  need its own signer, token cache and refusal semantics.
- **Presigned PUT URLs** minted by a function after checking the policy.
  Rejected: the function could check the *caller* but not the *record* — the
  bytes go straight to S3 after the URL is minted — so the author check is
  impossible, and the presigned URL would carry `PutObject` without
  `If-None-Match` being enforceable by the minter.
- **Recording gatedness in the chain**, so a client could tell from the records
  that they were author-checked. Rejected: gatedness is the bucket's, a chain
  copied elsewhere is the same chain, it would break ADR-0003 and the unchanged
  `format_version`, and it would make the gateway read chain content.
- **Signed records** — per-record cryptographic authorship the reader verifies
  offline. Out of scope: attribution here rests on the bucket policy, per
  bucket, not per record, and a reader who wants more than that wants a
  different design.
- **A user-constructed `GatewayObjectStore(bucket, url)`** passed as `store =`.
  Rejected in favour of the `gateway` keyword so the bucket is given once and
  the region can be checked against the URL.

## Consequences

- **ADR-0006 is amended in place**: its "server authors" option and "the
  server era is `format_version` 2" consequence are superseded by this ADR;
  `client.user` gains a second reading — advisory on a plain bucket, verified on
  a gateway bucket — and `record_user = false` is refused with a gateway.
- **ADR-0010 is amended in place**: `429` is retryable, and the object-store
  port stays four verbs with one of them routed through a function.
- **ADR-0020's table gains `WriteRefusedError`**, raised by commit, whose next
  move is to have a person act.
- **The gateway is Python** (`cbor2` to decode, `boto3` with retries off to
  put), one Lambda, with its code, tests, policy *format* and a generic deploy
  script in this repo under `gateway/`. The policy *contents*, account ids,
  ARNs, the function URL and the tenant federation live outside the repo.
  ADR-0027 admits the two dependencies on merit; ADR-0010's transport rule is
  met because boto3's retries switch off entirely.
- **A gateway bucket has a trust boundary a plain bucket lacks**, and it is
  exactly one fact wide: a record in a gateway bucket names the principal that
  filled its slot, and that principal was allowed to. Everything else a reader
  believes about a record, it believes for the same reasons as on a plain
  bucket.
- **Onboarding a writer is three independent gates**: assignment to the
  identity provider's application (sign-in), a permission-set assignment (the
  AWS rights), and the name in the gateway policy. Any one missing yields a
  different failure — a login refusal, `reason = "forbidden"`, or
  `reason = "not_allowed"` — and the messages name which.
- **The one credentials helper is `sso_credentials(profile)`**, a `credentials`
  callable over `aws configure export-credentials`, the CLI's own cache of an
  `aws sso login` session, re-run near expiry. It is not login code: the CLI
  logs in, the package reads what it cached, and the callable form is the one
  ADR-0019 already admits. It lives beside `credentials_from_env` because
  nothing about it is gateway-specific, and it is in the package rather than a
  documented snippet because the refresh margin and the expiry's timezone are
  what a copied snippet gets wrong, and both test without AWS.
- **Amended by ADR-0029**: `sso_login(profile)` runs `aws sso login` from
  Julia, beside `sso_credentials`. The CLI still logs in; no operation ever
  triggers it, and `sso_credentials(profile; login = true)` does so only in an
  interactive session.
- **The author is only as stable as the session name.** Should AWS change what
  Identity Center puts in the role session name, both sides move together
  (they apply one rule to one ARN), but existing records would carry the old
  spelling. That is the cost of resting on an undocumented fact, accepted
  because the alternative was a second identity path.
