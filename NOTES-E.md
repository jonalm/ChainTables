# NOTES-E: attachments and Testing

## 1. Guide cases

file:line | Rule/Default | unclear/wrong/blocked | choice made
---|---|---|---
test/fixtures/gateway_double.jl, gateway_attachments.jl, attachments.jl | Rule: fixtures hold only consts and pure functions | BLOCKED | Loopback servers, `with_gateway`, `created_chain` are stateful fixtures (the Default says a stateful fixture is a `with_<resource>(f)` helper, which contradicts the Rule; s3_server.jl has the same problem). Kept in fixtures/. Proposal: the Rule allows `with_<resource>` helpers and test doubles in fixtures/.
src/gateway_attachments.jl (check_minted_url, check_minted_header, NO_LIFETIME) | Errors: showerror writes the next move | wrong | `GatewayMismatchError`'s summary ("wrote to another bucket") and next move ("pair the bucket") do not fit a gateway that mints a malformed URL/headers/no lifetime (next move: redeploy it). Used it, the case in `detail`; see errors change requests.
src/gateway_attachments.jl throw_mint_refusal | Errors | unclear | `WriteRefusedError` reasons `no_mint_route` and `s3_refused` get the fallback next move; see errors change requests.
src/attachment_cache.jl cache_entry / heal_entry; src/attachment_repair.jl repair_entry | Default: repeated case split → types | Default doesn't fit | Kept Symbol states (`:absent/:ok/:stale`, `:ok/:absent/:changed/<hash>`, `:sound/:repaired/:gone`), each read in ≤ 2 places of 2 files; reason comment above.
src/gateway_attachments.jl mint | Default: several return values → struct when passed on | Default doesn't fit | Kept two NamedTuples (`present`/`minted`): test/live reads `.code`, `.url`, `.seconds`, `.capped`, `.headers` on both.
src/gateway_attachments.jl minted_reply, upload_minted | Default: timestamp is a keyword `at` | Default doesn't fit | Monotonic `time_ns()` read in place: a deadline read more than once; reason comment above.
src/attachment_cache.jl read_attachment, src/attachment_repair.jl repair_attachments! | Default: no unset keyword | allowed case | `hasher` kept, comment "Test-only race injection".
src/Testing/in_memory_object_store.jl `fault::Any` | Rule: fields concrete | Breakable | `# style: field users assign a fault function of any type at any time`.
src/attachments.jl, attachment_cache.jl, attachment_repair.jl, Testing/in_memory_object_store.jl docstrings | Default: docstring ≤ 8 lines | Default doesn't fit | 5 docstrings of 9–18 lines, each with a reason comment above.
test/test_gateway_attachments.jl + test_gateway_attachments_minted.jl | Default: one test file per src file vs ≤ 400 lines | unclear | Split src/gateway_attachments.jl's tests in two (526 lines); shared setup in fixtures/gateway_attachments.jl.
test/test_attachment_cache.jl (gateway chain testset) | Rule: no warnings but `@test_logs` ones | unclear | s3.jl's `@warn` for a non-AWS endpoint (not my file) prints during `open`; not asserted, since s3.jl's rewrite must remove the `@warn`.
src/Testing/Testing.jl | layout: module docstring, no Examples line | unclear | No separate `@testset "Testing example"`; `Testing` is used in test_testing_in_memory_object_store_examples.jl.
src/gateway_attachments.jl, src/attachments.jl `throw(failure(...))` | Rule: no function returns an error object | unclear | `failure` is s3.jl's; called as before. If s3.jl drops it, build the `TransportError` inline at my 2 call sites.

## 2. File mapping

