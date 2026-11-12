# NOTES-D: s3.jl, gateway.jl, bucket.jl, test/fixtures/s3_server.jl

## 1. Guide log (`file:line | Rule/Default | unclear/wrong/blocked | choice made`)

BLOCKED first.

- src/http.jl:31 | test_quality ExplicitImports `check_all_qualified_accesses_are_public` | BLOCKED | `Downloads.Curl.setopt` and `CURLOPT_*` are not public, but they are the only way to refuse redirects and set the stall and deadline limits of a streamed transfer. Kept the qualified access. Proposed: test_quality passes `ignore = (:Curl, :setopt, :CURLOPT_FOLLOWLOCATION, :CURLOPT_LOW_SPEED_LIMIT, :CURLOPT_LOW_SPEED_TIME, :CURLOPT_TIMEOUT_MS)` to that check, or the Guide adds a Breakable Rule for a non-public dependency API.
- src/sso.jl:75,136,160,200,202 | Errors: an operational failure throws the package's own type; `error(…)` is banned | BLOCKED | No own error type covers a failed SSO export or login, a missing AWS CLI or an unreadable export. These now throw `ArgumentError`, which is never retried, like the old `ErrorException`. Proposed: the lead adds `CredentialsError <: ChainTablesError` (`profile`, `detail`) to errors.jl, and these sites switch to it.
- test/fixtures/s3_server.jl:28, test/fixtures/gateway_server.jl:21,93,231 | testing.md Rule: fixtures hold only consts and pure functions | BLOCKED (the Rule and the `with_<resource>(f)` Default conflict) | Kept the server types (`S3TestServer`, `LoopbackServer`, `GatewayDouble`, `StsDouble`) and the socket-serving functions, because a `with_<resource>` helper needs them. Added `with_s3_server`, `with_loopback_server` and `with_gateway_doubles`, and every new test goes through them. Proposed: the Rule allows the types and functions behind a `with_<resource>` helper.
- src/s3_store.jl:176 | Rule: no `@warn` in src | Rule followed, behaviour change | `open` no longer warns once per process that a store which is not AWS will refuse commits; the refusal at `commit!` and `create_chain` is now the only signal. `warn_unsupported_store(chain) = nothing` stays only for localcopy.jl's call. Proposed: delete that call and the stub at merge. The user should confirm losing the warning.
- src/s3_store.jl:40 | Breakable `field` | Rule broken, with its marker | `credentials::Any`, because it holds a `Credentials` or any callable. A type parameter would make `Chain{S3ObjectStore}` and `Chain{GatewayObjectStore}` abstract, and test/live checks `chain isa Chain{GatewayObjectStore}`. Marker: `# style: field`.
- src/s3_store.jl:78, src/gateway.jl:93 | interfaces.md Default: `show` output is valid Julia `T(args…)` | Default doesn't fit | Kept the keyword form `S3ObjectStore("bkt"; region = …)`. The default `show` would print the credentials supplier, and printing the credentials is not allowed, so the output can't rebuild the value. Fields are now written with `show`, not `repr`.
- src/bucket.jl:26 | interfaces.md Default: define `show` only when the default is unreadable or leaks a secret | Default followed | Removed `Bucket`'s custom `show`. The default positional form still evaluates back to an equal value.
- src/credentials.jl:88 | interfaces.md Default: `convert` is not a constructor alias | Default followed | Removed both `Base.convert(::Type{Credentials}, …)` methods; added `to_credentials(x)`.
- src/sso.jl:14 | Rule: no named function inside a function / Default: use a callable struct when you return a function that holds state | Default followed | `sso_credentials` returns `SSOCredentials{…} <: Function`, so it stays `isa Function` for downstream code and for `Chain`'s `methods(credentials)` check.
- src/http.jl:25 | same Rule | Default followed | The libcurl hook is the callable struct `StreamOptions <: Function`, because the `Downloader.easy_hook` field is typed `Function`.
- src/http.jl:140 | Errors Rule: no function returns an error object | Rule followed | `failure(method, url, response)` now throws its `TransportError` itself. attachments.jl's `throw(failure(…))` still works, because `failure` throws before `throw` runs.
- src/http.jl:112 | Errors Rule: cleanup never uses catch-and-rethrow | Rule followed | `fetch_object_to`'s `catch; rm; rethrow()` became `with_partial_file_removed(f, path)`, which uses `finally`.
- src/sso.jl:46 | types_and_dependencies.md: never name a keyword `now`; a clock function only when the body reads the time repeatedly | Rule/Default followed | Renamed the `sso_credentials` keyword `now` to `clock`; only tests set it.
- src/sigv4.jl:94, src/s3_store.jl:204 | the same Default (a timestamp keyword is named `at`) | Default followed | Renamed `signed_headers`/`request_headers` keyword `now` to `at`. No caller outside these files and tests passed it (checked attachments.jl and test/live).
- src/sso.jl:46, src/sso.jl:191 | Default: no keyword that no caller sets | unclear | Kept the test seams `exporter`, `clock`, `login_with`, `interactive`, `setting` and `runner`, each with a comment saying tests need a fake CLI or clock. The Examples files set `exporter` and `runner`.
- src/sso.jl:187 | Rule: one docstring per function name | Rule followed | `sso_login` has methods in sso.jl and bucket.jl, so its docstring sits on `function sso_login end` and covers both forms. `is_aws`: same, on `function is_aws end` in s3_store.jl.
- src/s3_store.jl, src/gateway.jl, src/gateway_author.jl | Rule: one docstring per function name | Rule followed | Removed the docstrings from my methods of `fetch_object`, `put_object_if_absent`, `stat_object`, `list_objects`, `record_author` and `cache_namespace`; store.jl documents those functions. The gateway put's status table is now a comment.
- all src docstrings | Rule: no ADR reference and no `(@ref)` in a docstring | Rule followed | ADR references moved to comments or were dropped.
- src/bucket.jl:31, chain.jl `check_bucket_name`, src/s3_store.jl | Default: small types for domain values | Default not applied | A bucket name is checked in three places. A `BucketName` type would cross into agent C's chain.jl, so it was left for the lead.
- test/test_sigv4.jl, test/test_dates.jl, test/test_gateway_reply.jl, test/test_http.jl, test/test_gateway_author.jl (`author_from_arn`) | testing.md Default: test through API names; a seam with independent reference values becomes an API name | Default doesn't fit | These tests call internals (`sign_request` against AWS's worked examples, dates, JSON escapes, streaming), each file with a why comment. Making `sign_request`/`json_unescape` public needs the public line, which only the lead edits.
- test/*.jl | testing.md: `@test_throws` takes 3 arguments; no `@test all(…)` | Rule followed | Every old `try … catch e; e end` became `(@test_throws T "msg" expr).value`. Every `all(...)` became a table-driven testset or single assertions.

## 2. Old → new files

- src/s3.jl → src/credentials.jl (Credentials, environment, resolve and current credentials), src/sso.jl (sso_credentials, SSOCredentials, sso_login, export parsing), src/dates.jl (civil dates, amz_date, HTTP and ISO dates), src/sigv4.jl (uri_encode, query strings, sign_request, signed_headers), src/http.jl (http_request, http_stream, StreamOptions, failure, xml_unescape, with_partial_file_removed), src/s3_store.jl (S3ObjectStore, endpoints, is_aws, cache_namespace, the AWS-only gate, request_headers, s3_request, the four verbs, fetch_object_to)
- src/gateway.jl → src/gateway.jl (GatewayObjectStore, the put, the refusal details), src/gateway_reply.jl (gateway_reply, json_unescape), src/gateway_author.jl (record_author, STS, author_from_arn)
- src/bucket.jl → src/bucket.jl
- test/s3.jl → test/test_credentials.jl + test_credentials_examples.jl, test_sso.jl + test_sso_examples.jl, test_sigv4.jl, test_dates.jl, test_http.jl, test_s3_store.jl + test_s3_store_examples.jl, test_unsupported_store_workflow.jl. The plain-bucket `put_attachment` testset is attachments' (agent E).
- test/gateway.jl → test/test_gateway.jl + test_gateway_examples.jl, test_gateway_author.jl, test_gateway_reply.jl, test_gateway_commit_workflow.jl. The mint/upload/`expected_attachment_url`/`fetch_object_to` gateway testsets are attachments' (agent E). The InMemoryObjectStore `record_author` cases belong to store.jl.
- test/bucket.jl → test/test_bucket.jl + test_bucket_examples.jl
- test/fixtures/s3_server.jl → test/fixtures/s3_server.jl, plus a new test/fixtures/gateway_server.jl that holds the gateway and STS doubles from old test/gateway.jl (`LoopbackServer`, `loopback_url`, `GatewayDouble`, `gwtest_json`, `gwtest_minted`, `gwtest_mint`, `gwtest_check_signature`, `StsDouble`, `with_loopback_server`, `with_gateway_doubles`). Kept: `S3TestServer(; bucket, credentials, region, page_size)`, `close`, `s3test_endpoint`, `s3test_error`, `s3test_percent_decode`, and the fields `objects modified requests presigned respond page_size port bucket`. Added: `with_s3_server`, `s3test_refusal`, `s3test_store!`. The fixture now holds its own `using` lines. Old `gwtest_sts(creds, region, arn)` is now `StsDouble(creds, region, arn)`. `GatewayDouble`'s 6-argument positional form still works, and there is a new 4-argument form `(s3, creds, caller, policy)`.

## 3. Behaviour changes

- `open` of a chain whose store is not AWS no longer logs a warning (`@warn` is banned); commits still refuse.
- `show(Credentials)`: `Credentials("id", "***"; session_token = "***")` (was `<redacted>`).
- `show(Bucket)`: the default positional form `Bucket("bkt", "eu-north-1", nothing, "team")` (was the keyword form).
- `convert(Credentials, x)` no longer works; `Chain` still accepts a NamedTuple with key properties.
- `sso_credentials(…)` returns an `SSOCredentials` callable struct (still `isa Function`). Keyword `now` → `clock`. A test exporter now returns `(; ok, text)` instead of throwing.
- SSO export/login/CLI-missing failures throw `ArgumentError` (was `ErrorException`), with the same message fragments.
- `sso_login` runs the CLI with `success(cmd)`; a non-zero exit reads "… failed: the CLI exited non-zero".
- `signed_headers`/`request_headers` keyword `now` → `at`.
- `TransportError` detail drops "HTTP <status>", since `status` is evidence: `GET <url>: <Code>: <Message>`. "no response —" → "no response:".
- `WriteRefusedError`/`GatewayMismatchError`/`UnsupportedStoreError` take keyword construction with a short `detail`; the long next-move texts are now the lead's `showerror`. Lost hints: forbidden → "expired or revoked credentials / clock skew"; s3_refused → "report it to the operator" (see section 4).
- `refusal_message(store, key, reason, message; mint)` returns a short `detail`, not a full message.
- `failure(method, url, response)` throws instead of returning a `TransportError`.
- `unsupported_store` and `refuse_unsupported_store` take `chain::Chain` (were untyped).
- `http_stream`'s deadline message: "deadline is X seconds; must be positive".
- `S3ObjectStore` timeout message: "timeout is X; it must be positive".
- No `==`/`isequal` was added, so no `hash` was needed (`Credentials` and `Bucket` use the default `===`).

## 4. Errors change requests; renamed shared names

- `TransportError`: Evidence fields `method`, `url` and `code` (the S3 or gateway error code). They are in `detail` for now.
- `WriteRefusedError`: Evidence field `gateway` (the function URL), now in `detail`. Next moves: `forbidden` should also name expired or revoked credentials (`aws sso login`) and a clock off by over 5 minutes. Add `s3_refused` → "The gateway's deployment is wrong; report it to the bucket's operator." Unknown reasons: the fallback is fine.
- New `CredentialsError <: ChainTablesError` (`profile`, `detail`) for SSO export and login failures (see BLOCKED).
- Renamed shared names: none. Changed keyword: `now` → `at` on `signed_headers`/`request_headers` (no outside caller).
- Duplicate: `url_without_query` (http.jl) is the same function as attachments.jl's `bare_url`; keep one at merge.
