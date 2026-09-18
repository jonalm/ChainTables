---
status: accepted
---

# A `Bucket` value pairs what must agree, and login is always asked for

`ChainTables.Bucket(name; region, gateway, profile)` is a further public type: a
bucket, the region it lives in, the gateway that fronts it, and the AWS CLI
profile this client reaches it with, as one plain value.
`Chain(bucket::Bucket, prefix; kw...)` is a method on the existing constructor
that delegates to `Chain(name, prefix; …)`. `ChainTables.sso_login` runs
`aws sso login` from Julia, and **no operation ever calls it by itself**. A
gateway's `200 created` is believed only once the bucket the chain reads holds
the slot; otherwise `commit!` raises the new `GatewayMismatchError`.

This amends ADR-0019 (a fourth type with behaviour, after ADR-0024's
`TableView`), ADR-0020 (a sixteenth error) and ADR-0028 (the mismatch check, and
a second credentials-side helper).

## The problem

Opening a chain on a gateway bucket takes four values that must agree, and
ADR-0028's surface takes them loose:

```julia
credentials = ChainTables.sso_credentials(profile)
chain = ChainTables.Chain(bucket, prefix; gateway, region, credentials)
```

- **bucket ↔ gateway is 1:1.** The function's `CHAINTABLES_BUCKET` names one
  bucket, and the bucket policy admits one gateway role as the only `PutObject`
  principal (ADR-0028: one gateway per bucket).
- **region** is where both live; `Chain` already refuses a `region` that
  disagrees with a `*.lambda-url.<region>.on.aws` host.
- **profile → bucket is many-to-one.** The profile's permission set is scoped to
  *that* bucket's reads and *that* function's invocation, and the user must be
  in that gateway's policy.

These are facts about a **deployment**, and `Chain`'s keywords cannot express
that they belong together: a consumer ends up with three constants and the same
five-keyword call at every site, and a scratch script pairs a profile or a
gateway with the wrong bucket without anything saying so.

Most mismatches already fail cleanly — the wrong profile is a 403 on a read or
`reason = "forbidden"`, a missing policy entry is `not_allowed`. **One did
not.** ADR-0028 said the bucket "is named once and cannot mismatch the
gateway's"; that is true of the *store* `Chain` builds, and false of the
*deployment*: the gateway fills the bucket of its own environment whatever
bucket the client named. Reading the commit path settled the symptom the issue
left unverified: `put_record!` takes `created = true` as the outcome, caches the
record under the client's bucket and returns, so the commit **succeeded in
silence** into a bucket nobody reads, the local copy advanced, and the record
cache then answered for a slot the read bucket never held.

## The type is here; the values are the consumer's

The struct, its checks and the `Chain` method are generic and public. Bucket
names, function URLs, account ids and profile names stay with the consumer, as
an instance (`const BUCKET = ChainTables.Bucket(…)`), exactly as ADR-0028 keeps
policy contents and ARNs outside the repository. Docs and tests here use
placeholders only.

It is **plain data**: constructing one performs no I/O and resolves nothing. It
holds the profile's *name*, never credentials, which resolve when a `Chain` is
built (ADR-0019). So it prints whole — nothing in it is secret — it loads from
TOML or Preferences, and a user overrides `profile` per call, because profile
names are local to each `~/.aws/config`. `profile` is already a ChainTables
concept (`sso_credentials(profile)` shipped with ADR-0028), so holding it is
consistent.

### The name

The issue's working name was `ChainConfig`. Rejected: ADR-0019 already defines
`Chain` as "location and configuration", so `ChainConfig` reads as `Chain` minus
`prefix` and says nothing about what the value is. `Site` and `Deployment` name
nothing in the glossary. **`Bucket`** is what it is: ADR-0028 made gatedness "a
property of the bucket — who holds `PutObject` on it, and which gateway fronts
it", the glossary says "one bucket holds many chains", and
`Chain(bucket, prefix)` already reads as a bucket and a prefix. `Bucket` stands
to a bucket as `Chain` stands to a chain: where it is and how this client
reaches it, not the thing itself. The name is positional and the field is
`name`, so nothing is written `Bucket(; bucket = …)`.

### Checks, and the region

Construction fails fast with **the checks `Chain` makes and the messages `Chain`
gives**, from shared code (`check_bucket_name`, `gateway_base`): an empty name,
a dot in the name (ADR-0010), a gateway that is not `scheme://host[:port]`, a
`region` that disagrees with the function URL's. An empty `profile` is refused.
`gateway = nothing` is a plain bucket; `profile = nothing` is the `AWS_*`
environment or a `credentials` keyword.

`region` is **optional and follows `Chain`'s rule unchanged**: the value, else
`AWS_REGION`, else `AWS_DEFAULT_REGION`, never guessed, resolved when the
`Chain` is built — where the URL check runs again against the resolved region.
Resolving at `Bucket` construction was rejected: the value would then depend on
the environment it was built in, and stop being plain data. Requiring it was
rejected because a bucket used with a supplied `store` has no use for one.
Deriving it from a `lambda-url` host was rejected as a second rule beside
ADR-0019's.

### `Chain(bucket, prefix; kw...)`

One way to build a chain: the method computes keywords and delegates.