- src/attachments.jl → src/attachments.jl (AttachmentHash, put_attachment/touch_attachment on chains, the plain bucket's put, keys, retry), src/gateway_attachments.jl (mint route, upload of a minted URL, gateway touch, `fetch_object_to` on a gateway store), src/attachment_cache.jl (`attachment`, cache entries, sidecars, fetch), src/attachment_repair.jl (`verify_attachments`, `repair_attachments!`).
- src/Testing.jl → src/Testing/Testing.jl (Module file) + src/Testing/in_memory_object_store.jl.
- test/attachments.jl + the put_attachment testsets of test/gateway.jl and test/s3.jl → test/test_attachments.jl, test/test_attachments_examples.jl, test/test_gateway_attachments.jl, test/test_gateway_attachments_minted.jl, test/test_attachment_cache.jl, test/test_attachment_cache_examples.jl, test/test_attachment_repair.jl.
- test/Testing.jl → test/test_testing.jl, test/test_testing_in_memory_object_store.jl, test/test_testing_in_memory_object_store_examples.jl.
- New fixtures: test/fixtures/attachments.jl, test/fixtures/gateway_double.jl (LoopbackServer, GatewayDouble, gwtest_* from old test/gateway.jl), test/fixtures/gateway_attachments.jl.

## 3. Behaviour changes

- Every error thrown by my files now has the shared form (summary, `detail`, evidence, next move); old message texts and `(ADR-…)` suffixes are gone.
- `Testing.InMemoryObjectStore` is `public` in `Testing` (`names(Testing)` lists it).
- `InMemoryObjectStore` is parametric, `InMemoryObjectStore{C}` with `clock::C` now `const` (was a reassignable `Any` field). `fault` stays reassignable `Any`. Default clock/fault are named functions.
- `AttachmentHash` (internal) with `==` and `hash`: the hash check runs once per entry point.
- A cached file that vanishes before it is opened is "absent" on any `SystemError` once the path is gone (was: `ENOENT` only; `Libc.ENOENT` is not public).
- `verify(copy; full = true)`'s `AttachmentCacheError` lists the damaged paths, no longer each file's hash.
- A header minted more than once is reported as "N times", not "twice".
- `with_retries` retries `PUT_BACKOFF_S[1:PUT_ATTEMPTS-1]` sleeps then a last attempt: same count, but a mismatch of the two store.jl consts now throws `BoundsError`.
- Internals renamed (only my files used them): `fill_attachment!` → `fetch_into_cache`, `confirm!` → `write_confirmed_marker`, `attachment_cache_path(cache, h)` → `attachment_cache_path(chain, hash)`, `_request!/_respond!/_next!/_shuffle!` → `begin_request!/end_request/next_random!/shuffle_listing!`; `changed`, `outlasted`, `damaged_entry`, `changed_entry`, `size_mismatch`, `absent_for_reader`, `gone_from_store`, `check_attachment_hash`, `attachment_problem` removed.
- The gateway double's presigned signature is a hash of key and grant count, not random.

## 4. Errors change requests; renames others use

- `GatewayMismatchError`: a way to say "the gateway minted a malformed URL or headers: redeploy it" (a new type, e.g. `GatewayMintError`, or a `reason` field with its own next move). Cases: URL elsewhere, no query, a missing/wrong/duplicate checksum, if-none-match or content-length header, no lifetime.
- `WRITE_REFUSED_NEXT_MOVES`: add `"no_mint_route"` (redeploy the gateway, gateway/deploy.sh) and `"s3_refused"` (the gateway's deployment is wrong; report it to the bucket's operator).
- `AttachmentURLExpiredError`: Evidence fields `seconds` (URL life), `ran` (seconds), `capped::Bool`; now in `detail`.
- `AttachmentCacheError`: Evidence fields `found` (hash of the cached file), `recorded` (sidecar text), `size`; now in `detail`.
- `AttachmentAbsentError`: a `keys` field for `repair!`'s several gone attachments; now `key = nothing` and the keys in `detail`.
- `AttachmentDigestError` from a size mismatch: a `cached_size` field; now in `detail`.
- No name used by other files was renamed (`verify_attachments`, `repair_attachments!`, `bare_url`, `attachment_key`, `checksum_sha256`, `mint`, `upload_minted`, `fetch_object_to` keep name and arity).
