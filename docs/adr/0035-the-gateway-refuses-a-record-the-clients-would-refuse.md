---
status: accepted
---

# The gateway refuses a record the clients would refuse

ADR-0028's check 3 said the body "decodes, under a strict CBOR decoder, as a
map". The gateway decoded with `cbor2.loads`, which is not strict: it takes
duplicate map keys (the last one wins), trailing bytes, indefinite lengths,
unsorted keys, non-shortest heads and tags. The Julia reader (`src/cbor.jl`,
ADR-0006) rejects all of them. So the gateway could fill a slot with a record
that every client then refuses to read. A slot is filled once and never
rewritten, so one such record ends the chain for every reader. Issue #75.

## Decision

Check 3 holds the body to the record format the Julia reader accepts, in two
steps:

1. **Domain.** The decoded item may hold only maps with text keys, arrays, text
   without U+0000, bytes, int64 integers, floats, `false`, `true` and `null`, at
   most 64 levels deep. Anything else (a tag `cbor2` decodes into a datetime or
   a set, `undefined`, another simple value, an out-of-range integer, a cycle
   built from shared references) is `400 not_cbor_map`.
2. **Encoding.** `cbor2.dumps(item, canonical=True)` must equal the body byte
   for byte. This one comparison refuses duplicate and unsorted keys,
   indefinite lengths, non-shortest integers and floats, a NaN other than
   `f97e00`, a tag around a plain value (a bignum that fits in an int64, the
   self-describe tag), and trailing bytes.

Step 2 relies on `cbor2`'s canonical encoder producing the same bytes as the
Julia encoder. It did on all 96 cases of the conformance corpus
(`test/conformance`, ADR-0006), with the same pinned `cbor2` version the gateway
runs. A `cbor2` upgrade must re-run that corpus.

This is still not content validation. The gateway does not read `prev_hash`,
`chain_id`, the ops or `format_version`, and a record that is well-encoded but
malformed in ADR-0025's sense is still the committer's bug. The gateway only
refuses bytes that no client can decode, because those break every reader and
not only the writer.

## S3 refusing the gateway's own put

Check 7 mapped every S3 failure other than 412 and 409 to `502 s3_error`, which
the client retries (ADR-0010). A 4xx from S3 there is a misconfigured
deployment: the role lacks a permission, the bucket is wrong, or the lock's
headers do not match the bucket policy. A retry cannot fix any of these. The
gateway now answers `502 s3_refused` for an S3 4xx and keeps `502 s3_error` for
an S3 5xx or a transport failure. The client raises `WriteRefusedError` with
`reason = "s3_refused"` and does not retry. Its message sends the user to the
bucket's operator. An older client reads `s3_refused` as a 502 and retries it
four times, as before.

## Considered options

- **Correct the ADR instead.** The issue offered this: call the decoder lenient
  and leave the gap. Rejected, because the gap is unrecoverable.
- **A byte-level validator in Python that mirrors `src/cbor.jl`.** Exact, but a
  second implementation of the format to keep in step with the first. The
  canonical round trip reuses an encoder already checked against the corpus.
