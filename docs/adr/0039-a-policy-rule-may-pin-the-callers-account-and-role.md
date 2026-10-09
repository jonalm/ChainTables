---
status: accepted
---

# A policy rule may pin the caller's account and role

ADR-0028's author rule takes the caller's name from the text after the last
`/` of the caller ARN, and the gateway policy lists names only. So every
account whose principals may invoke the function shares one namespace: an
IAM user named `alice@example.com` in any such account, or an Identity Center
user of that name in another account's Identity Center, passes as alice. A
plain IAM role whose session name the caller chooses is the same risk inside
one account. Both were only documented (`docs/gateway-setup.md`). Issue #82.

## Decision

**A rule may carry `accounts` and `roles`, and a caller then matches the rule
only if all of them hold:**

```json
{"prefix": "teams/alpha", "writers": ["alice@example.com"],
 "accounts": ["111122223333"],
 "roles": ["AWSReservedSSO_chaintables-writer_*"]}
```

- `accounts`: the caller ARN's account is listed.
- `roles`: the caller is an assumed role whose role name matches one of the
  globs (`*` the only wildcard, case-sensitive). An IAM user never matches a
  rule with `roles`. To admit both kinds, write two rules: rules are
  alternatives, as before.
- A rule without them behaves as before.

**`roles` requires `accounts`.** The assumed-role ARN carries the role name
without its path, and the name is whatever the account's administrators
chose. Pinning `AWSReservedSSO_*` without an account would admit a role of
that name created in any account allowed to invoke. With `accounts`, it limits
the rule to Identity Center sessions, where AWS sets the session name, against
everyone in those accounts who cannot create or rename roles. AWS does not
document the `AWSReservedSSO_` name as reserved, so it is not a defence
against that account's own administrators.

**Pinning narrows the namespace for function-URL callers only.** The account
and role come from the same `requestContext.authorizer.iam.userArn` the name
does. A principal that may call Invoke without the function-URL condition
writes the whole event, so it can forge account and role as easily as name.
Pinning does not shrink the trust boundary ADR-0036 sets.

**The policy stays `format_version` 1.** The fields are optional and additive,
and a policy without them means what it meant. An older gateway refuses a rule
with any field but `prefix` and `writers` when it loads, so a new policy on an
old gateway fails at startup, and `deploy.sh`'s smoke invocation reports it.
A version bump would add no safety and would force every existing policy to
change.

## Considered options

- **A separate `users` field for IAM users.** Two rules already express it.
  Rejected for now.
- **Pin by full ARN in `writers`.** It would tie the policy to the
  permission-set role's per-account hash suffix, which changes when the
  permission set is reprovisioned. Rejected.
- **Have `deploy.sh --writer` warn about cross-account writers when no rule
  pins `accounts`.** `deploy.sh` never sees the policy: `build.sh --policy`
  bundles it into the zip. The warning would need `deploy.sh` to read
  `policy.json` back out of the zip. Rejected for now.

## Consequences

- ADR-0028's check 1 becomes: the caller is an IAM user or assumed role that
  some rule matching the prefix admits.
- `not_allowed` now names the caller's account and role, so an operator can
  tell a missing name from a pin that does not match.
- A policy that uses the new fields reaches a gateway only in a zip built from
  this handler: `build.sh --policy` bundles both, so they always ship together
  (#83). On a locked bucket the redeploy is `setup-locked-bucket.sh --policy`
  (ADR-0037).
