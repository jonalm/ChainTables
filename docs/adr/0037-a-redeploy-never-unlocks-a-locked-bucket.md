---
status: accepted
---

# A redeploy never unlocks a locked bucket

A locked bucket (`setup-locked-bucket.sh`) rests on two things that
`deploy.sh` also writes: the function's environment, where
`CHAINTABLES_KMS_KEY_ARN` and `CHAINTABLES_RETENTION_DAYS` make the gateway
dress every put with SSE-KMS and COMPLIANCE retention, and the bucket policy,
whose `Deny*` statements refuse any put without them. `deploy.sh` replaced
both wholesale. Re-running it on its own, the documented way to redeploy,
dropped the two variables and every deny, and the gateway went on filling
slots with no retention and no error. Issue #69.

## Decision

**`deploy.sh` merges the bucket policy by `Sid`.** It owns `GatewayPuts`,
`OnlyTheGatewayPuts`, `DenyInsecureTransport` and `Read<n>`, rewrites those
from its arguments (a dropped `--reader` loses its `Read<n>`), and keeps every
other statement as it is. A statement without a `Sid` cannot be merged, and
the script refuses rather than drop it. A failure to read the policy, other
than there being none, aborts.

**`deploy.sh` refuses a lock mismatch before it changes anything.** A bucket
with Object Lock must be deployed with both variables, and a bucket without it
with neither: the first would put records with no retention, the second would
have S3 refuse every put. The refusal names `setup-locked-bucket.sh`, which is
how a locked bucket is redeployed. Object Lock is the test because it can only
be set when a bucket is created and never removed, so it cannot drift from
what the bucket is.

**The environment is still replaced, not merged.** Its contents are the
arguments, as before; the lock check covers the two variables that matter.

**`setup-locked-bucket.sh` verifies content, not presence.** It reads the
bucket policy back and compares every statement it put with what it sent,
where it used to check only that the `Sid`s existed.

## Considered options

- **Keep the variables already set on the function.** A redeploy could then
  never remove a variable, and a stale key ARN would survive a key change in
  silence. Rejected for the check above.
- **Refuse any `deploy.sh` run on a locked bucket.** `setup-locked-bucket.sh`
  runs `deploy.sh` itself, so it would need a bypass, and the bucket policy
  would still be stripped between its deploy and merge steps. Rejected.

## Consequences

- On a plain bucket, a statement added by hand now survives a redeploy. One
  named `GatewayPuts`, `OnlyTheGatewayPuts`, `DenyInsecureTransport` or
  `Read<n>` is still overwritten.
- `deploy.sh` reads the bucket's Object Lock configuration and policy, so the
  deploying principal needs `s3:GetBucketObjectLockConfiguration` and
  `s3:GetBucketPolicy`; an administrator has both.
- A deployment from before this change is not repaired by it: a locked bucket
  already unlocked by a bare `deploy.sh` is re-locked by running
  `setup-locked-bucket.sh` (#83).
