---
status: accepted
---

# Nobody may change a locked bucket's lifecycle

ADR-0038 denies `DeleteObject` so that no principal can hide a locked slot
behind a delete marker. A lifecycle rule that expires current versions adds
the same markers, as S3 itself. ADR-0038 left that path to the verification
in `setup-locked-bucket.sh`, and rejected denying
`s3:PutLifecycleConfiguration` because the deny would also refuse harmless
rules. But the verification runs only when the setup runs. Between runs, a
console click, an infrastructure tool or a clean-up script can add such a
rule. S3 then hides the slots on its own schedule, and the gateway fills them
again with no alarm. That is the casual, scripted change ADR-0038 meant to
turn into a deliberate one. Issue #87.

## Decision

**The bucket policy denies `s3:PutLifecycleConfiguration` on the bucket to
every principal (`DenyLifecycleChanges`), with no exception.** The action also
covers deleting the configuration. A bucket policy cannot see what a rule
contains, so the deny refuses every change, harmless or not. Break glass is
the same as for `DenyDeleteMarkers`: edit the bucket policy, change the
lifecycle, and run the setup again, which restores the deny.

**The verification still refuses a rule that expires current versions.** A
rule put before the deny is not undone by it.

**The setup proves it.** After the `PutObject` and `DeleteObject` probes, a
lifecycle put as the administrator running the setup must be denied. If it
were let through, it would change nothing: it puts back the configuration in
place, or, with none, one disabled rule that would only abort stale
multipart uploads under `probe/`.

## Considered options

- **Keep the verification alone (ADR-0038).** It checks only when the setup
  runs. Rejected.
- **Alert on `PutBucketLifecycleConfiguration` (CloudTrail, EventBridge or AWS
  Config).** It keeps transitions possible, and an expiration needs at least a
  day, so an alert usually comes in time. But it detects instead of refusing,
  and it is infrastructure outside this repository. It can still be added on
  top. Rejected as the guarantee.

## Consequences

- Amends ADR-0038, which rejected this deny.
- Storage-class transitions (to Infrequent Access or Glacier) and clean-up
  once a retention ends are lifecycle rules too. Each is now a break-glass
  change. Set up any transitions you plan before the deny goes in.
- In a locked bucket the rules ADR-0038 wanted to keep have little to do:
  puts never overwrite and deletes are denied, so there are almost no
  noncurrent versions or delete markers to expire.
- An existing locked bucket gets the deny when `setup-locked-bucket.sh` runs
  again (#83).