- `credentials` defaults to `sso_credentials(profile; login)` when there is a
  profile, else `nothing`. A `credentials` keyword wins; a `profile` keyword
  replaces the bucket's.
- Every other `Chain` keyword passes through, **except `region` and
  `gateway`, which are refused**: they are the bucket's to say, and a keyword
  that silently won over the value would reopen the mispairing the value exists
  to close.
- With a supplied `store` the bucket's `gateway` is not forwarded, because
  `Chain` refuses `gateway` with `store`; that is what lets a consumer test
  against `Testing.InMemoryObjectStore` with its production `Bucket`.

## A gateway's `created` is checked against the bucket the chain reads

After a `200` from the gateway, `GatewayObjectStore` stats the key on its S3
half. Found: `PutOutcome(true, 200)` as before. Absent:
**`GatewayMismatchError(msg; chain_id, slot, key, bucket, gateway)`**, the
sixteenth `ChainTablesError`, raised by `commit!` and `create_chain`, never
retried, before the record is cached or applied. S3 is read-after-write
consistent, so absence is a verdict and not a race; a stat that itself fails is
a retryable `TransportError`, and the re-issued put's `412` hands the decision
to ADR-0010's read-back as usual.

The cost is one `HEAD` per commit on a gateway bucket, accepted: the alternative
is a commit that reports success and is lost. The record that landed in the
other bucket stays there — the port has no delete (ADR-0010) — and the message
says so. The next move is the configuration's: pair the bucket with its own
gateway, as one `Bucket`.

Having the gateway *report* its bucket in the `200` body, for the client to
compare, was rejected: it changes the wire contract and every deployed gateway
for a fact the client can establish itself with a request it already knows how
to make.

`Bucket` does not make the mismatch impossible — a `Bucket` can still be written
with the wrong URL — it makes the pairing **one value, written once, by whoever
knows the deployment**; the check is what makes a wrong one loud.

## Login is never triggered by an operation

An expired SSO session surfaces from the `sso_credentials` callable as an error
naming `aws sso login --profile <p>`. There is now a Julia entry point:

```julia
ChainTables.sso_login(profile; device_code = false)
ChainTables.sso_login(bucket)
```

It runs the CLI attached to the terminal and raises on a non-zero exit or a
missing CLI. It is still not login code in ADR-0028's sense — the CLI logs in —
and it is **always asked for**. `create_chain` was considered as an implicit
trigger and rejected on two facts: `credentials` is a callable invoked before
*every* request, so expiry meets `sync!`, `commit!` and reads as readily as
creation and no single operation is the place; and a library call that opens a
browser and blocks breaks fail-fast and hangs every non-interactive run.

The one chokepoint is the `sso_credentials` callable, and auto-login there is
**opt-in and interactive-only**: `sso_credentials(profile; login = true)` — also
`Chain(bucket, prefix; login = true)` — under `isinteractive()`, runs
`sso_login` once on a failed export and exports again; a second failure raises
as before. Without `login = true`, or outside an interactive session, behaviour
is unchanged: it raises rather than block. The runner, like the exporter, is
injectable, so all of it tests without AWS.

## Considered options

- **Keep the loose keywords and document the pairing.** Rejected: the pairing
  is exactly what documentation cannot enforce, and one of its failures was
  silent.
- **A second constructor or an `open_chain(cfg, prefix)`.** Rejected: a parallel
  way to build a `Chain` is a second API to keep equal to the first. A method
  that delegates cannot drift.
- **`Bucket` holding resolved credentials.** Rejected: it would not print, not
  load from TOML, and would expire.
- **`Bucket` holding the policy or the permission-set name.** Rejected:
  ADR-0028 keeps policy in the gateway's deployment, and the client needs
  neither.
- **Letting `region`/`gateway` keywords override the `Bucket`.** Rejected above.
- **A read-back `GET` instead of a `HEAD`** after the gateway's `200`.
  Rejected: presence is the whole question; the bytes were hashed before they
  left.
- **Reusing `WriteRefusedError` or `TransportError` for the mismatch.**
  Rejected: nothing was refused and nothing failed in transport, and ADR-0020's
  rule is that a condition with its own next move is its own type.
- **Implicit login from `create_chain`, or from any operation.** Rejected
  above.

## Consequences

- **ADR-0019 is amended**: the public surface gains `Bucket`, a fourth type
  with behaviour, and `Chain` gains a method. Nothing is exported, as before.
- **ADR-0020's table gains `GatewayMismatchError`**, raised by commit and
  `create_chain`; next move: pair the bucket with its own gateway.
- **ADR-0028 is amended**: a gateway `200` costs one `HEAD`; its "cannot
  mismatch the gateway's" is narrowed to the store; `sso_login` joins
  `sso_credentials` beside `credentials_from_env`, and the client still has no
  login code of its own.
- **A consumer replaces its bucket, gateway, region and profile constants with
  one `Bucket`**, and its tests run the same value against the in-memory store.
- **A mispaired gateway leaves one stray record in the gateway's bucket** per
  attempt, and the client cannot remove it. No chain read from the named bucket
  ever sees it. If a chain lives under the same prefix in the *other* bucket
  and the slot was its next one, that chain now holds a record that does not
  name its head as parent, which its clients refuse at sync; the gateway's
  policy is what normally prevents this, and that bucket's operator is who
  must look.
