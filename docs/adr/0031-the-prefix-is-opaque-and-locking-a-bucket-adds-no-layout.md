---
status: accepted
---

# The prefix is opaque, and locking a bucket adds no layout

A chain's prefix is opaque text. ChainTables — client and gateway — reads no
structure into it: it may contain `/`, the slashes mean nothing, and the empty
prefix is the one chain at the bucket root (ADR-0011). A **locked bucket**
(SSE-KMS plus COMPLIANCE Object Lock) changes how a put is dressed and nothing
about which keys are slots. Issue #64.

## The problem

Commit `89d4070` made a gateway configured for a locked bucket refuse any slot
key that was not `<record-class>/<customer>/<four-digit year>/…/<12 digits>`
(`400 not_a_record_key`), and tag each object with `record-class` and `customer`
from the first two segments, plus `retain-until`.

- **"Record class" and "customer" are not ChainTables concepts.** No ADR and no
  glossary entry defined them; they were one deployment's vocabulary in a
  generic package.
- **It contradicted the client.** `Chain` accepts any prefix, so a client built
  a valid chain at `scratch_1` and its first write failed at the gateway.
- **Nothing consumed it.** No bucket policy, lifecycle rule or IAM condition
  read the tags; the year was matched and discarded; retention is one number per
  gateway.
- **Two unrelated things shared a switch.** Turning on Object Lock also turned
  on a naming convention.

## The decision

- **The layout rule and `not_a_record_key` are removed.** A locked gateway takes
  a slot under any prefix a plain one does. Nothing generic replaces the rule: a
  deployment that wants a naming convention has the policy file's globs, and its
  own code that builds prefixes.
- **The gateway writes no tags.** `retain-until` duplicated the Object Lock
  retention date, which S3 records authoritatively (`GetObjectRetention`). The
  execution role no longer needs `s3:PutObjectTagging`.
- **A locked put carries** SSE-KMS with the configured key and the bucket key,
  COMPLIANCE retention until now + n days, and the SHA-256 checksum.
- **Opaque, within a portable alphabet.** Amended by ADR-0034: each
  `/`-separated segment of the prefix is a record-cache directory, so it must be
  valid on every filesystem: lowercase `a-z`, `0-9`, `.`, `_`, `-`, and no `.`,
  `..`, trailing `.` or Windows device name. The prefix is at most 100
  characters. This is the client's path mapping,
  not a layout: no segment means anything.
- **Prefixes may nest.** Chains at `a` and `a/b` are unrelated. Their slot keys
  cannot collide (a slot is the prefix plus exactly twelve digits), and no
  client lists a chain — head discovery asks for slot keys by name — so neither
  chain can observe the other. Refusing nesting would need a mechanism for a
  non-problem.

## Considered and rejected: renaming `prefix` to `chainname`

"Prefix" names the S3 mechanism rather than what the value is, which is how a
layout rule came to be attached to it. Renaming was weighed: about two hundred
edits across client, gateway, tests and docs; a changed public field and
`ChainNotFoundError` keyword; changed message texts (the contract, ADR-0020);
and a breaking `format_version: 2` for a policy file operators hold private
copies of. A client-only rename would have left two words for one thing across
the gateway seam.

Rejected on cost. The glossary carries the meaning instead: `CONTEXT.md` defines
**prefix** as a chain's opaque location within a bucket — where, not which;
identity stays the chain id (ADR-0011).
