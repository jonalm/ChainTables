---
status: accepted
---

# Nobody may hide a locked slot behind a delete marker

A locked bucket (ADR-0031, `setup-locked-bucket.sh`) puts every record under
COMPLIANCE retention, so no one can delete or overwrite that version until the
retention ends. But a locked bucket is versioned, and Object Lock allows a
`DeleteObject` without a version id: it adds a delete marker above the locked
version. The slot then reads as absent, the gateway's `If-None-Match: *` put
succeeds, and readers see the new record. The original survives underneath,
yet the chain a fresh client reads has been rewritten. A lifecycle rule that
expires current versions adds the same markers, through S3 itself rather
than a principal. The bucket policy had no statement for either. Issue #74.

## Decision

**The bucket policy denies `s3:DeleteObject` on the bucket's objects to every
principal (`DenyDeleteMarkers`), with no exception.** Neither the gateway nor
a reader ever deletes. Break glass is to edit the bucket policy, which only
an administrator can do and CloudTrail records.

**`setup-locked-bucket.sh` refuses a lifecycle rule that expires current
versions.** No bucket policy can deny an action S3 takes on its own, so the
verification checks the configuration instead. Rules that expire noncurrent
versions or expired delete markers are allowed.

**The setup proves it.** Next to the bare-`PutObject` probe, a `DeleteObject`
as the administrator running the setup must be denied. This is the live test
the issue asked for. It runs on every setup, against the real bucket.

## Considered options

- **Exempt a break-glass role from the deny.** That role would become a
  standing way to rewrite the chain. Editing the policy already serves the
  rare legitimate case, and is a deliberate, logged step. Rejected.
- **Deny `s3:DeleteObjectVersion` too.** Object Lock already refuses it while
  the retention holds. Once the retention ends, deletion is the operator's
  choice, which is what a finite retention means (and GDPR may require it, see
  #80). Rejected.
- **Have the gateway refuse a slot whose current version is a delete marker.**
  That costs a HEAD per write and a wider execution role, and it races with
  the marker. An administrator who can add the marker can also redeploy the
  gateway. Rejected for now.
- **Deny `s3:PutLifecycleConfiguration`.** That would also block harmless
  rules, and an administrator could remove the deny. Rejected in favour of
  the verification.

## Consequences

- As with every other guarantee here, an administrator can still remove the
  deny (ADR-0028). It turns a casual or scripted delete into a policy change.
- After the retention of a record ends, its version can be deleted, and the
  slot can then be filled again.
- An existing locked bucket gets the deny when `setup-locked-bucket.sh` runs
  again (#83).
- A locked bucket cannot have its old records cleaned up by expiring current
  versions; the live test's advice about lifecycle rules no longer applies to it.
