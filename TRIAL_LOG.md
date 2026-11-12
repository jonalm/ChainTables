# Trial log

Trial of Guide `trial-777a0df` (codestyle `777a0df`) on ChainTables, branch
`trial/guide-777a0df` cut from `1e1d300`. Append-only. Ground rules:
jonalm/julia_codestyle#44.

## Baseline (before any change)

Julia 1.13.2, aarch64 macOS. ChainTables `1e1d300`, BioMeCore `dff75ef`
(BioMeFrontend included), each suite run with `Pkg.test()` after
`Pkg.instantiate(); Pkg.precompile()`. Wall time = the `Pkg.test()` call (it
includes the test env's resolve and precompile). BioMeCore and BioMeFrontend
`Pkg.develop` this worktree at `1e1d300`.

| Suite | Result | Passes | Wall time |
|---|---|---|---|
| ChainTables `1e1d300`, non-live (`test/live/` excluded by the runner) | pass | 2981 | 106.9 s |
| BioMeCore `dff75ef` vs ChainTables `1e1d300` | pass | 22808 | 57.6 s |
| BioMeFrontend `dff75ef` vs ChainTables `1e1d300` | pass | 355 | 40.1 s |

No failures, no broken tests. BioMeFrontend logs `@error` output from its
injected-fault tests (`network down`); these are expected and pass.

TestConventions precheck: `Pkg.add("TestConventions")` from BioMeRegistry
(`0921a36`, v0.1.0, tree `f1e4fce` = `777a0df:TestConventions`) in a throwaway
env, then `using TestConventions`: pass.

## Rewrite

Wall time and tokens: (recorded by the rewrite session)

Line format: `file:line | Rule/Default | unclear/wrong/blocked | choice made`

### Sessions

The trial ran over two sessions. Session 1 (lead + five rewrite agents A–E, worktree
clones `wip-A..E` merged by the lead) was stopped by the user mid-integration and left a
handover; session 2 finished it.

| Session | Start | End | Tokens |
|---|---|---|---|
| 1 | 2026-11-12 12:26:03 CET | ~13:25 CET | not recorded (the user has no count) |
| 2 | 2026-11-12 13:27:54 CET | 2026-11-12 13:45:24 CET | not recorded (the user has no count) |

The agents' raw notes (`trial_notes/AGENT_BRIEF.md`, `NOTES-{A..E}.md`, first full-suite
log) and `HANDOVER.md` are in commit `3ddeb20`; their content is carried below and the
files are deleted from the tree.

### Decisions made by the user (session 2)

The three Rules that blocked session 1 were put to the user:

- `test/fixtures/*.jl | testing.md Rule: fixtures hold only consts and pure functions, vs the Default: a stateful fixture is a with_<resource>(f) helper | wrong (Guide inconsistency) | user: allow stateful test doubles, with_<resource> helpers and the types behind them in test/fixtures/. Applied: D's and E's doubles stay; E's gateway_double.jl merged into D's gateway_server.jl; C's with_chain/with_seeded/with_copy (copied into 8 test files) plus chain_over, commit_samples!, commit_three!, create_keyed!, declare_samples! moved to the new test/fixtures/seeded_chains.jl`
- `src/local_copy.jl choose_head | Rule: no @warn in src/ | blocked | user: drop every @warn in src/. B's warning when open falls back to a lower head removed (behaviour change); test now asserts no log`
- `src/s3_store.jl warn_unsupported_store + src/local_copy.jl open | Rule: no @warn in src/ | blocked | user: drop. Stub and its call deleted (the warning itself was already gone in session 1; behaviour change)`
- `test/test_quality.jl | ExplicitImports check_all_qualified_accesses_are_public | blocked | user: ignore list limited to the Tables.jl interface (Schema, columnaccess, columns, istable, rowaccess, rows, schema) and Downloads.Curl (Curl, setopt, CURLOPT_FOLLOWLOCATION, CURLOPT_LOW_SPEED_LIMIT, CURLOPT_LOW_SPEED_TIME, CURLOPT_TIMEOUT_MS). No other non-public access was flagged, so nothing else to remove`

### Cases

Line format: `file:line | Rule/Default | unclear/wrong/blocked | choice made`. Lines
marked BLOCKED were resolved by the user decisions above.

Lead, session 1:

- `test/live/*.jl | Runic step vs "leave test/live untouched" | unclear | ran runic --inplace . literally; 3 live files reformatted, nothing else touched there`
- `test/Project.toml | testing.md Shared test package ([sources] url/rev) | wrong (known Guide gap) | TestConventions v0.1.0 from BioMeRegistry per trial instruction`
- `.github/workflows/CI.yml | testing.md every Package root tested by CI | unclear | floor 1.13; CI cannot resolve TestConventions without access to the private BioMeRegistry; not fixed`
- `src/ChainTables.jl | layout.md no internal namespacing submodules | unclear | Model flattened; CBOR (a seam with an independent corpus) and Ops (test/live calls GWT.Ops.decode_record) made public submodules`
- `src/ChainTables.jl | layout.md public by default | unclear | ~80 public names: the 29 BioMe names plus documented API, all error types, store verbs for implementers`
- `src/errors.jl | Errors: Evidence fields, optional detail | unclear | every own type has keyword constructor, Union{Nothing,T} Evidence and detail::String; print_summary/print_evidence helpers; one showerror per type`
- `src/errors.jl CommitOutcomeUnknownError.cause | Default no cause field; Rule no function stores an error object | unclear | kept (BioMeCore reads .cause) with reason comment + # style: field; read the Rule as about functions, the Default as governing fields`
- `src/errors.jl TransportError, ModelError, CBOR.DecodeError, HeadRejected | Rule: every own error type subtypes <Pkg>Error | — | now ChainTablesError; behaviour change: catching ChainTablesError now also catches transport failures`
- `src/errors.jl CredentialsError | Rule: operational failure throws own type; no error() | — | new public CredentialsError for SSO/CLI/env credential failures (were ErrorException)`
- `src/errors.jl GatewayMismatchError | one type, one showerror | unclear | also covers a malformed mint (E); summary and next move broadened instead of a new type`
- `test/fixtures/gateway.jl | layout.md no as aliases; fixtures only consts and pure functions | unclear | kept const GWT = ChainTables and const gwtest_record alias, used by test/live`
- `test/data/cbor_corpus | Guide term Conformance test; Default data in test/data/ | — | renamed from test/conformance`
- `test/test_live_suite_workflow.jl | Default one test file per src file | — | old live_calls test kept as a workflow test`
- `src/*.jl # style: inferred | marker on the line above the construct | unclear | a comment between a docstring and its function detaches the docstring; agents A/B put the marker above the opening """`
- `src/commit.jl catch | Rule: catch body starts with e isa T || rethrow() | unclear | commit outcome contract needs every exception after the put began: e isa Exception || rethrow() (filters nothing)`
- `src/*.jl throws | Rule: throw ≤ 3 lines | unclear | errors with 6–7 Evidence fields bound as evidence = (; …) then throw(T(; evidence...))`

Lead, session 2:

- `test/test_*.jl const CT = ChainTables (also SIGNER, HTTP, DATES; GWT in fixtures/gateway.jl) | layout.md Rule: no as aliases | unclear | read literally (bans `as`); the const aliases the agents wrote are kept`
- `src/http.jl url_without_query, src/attachments.jl bare_url | Default: one concept per file / no duplicate helpers (merge) | — | the same function twice after the merge; kept url_without_query, bare_url deleted`
- `test/fixtures/gateway_server.jl gwtest_minted | testing.md Rule: every random call takes StableRNG | unclear | D's signature hashed time_ns(); took E's deterministic form (key and grant count)`
- `test/test_*_examples.jl | testing.md Rule: Examples files use only public names (ExplicitImports public checks run on them) | — | each of the 29 Examples files ends with a testset running check_all_explicit_imports_are_public and check_all_qualified_accesses_are_public on its own module and file; all pass with no ignore list`
- `test/test_tracked_values.jl | — | — | the tripwire asserted isdir(".git"); in a git worktree .git is a file: ispath`
- `src/errors.jl, src/local_copy_errors.jl, src/attachment_errors.jl | Rule: an own error type holds Evidence fields | unclear | the agents' requested Evidence fields (RewrittenChainError location/path; FingerprintMismatchError path; WriteRefusedError location/gateway; GatewayMismatchError location; TransportError method/url/code; AttachmentURLExpiredError seconds/ran/capped; AttachmentCacheError found/recorded/size; AttachmentAbsentError keys; AttachmentDigestError cached_size; WrongChainError slot; LocalCopyInconsistentError table; WriteBuilderError size/cap) were not added (handover step marked optional); the values stay in detail`
- `src/sso.jl export_attempt | Rule: a catch body starts with e isa T || rethrow() | unclear | the exporter seam may throw anything (BioMeCore's fakes throw ErrorException), so e isa Exception || rethrow(), as in commit.jl. Found by the BioMeCore run: D had changed the exporter contract to return (; ok, text), which broke BioMeCore's lab_tables test (2 fail, 1 error); restored "return the text or throw" (a100664)`
- `test/test_cbor_encode.jl:414-458 | Rule: no line over 92 columns, except a line holding just one string literal | unclear | lines holding one hex literal plus the trailing comma read as exempt (as A did)`

Agent A (record format core: hashes, CBOR, model, Ops, error tests):

- src/CBOR/decode.jl:47 | `# style: inferred` marker "on the line above the definition" | unclear | A comment between the docstring and `function` detaches the docstring (`Docs.undocumented_names` flagged `decode`). Marker put above the opening `"""`, as for `docstring-length`.
- src/CBOR/decode.jl:61 | Boundary function never returns `Dict{String,Any}`; no `Dict{String,Any}`/`Vector{Any}` in signatures | unclear | `CBOR.decode` is a generic codec, not a Boundary function: it returns `Dict{String,Any}`/`Vector{Any}` by nature (return values, not signatures). The Boundary functions on top (`decode_record`, `read_table`, `Shape(wire)`, `op_from_wire`) turn it into typed structs. Marked `# style: inferred`.
- src/Ops/op.jl:132, src/shape.jl:72 | same | unclear | `wire`/`shape_wire` keep returning `Dict{String,Any}` (input to `encode`, return value only).
- src/Ops/op.jl:6 | no `Vector{Any}` in fields | unclear | `Vector{Vector{Any}}` is not literally `Vector{Any}`; read it as forbidden and typed cells as `Cell = Union{Missing,Int64,Float64,String,Vector{UInt8}}` (`AddColumn.fill::Cell`, rows/keys `Vector{Vector{Cell}}`). Behaviour change, see 3.
- test/test_shape.jl:2 (and test_row_checks, test_table, test_content, test_table_file, test_fingerprint, test_ops_op, test_ops_record, test_ops_record_bytes, test_ops_apply) | Default: test through API names | Default does not fit | The model and Ops internals carry the format's spec and frozen literals (state_fingerprint, transaction_hash, table hashes). Tested directly, reason comment above the `using`. Proposal: per testing.md's seam rule, make `Ops.apply!`, `Ops.transaction_hash` and a `state_fingerprint` public (the lead owns the public lists).
- src/Ops/record.jl:52,96 | Default ≤ 4 positional arguments | Default does not fit | `Client` (5) and `Record` (7) mirror the envelope field for field; chain.jl calls them positionally. Reason comments added.
- src/model_error.jl:9 | own error type holds Evidence fields | unclear | `ModelError` has none: every caller folds its `detail` into another error's detail (`WriteBuilderError`, `MalformedRecordError`, `ArgumentError` in views/localcopy), so table/column/key stay in `detail`.
- src/model_error.jl:27 | Guard is `cond || throw(...)`; Default: no pass-through helper | Default does not fit | `fail(detail)` kept for builder.jl, localcopy.jl, recovery.jl (other agents). My files throw `ModelError(; detail)` directly.
- src/Ops/apply.jl:64 | Default: `try` only in a Boundary function | Default does not fit | Translating the model's rule into the `MalformedRecordError` of the record that broke it needs the record's slot and op index. Reason comment added.
- src/Ops/record_bytes.jl:171 | `detail` never repeats Evidence | unclear | `decode_record` cannot set `op` Evidence for an op that fails to read without translating per op with the slot in hand; the op index stays in `detail` as `op i: …`. `apply!` sets `op` Evidence and leaves it out of `detail`.
- src/Ops/record.jl:16-18, src/CBOR/encode.jl:5 | ADR references only in comments | unclear | Some refusal messages contain `(ADR-NNNN)`. Messages are neither docstrings nor file headers; text kept so pinned messages do not move.
- src/* (many) | `throw(…)` ≤ 3 lines + 92 columns + keyword constructors | unclear (costly) | Long messages need consts (`NOT_COLUMN_NAME`, `GOT_TYPE`, …) or small `*_text(…)` helpers called inside `throw`, so the non-throwing path does not allocate. Runic expands a split `detail =` to 5–6 lines, so `*`-splitting inside the throw is not available.
- src/hashes.jl:73 | no fallback method on a broad abstract type | unclear | `hash_bytes(::Type{T}, x)` refuses anything else with the pinned message ("is 32 bytes or 64 hex characters, got a value of type …"); kept, comment says why.
- src/Ops/record.jl:87 | Default: small types for domain values | Default does not fit | `Record.prev_hash`/`state_fingerprint` stay `Vector{UInt8}`: localcopy.jl and chain.jl read them as bytes (`Vector{UInt8}(…)`).
- src/table_file.jl:12 | Conformance test for a type implementing a Base interface | unclear | `HashingIO <: IO` implements `write`/`unsafe_write`; testing.md's laws do not cover IO. No Conformance test; covered by `write_table` returning `table_hash`.
- test/test_cbor_encode.jl:1 | file ≤ 400 lines (Default) | Default does not fit | 484 lines: the 96-case frozen corpus belongs with the encoder it freezes. Reason comment at the top.
- test/test_cbor_encode.jl:400-460 | line ≤ 92 unless it holds just one string literal | unclear | Long frozen hex literals sit alone on a line followed by the call's trailing comma; read as exempt.
- test/test_shape.jl etc. | `@test_throws` 3-argument form vs 92 columns | unclear | Long ones written as `@test_throws(T, "msg", expr)` over several lines.

Agent B (builder, local copy, views):

- src/local_copy.jl:259 | Rule: no `@warn` in src/ | BLOCKED | `open`'s fall-back to a lower head still warns (the old test pinned the warning). Proposed: record the fall-back on the copy (e.g. a field read by an accessor) or accept a Breakable `warn` marker; or drop the warning. Resolved: user decision 2, warning dropped.
- src/chain.jl:6 | Rule: all `using` in the Module file | BLOCKED (not my file) | the old localcopy.jl held `using .Ops: Record`, which chain.jl relies on. A `using .Ops: …` cannot sit in the Module file before `include("ops.jl")`. To keep the clone running I extended chain.jl's own line to `using .Ops: Client, Record`. Proposed: chain.jl owner qualifies `Ops.Record` (and `Ops.Client`). Resolved: at merge, chain.jl qualifies Ops names; no `using` outside Module files.
- test/test_quality.jl | Rule: qualified accesses are public (ExplicitImports) | BLOCKED (lead's file) | Tables.jl declares no `public` names, so every `Tables.istable`/`Tables.columns`/… method in src/table_view.jl is flagged. Implementing the Tables.jl interface needs them. Proposed: an `ignore` list for Tables in test_quality.jl. Resolved: user decision 3.
- src/views.jl:1, src/local_copy.jl:2 | Rule: `# style: inferred` on the line above the definition | unclear | a marker between docstring and `function` detaches the docstring (`table` became undocumented). Marker put above the opening `"""`.
- src/local_copy.jl:2 | Rule: constructors of public types have an inference test | blocked-by-design | `LocalCopy`'s field constructor is never called by users; marked `# style: inferred`, `open` has the inference test.
- src/table_view.jl:52 | same, `TableView(name, head, table)` | the column types come from the table at run time; marked `# style: inferred`. `table` likewise (src/views.jl:1).
- src/table_view.jl:1, src/local_copy.jl:1/31 | Default: docstring ≤ 8 lines | does not fit | reason comment above; all ≤ 20.
- src/table_view.jl:140 | Default: one split in one place stays if/elseif | does not fit | `lookup_key` dispatches on NamedTuple/Tuple/other: each case is a Guard and a return, which if/elseif would nest (`return` inside a block is Kernel-only). Reason comment above.
- src/table_view.jl:132 | Default: 2-arg `show` prints valid Julia | does not fit | valid Julia would spell out every row; kept the one-line summary, reason comment above.
- src/table_view.jl:57 | Default: Guard lengths before `map(f, xs, ys)` | does not fit | a model Table has one vector per shape column by construction; comment above instead of a Guard.
- src/table_view.jl:20 | Default: a field users must read gets an accessor | unclear | users read `v.name`, `v.slot`, `v.chain_id`, `v.transaction_hash`, `v.columns`; accessors would be new public names (the public list is the lead's). Fields kept and named in the docstring.
- src/table_view.jl:32 | Rule: no `Dict{String,Any}`/`Vector{Any}` fields | unclear | `index::Dict{Any,Int}` is neither; kept (keys are cell tuples of mixed type).
- src/builder.jl:270 | Default: `try` only in a Boundary function | does not fit | `guarded` translates the model's `ModelError` into `WriteBuilderError` at every op entry; kept, why-comment above.
- src/head_file.jl:57 | errors decision: Evidence fields `Union{Nothing,T}` | unclear for an internal type | `HeadRejected.kind::Symbol` is a required keyword (`:not_ours`/`:layout`/`:damaged`, the one case split in `read_head_file`), plus `detail`. One `showerror` added.
- src/head_file.jl:156, src/table_files.jl:170 | Rule: build the exception only as the argument of `throw` | unclear | `reject_head` and `throw_damaged_table` are throwing helpers (like model.jl's `fail`); each builds the error inside `throw`.
- test/test_row_sets.jl:228 | Default: test through API names | does not fit | the canonical form of an op (row and key order) is visible only in the builder's internal `ops`; those 3 testsets read `w.ops`, why-comment above.
- test/* | Rule: fixtures hold only consts and pure functions | does not fit for shared helpers | each test file defines its own `with_…` helper (mktempdir + chain + copy); some duplication across files.
- src/local_copy.jl:172 | Rule: a Guard condition has no `!` | — | `ispath(p) && !isdir(p)` moved into the predicate `is_non_directory`.

Agent C (store, chain, sync, commit, recovery):

- src/commit.jl put_or_unknown!, write_commit_head! | Rule: a catch starts with `e isa T || rethrow()` | unclear | the commit-outcome contract (BioMeCore) needs every exception after the put began, so the first line is `e isa Exception || rethrow()`, which filters nothing; then `is_known_unwritten(e) && rethrow()`
- src/record_cache.jl heal_record! | Rule: no `@warn` in src | wrong? | dropped the warning when a damaged cache file is replaced (old tests pinned it); no other channel exists in the Guide except `depwarn`; behaviour change below
- src/sync.jl, src/verify.jl, src/repair.jl, src/commit.jl (evidence NamedTuples) | Rule: a `throw(…)` is ≤ 3 lines; build the exception only as the direct argument of throw | unclear | errors with 6–7 evidence fields do not fit 3 lines at 92 columns; bound `evidence = (; …)` then `throw(T(; evidence...))`. Possibly against the spirit; an outer constructor in errors.jl (lead's) would be cleaner
- src/store.jl cache_namespace | Default: no fallback method on a broad abstract type | Default does not fit | kept the `::AbstractObjectStore` method that throws `ArgumentError` naming what to define: old behaviour, and `Chain` construction relies on it to refuse a store
- src/as_of.jl target_slot(chain, ::StateFingerprint), target_slot(chain, target) | Default: no fallback method | Default does not fit | kept, with reason comments: a user passing a fingerprint or a hash's bytes gets a message naming the right address types, not a MethodError
- src/record_cache.jl record_path | Default: small types for domain values (bucket and key Strings side by side) | Default does not fit | reason comment; a key type would reach every store method
- src/commit.jl put_commit_record!, commit_record | Default: ≤ 4 positional arguments | Default does not fit | 5 each, reason comments; they are the record's inputs
- src/chain.jl show(::Chain) | Default: 2-arg show prints valid `T(args…)` | unclear | kept the old output `Chain("bkt", "p"; store = InMemoryObjectStore)` (store's type name, not a value); reason: credentials must not be shown
- src/read_forward.jl read_forward | Default: keywords that come together become one `Union{Nothing,T}` | applied | `prev`, `chain_id`, `holder` → `parent::Union{Nothing,ParentLink}` (the Guide's own example); `tail` dropped (no caller needs it once the next move is in showerror)
- src/read_forward.jl `keep_bytes`, src/sync.jl replay! `clock` | Default: no keyword no caller sets | kept | tests set them (re-read path, scripted checkpoints), comments say so
- src/*.jl docstrings over 8 lines (Chain, create_chain, read_forward, sync!, commit!, verify, repair!, as_of, commit_log) | Default ≤ 8 | Default does not fit | reason comment above each `"""`; whether blank lines count is unclear (I counted them)
- test/test_sync.jl, test/test_commit.jl | Default: file ≤ 400 lines | Default does not fit | ~450 lines each; reason comment at the top
- test/fixtures/chains.jl forged_chain | testing.md "the one loop allowed in tests" | unclear | whether it covers a fixture builder with no assertion; kept one `for` (each record names the previous one)
- test/*.jl `with_chain`, `with_seeded`, `with_copy` | Rule: fixtures hold only consts and pure functions | unclear/wrong? | stateful `with_…` helpers are duplicated in each test file (8 files), since they may not live in fixtures/
- test/test_record_cache.jl, test_put_record.jl, test_read_forward.jl, test_chain.jl (gallop, expected_chain_id), test_verify.jl (walked_record_at) | Default: test through API names | Default does not fit | internals tested where the behaviour is not observable through an API name (cache paths, retry counts, keep_bytes, probe counts); comment at each file's top
- test/test_tracked_values.jl | testing.md file names | unclear | a repository tripwire, not a src stem; named `test_tracked_values.jl`. It now fails outside a git checkout instead of skipping with `@info` (testing.md: a group never skips; fail-fast)
- test/test_store.jl `@test_throws MethodError "no method matching …"` | Rule: 3-argument `@test_throws` | applied | MethodError message fragment used
- CommitOutcomeUnknownError `cause` field vs Default "no cause field" | lead's errors.jl | noted only; downstream contract

Agent D (S3 client, SSO, SigV4, HTTP, gateway, Bucket):

- src/http.jl:31 | test_quality ExplicitImports `check_all_qualified_accesses_are_public` | BLOCKED | `Downloads.Curl.setopt` and `CURLOPT_*` are not public, but they are the only way to refuse redirects and set the stall and deadline limits of a streamed transfer. Kept the qualified access. Proposed: test_quality passes `ignore = (:Curl, :setopt, :CURLOPT_FOLLOWLOCATION, :CURLOPT_LOW_SPEED_LIMIT, :CURLOPT_LOW_SPEED_TIME, :CURLOPT_TIMEOUT_MS)` to that check, or the Guide adds a Breakable Rule for a non-public dependency API. Resolved: user decision 3.
- src/sso.jl:75,136,160,200,202 | Errors: an operational failure throws the package's own type; `error(…)` is banned | BLOCKED | No own error type covers a failed SSO export or login, a missing AWS CLI or an unreadable export. These now throw `ArgumentError`, which is never retried, like the old `ErrorException`. Proposed: the lead adds `CredentialsError <: ChainTablesError` (`profile`, `detail`) to errors.jl, and these sites switch to it. Resolved: lead added public CredentialsError (48efcdc); these sites throw it.
- test/fixtures/s3_server.jl:28, test/fixtures/gateway_server.jl:21,93,231 | testing.md Rule: fixtures hold only consts and pure functions | BLOCKED (the Rule and the `with_<resource>(f)` Default conflict) | Kept the server types (`S3TestServer`, `LoopbackServer`, `GatewayDouble`, `StsDouble`) and the socket-serving functions, because a `with_<resource>` helper needs them. Added `with_s3_server`, `with_loopback_server` and `with_gateway_doubles`, and every new test goes through them. Proposed: the Rule allows the types and functions behind a `with_<resource>` helper. Resolved: user decision 1.
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

Agent E (attachments, Testing):

- test/fixtures/gateway_double.jl, gateway_attachments.jl, attachments.jl | Rule: fixtures hold only consts and pure functions | BLOCKED | Loopback servers, `with_gateway`, `created_chain` are stateful fixtures (the Default says a stateful fixture is a `with_<resource>(f)` helper, which contradicts the Rule; s3_server.jl has the same problem). Kept in fixtures/. Proposal: the Rule allows `with_<resource>` helpers and test doubles in fixtures/. Resolved: user decision 1; gateway_double.jl merged into gateway_server.jl.
- src/gateway_attachments.jl (check_minted_url, check_minted_header, NO_LIFETIME) | Errors: showerror writes the next move | wrong | `GatewayMismatchError`'s summary ("wrote to another bucket") and next move ("pair the bucket") do not fit a gateway that mints a malformed URL/headers/no lifetime (next move: redeploy it). Used it, the case in `detail`; see errors change requests.
- src/gateway_attachments.jl throw_mint_refusal | Errors | unclear | `WriteRefusedError` reasons `no_mint_route` and `s3_refused` get the fallback next move; see errors change requests.
- src/attachment_cache.jl cache_entry / heal_entry; src/attachment_repair.jl repair_entry | Default: repeated case split → types | Default doesn't fit | Kept Symbol states (`:absent/:ok/:stale`, `:ok/:absent/:changed/<hash>`, `:sound/:repaired/:gone`), each read in ≤ 2 places of 2 files; reason comment above.
- src/gateway_attachments.jl mint | Default: several return values → struct when passed on | Default doesn't fit | Kept two NamedTuples (`present`/`minted`): test/live reads `.code`, `.url`, `.seconds`, `.capped`, `.headers` on both.
- src/gateway_attachments.jl minted_reply, upload_minted | Default: timestamp is a keyword `at` | Default doesn't fit | Monotonic `time_ns()` read in place: a deadline read more than once; reason comment above.
- src/attachment_cache.jl read_attachment, src/attachment_repair.jl repair_attachments! | Default: no unset keyword | allowed case | `hasher` kept, comment "Test-only race injection".
- src/Testing/in_memory_object_store.jl `fault::Any` | Rule: fields concrete | Breakable | `# style: field users assign a fault function of any type at any time`.
- src/attachments.jl, attachment_cache.jl, attachment_repair.jl, Testing/in_memory_object_store.jl docstrings | Default: docstring ≤ 8 lines | Default doesn't fit | 5 docstrings of 9–18 lines, each with a reason comment above.
- test/test_gateway_attachments.jl + test_gateway_attachments_minted.jl | Default: one test file per src file vs ≤ 400 lines | unclear | Split src/gateway_attachments.jl's tests in two (526 lines); shared setup in fixtures/gateway_attachments.jl.
- test/test_attachment_cache.jl (gateway chain testset) | Rule: no warnings but `@test_logs` ones | unclear | s3.jl's `@warn` for a non-AWS endpoint (not my file) prints during `open`; not asserted, since s3.jl's rewrite must remove the `@warn`.
- src/Testing/Testing.jl | layout: module docstring, no Examples line | unclear | No separate `@testset "Testing example"`; `Testing` is used in test_testing_in_memory_object_store_examples.jl.
- src/gateway_attachments.jl, src/attachments.jl `throw(failure(...))` | Rule: no function returns an error object | unclear | `failure` is s3.jl's; called as before. If s3.jl drops it, build the `TransportError` inline at my 2 call sites.

### Old → new files

Merged or split files are shown as groups.

Lead:
- src/ChainTables.jl → src/ChainTables.jl (Module file only: docstring, using, public, includes)
- src/errors.jl → src/errors.jl, src/local_copy_errors.jl, src/attachment_errors.jl
- test/runtests.jl → test/runtests.jl (Guide template) + test/test_live_suite_workflow.jl (the old in-runner check that test/live's calls resolve)
- test/aqua.jl → test/test_quality.jl (Aqua, ExplicitImports, undocumented names)
- test/conformance/ → test/data/cbor_corpus/
- test/fixtures/gateway.jl → test/fixtures/gateway.jl (kept for test/live)
- (new) test/Project.toml, `[workspace] projects = ["test"]` in Project.toml
- session 2: test/fixtures/gateway_double.jl (E) merged into test/fixtures/gateway_server.jl (D); new test/fixtures/seeded_chains.jl (C's per-file helpers)

Agent A:
- src/hashes.jl → src/hashes.jl
- src/cbor.jl → src/CBOR/CBOR.jl (Module file), src/CBOR/profile.jl, src/CBOR/encode.jl, src/CBOR/decode.jl
- src/model.jl → src/model_error.jl, src/shape.jl, src/row_checks.jl, src/table.jl, src/content.jl, src/table_file.jl, src/fingerprint.jl
- src/ops.jl → src/Ops/Ops.jl (Module file), src/Ops/op.jl, src/Ops/record.jl, src/Ops/record_bytes.jl, src/Ops/apply.jl
- test/hashes.jl → test/test_hashes.jl, test/test_hashes_examples.jl
- test/cbor.jl → test/test_cbor_encode.jl (+ frozen corpus), test/test_cbor_encode_examples.jl, test/test_cbor_decode.jl, test/test_cbor_decode_examples.jl
- test/model.jl → test/test_shape.jl, test/test_row_checks.jl, test/test_table.jl, test/test_content.jl, test/test_table_file.jl, test/test_fingerprint.jl (frozen determinism vector)
- test/ops.jl → test/test_ops_op.jl, test/test_ops_record.jl, test/test_ops_record_examples.jl, test/test_ops_record_bytes.jl, test/test_ops_record_bytes_examples.jl, test/test_ops_apply.jl (frozen transaction_hash)
- test/errors.jl → test/test_errors.jl, test/test_errors_examples.jl, test/test_local_copy_errors.jl, test/test_local_copy_errors_examples.jl, test/test_attachment_errors.jl, test/test_attachment_errors_examples.jl. Dropped from it: `retryable` (store.jl's), `isabstracttype(AbstractObjectStore)` (store's), the `msg`-field assertions (obsolete).
- test/data/cbor_corpus/README.md: paths now name test/test_cbor_encode.jl.

Agent B:
- src/builder.jl → src/builder.jl (WriteBuilder, TableDeclaration, the op functions, spend!) + src/row_sets.jl (cells, row sets, name checks)
- src/localcopy.jl → src/chain_id_text.jl (base32 chain id) + src/head_file.jl (Head, HeadRejected, encode/decode) + src/local_copy.jl (LocalCopy, open, head, tables, pin, close, sweep) + src/table_files.jl (load_table!, stage!, write_head!, discard!, checkpoint!, hash_file)
- src/views.jl → src/table_view.jl (TableView, ReadOnlyColumn, Base/Tables.jl methods, table_with_slots) + src/views.jl (table, shape)
- test/builder.jl → test/test_builder.jl, test/test_row_sets.jl, test/test_builder_examples.jl
- test/localcopy.jl → test/test_chain_id_text.jl, test/test_head_file.jl, test/test_local_copy.jl, test/test_table_files.jl, test/test_local_copy_examples.jl
- test/views.jl → test/test_table_view.jl, test/test_views.jl, test/test_table_view_examples.jl, test/test_views_examples.jl
- Old tests dropped (internals): a scratch table holding rows (needs internal mutation; now an `AssertionError("BUG: …")`); `WriteBuilder(Content(); copy, head)` type parameters; `length(methods(write_builder)) == 1` and `commit!(WriteBuilder(Content()))` (chain.jl's); builder ops through `Ops.encode_record`/`decode_record` (replay of committed ops is tested instead); `open` reading no chain field (replaced: `open` makes no store call).

Agent C:
src:
- src/store.jl → src/store.jl (port: AbstractObjectStore, PutOutcome, ObjectMeta, the four verbs, record_cap, record_author, cache_namespace, retryable, PUT_ATTEMPTS) + src/record_cache.jl (RecordCache, default_cache_dir, record_path, fetch_record, heal_record!, cache_record!, path rules); `put_record!` → src/put_record.jl; `gallop` → src/chain.jl
- `abstract type AbstractObjectStore end` (src/ChainTables.jl) → src/store.jl
- src/chain.jl → src/chain.jl (Chain, checks, slot_key, location, expected_chain_id, gallop, chain_of, refuse_pinned, with_cleanup_on_failure, with_rollback) + src/put_record.jl (put_record!, put_record_for!, write_author, check_record_cap) + src/create_chain.jl + src/read_forward.jl + src/sync.jl (sync!, check_head_slot, check_head_record, replay!) + src/commit.jl (write_builder, commit!)
- src/recovery.jl → src/verify.jl (BackwardWalk, verify, walk_back, …) + src/repair.jl + src/as_of.jl (as_of, slot_at) + src/commit_log.jl
test:
- test/store.jl → test/test_store.jl, test/test_store_examples.jl, test/test_record_cache.jl (S3/gateway `cache_namespace` cases are s3.jl/gateway.jl methods: left to agent D)
- test/chain.jl → test/test_chain.jl, test_chain_examples.jl, test_create_chain.jl, test_create_chain_examples.jl, test_put_record.jl, test_read_forward.jl, test_sync.jl, test_sync_examples.jl, test_commit.jl, test_commit_examples.jl
- test/recovery.jl → test/test_verify.jl, test_verify_examples.jl, test_repair.jl, test_repair_examples.jl, test_as_of.jl, test_as_of_examples.jl, test_commit_log.jl, test_commit_log_examples.jl
- test/readme.jl → test/test_readme_workflow.jl
- test/tracked_values.jl → test/test_tracked_values.jl
- new fixture: test/fixtures/chains.jl (slotkey, forged_record, forged_chain, with_comment, with_fingerprint, flipped, SAMPLE_ROWS)
- dropped: the exact old message strings (new error format), `TransportError` showerror format checks (errors.jl, lead's)

Agent D:
- src/s3.jl → src/credentials.jl (Credentials, environment, resolve and current credentials), src/sso.jl (sso_credentials, SSOCredentials, sso_login, export parsing), src/dates.jl (civil dates, amz_date, HTTP and ISO dates), src/sigv4.jl (uri_encode, query strings, sign_request, signed_headers), src/http.jl (http_request, http_stream, StreamOptions, failure, xml_unescape, with_partial_file_removed), src/s3_store.jl (S3ObjectStore, endpoints, is_aws, cache_namespace, the AWS-only gate, request_headers, s3_request, the four verbs, fetch_object_to)
- src/gateway.jl → src/gateway.jl (GatewayObjectStore, the put, the refusal details), src/gateway_reply.jl (gateway_reply, json_unescape), src/gateway_author.jl (record_author, STS, author_from_arn)
- src/bucket.jl → src/bucket.jl
- test/s3.jl → test/test_credentials.jl + test_credentials_examples.jl, test_sso.jl + test_sso_examples.jl, test_sigv4.jl, test_dates.jl, test_http.jl, test_s3_store.jl + test_s3_store_examples.jl, test_unsupported_store_workflow.jl. The plain-bucket `put_attachment` testset is attachments' (agent E).
- test/gateway.jl → test/test_gateway.jl + test_gateway_examples.jl, test_gateway_author.jl, test_gateway_reply.jl, test_gateway_commit_workflow.jl. The mint/upload/`expected_attachment_url`/`fetch_object_to` gateway testsets are attachments' (agent E). The InMemoryObjectStore `record_author` cases belong to store.jl.
- test/bucket.jl → test/test_bucket.jl + test_bucket_examples.jl
- test/fixtures/s3_server.jl → test/fixtures/s3_server.jl, plus a new test/fixtures/gateway_server.jl that holds the gateway and STS doubles from old test/gateway.jl (`LoopbackServer`, `loopback_url`, `GatewayDouble`, `gwtest_json`, `gwtest_minted`, `gwtest_mint`, `gwtest_check_signature`, `StsDouble`, `with_loopback_server`, `with_gateway_doubles`). Kept: `S3TestServer(; bucket, credentials, region, page_size)`, `close`, `s3test_endpoint`, `s3test_error`, `s3test_percent_decode`, and the fields `objects modified requests presigned respond page_size port bucket`. Added: `with_s3_server`, `s3test_refusal`, `s3test_store!`. The fixture now holds its own `using` lines. Old `gwtest_sts(creds, region, arn)` is now `StsDouble(creds, region, arn)`. `GatewayDouble`'s 6-argument positional form still works, and there is a new 4-argument form `(s3, creds, caller, policy)`.

Agent E:
- src/attachments.jl → src/attachments.jl (AttachmentHash, put_attachment/touch_attachment on chains, the plain bucket's put, keys, retry), src/gateway_attachments.jl (mint route, upload of a minted URL, gateway touch, `fetch_object_to` on a gateway store), src/attachment_cache.jl (`attachment`, cache entries, sidecars, fetch), src/attachment_repair.jl (`verify_attachments`, `repair_attachments!`).
- src/Testing.jl → src/Testing/Testing.jl (Module file) + src/Testing/in_memory_object_store.jl.
- test/attachments.jl + the put_attachment testsets of test/gateway.jl and test/s3.jl → test/test_attachments.jl, test/test_attachments_examples.jl, test/test_gateway_attachments.jl, test/test_gateway_attachments_minted.jl, test/test_attachment_cache.jl, test/test_attachment_cache_examples.jl, test/test_attachment_repair.jl.
- test/Testing.jl → test/test_testing.jl, test/test_testing_in_memory_object_store.jl, test/test_testing_in_memory_object_store_examples.jl.
- New fixtures: test/fixtures/attachments.jl, test/fixtures/gateway_double.jl (LoopbackServer, GatewayDouble, gwtest_* from old test/gateway.jl), test/fixtures/gateway_attachments.jl.

### Behaviour changes

ChainTables#93 (`==`/`isequal` without `hash`), forced by interfaces.md's Equality Rule:
`hash` added for `Shape`, every `Ops.Op` type, `Ops.Record` (A) and `Head` (B), each
consistent with `==`; their `isequal` overrides removed (Base falls back to `==`), and
`Client`'s `==` removed (the default gives the same result). The new internal
`AttachmentHash` (E) has `==` and `hash`.

Lead:
- every own error type subtypes ChainTablesError, including TransportError, ModelError, CBOR.DecodeError and HeadRejected: catching ChainTablesError now also catches transport failures
- error messages: one showerror per type ("<Type>: <summary>: <detail>." + evidence + next move); no msg field; keyword constructors
- new public CredentialsError for SSO, AWS CLI and environment credential failures (were ErrorException; D's interim ArgumentError)
- `ispinned` → `is_pinned`; Model flattened into ChainTables with renamed functions; CBOR, Ops, Testing are public submodules
- `open` no longer warns when it falls back to a lower head (session 2, user decision)
- `open` of a chain whose store is not AWS no longer warns; the refusal at commit!/create_chain is the only signal (session 2 removed the stub; user decision)
- D's change of the `sso_credentials` exporter seam to return `(; ok, text)` reverted in session 2: the exporter returns the CLI's text or throws, as before; the default exporter throws `CredentialsError`
- `heal_record!` no longer warns when it replaces a damaged cached record (C, session 1; covered by the same user decision)

Agent A:
- `hash` added for `Shape`, every `Ops.Op` type and `Ops.Record`, consistent with their `==`. `Client`'s `==` override removed: the default (`===`, content-equal for its immutable String/Int fields) gives the same result, and the default `hash` agrees. The `isequal` overrides on Op and Record removed (Base's fallback to `==` gives the same).
- Op cells are typed `Cell`: `Insert/Update/Delete` rows and `AddColumn.fill` hold only `Int64`, `Float64`, `String`, `Vector{UInt8}`, `missing`. A wire op holding another value (Bool, array, map) is refused when the record is decoded (`MalformedRecordError`, detail `op i: "rows" holds a Bool, which is not a typed value`), no longer at apply. Building an op from Julia with such a value throws a conversion `MethodError`.
- `MalformedRecordError` from `apply!(content, record)`: detail is `<op> on "<table>": <rule>`; slot, chain id and op index are Evidence only (the old `malformed record at slot N: op i (…)… (chain X). No client can apply …` text is gone; the next move is in `showerror`).
- `MalformedRecordError` from `decode_record`: detail is the rule (`the record names slot 1`, `op 2: unknown op "nope"`, `not deterministic CBOR (byte 0: …)`); slot and readable chain id are Evidence.
- `encode_record` over the cap: `WriteBuilderError(; detail)`, `call` unset.
- `CBOR.DecodeError`: keyword constructor `DecodeError(; offset, detail)`; fields now `(offset::Union{Nothing,Int}, detail)`; `showerror` adds the offset Evidence and a next move.
- `ModelError`: keyword constructor added; `showerror` adds a next-move line.
- `Ops.local_client` takes `at = time()` (seconds since the epoch) for `time_ms`.
- `CBOR`, `Ops`: now public submodules with `public encode, decode, DecodeError` and `public Client, Record, decode_record, encode_record`.
- `check_column_name` returns `nothing` (was `true`); no caller used the value.
- Renamed, used only in my files: `getrow` → `row_of`, `Base.haskey(::Table, key)` → `has_row`, `ncols` → `n_columns`, `own` → `owned_cell`, CBOR helpers (`readbyte` → `read_byte`, `readbytes` → `read_bytes`, `read_be` → `read_big_endian`), `Ops.article` now with `with_article`. `nrows(t)` now reads `length(t.slots)` (same value).

Agent B:
- `Head` has `hash` (value-based, agreeing with `==`); its `isequal` method is gone (Base's falls back to `==`, same result).
- `LocalCopy.views` is `Dict{String,TableView}` (was `Dict{String,Any}`); TableView is defined before LocalCopy.
- WriteBuilderError is built with keywords: `call` evidence (e.g. `insert_rows!(w, :samples)`) and `detail`; the message is no longer "`<call>: <detail>`". Details reworded: spent builder → `this builder is spent` (`commit!`) / `this builder is spent: commit! consumed it` (ops), without "take a new one with write_builder(copy)"; "a table has one key" (was "one primary key"); "wrap it in a vector" (was "wrap the row in a vector").
- `open`'s errors use keywords: NotALocalCopyError detail "it exists and is not a directory" / "a non-empty directory without heads/ and tables/" / "head heads/N is not a ChainTables head file"; LayoutVersionError has `file` evidence and detail "layout version 2 is not this client's, 1" / "format_version 2 is above this client's maximum, 1" / "begins \"chaintables/v2/head\", not …"; WrongChainError detail "the head is at slot N"; LocalCopyInconsistentError (no usable head) has `file` = highest head and the joined reasons as detail.
- A damaged table file: LocalCopyInconsistentError with `path`, `slot`, `file` evidence and detail "table file tables/X (table \"t\") hashes to Y" / "… is missing" / "… holds a row slot S, above the head's slot H" / "… hashes to its name but is not a canonical table file" (the inner decode message is no longer appended; it is on the exception stack). The chain id is no longer in the message.
- FingerprintMismatchError at checkpoint: keyword evidence, detail "the local copy stays at slot N" (or "fresh and unbound").
- `ReadOnlyColumn` write message drops "(ADR-0043)".
- `checkpoint!`/`write_head!` slot refusal: "slot S is not above the head's slot H" (dropped "; a head is write-once and the slot advances").
- `scratch_slot` with rows throws `AssertionError("BUG: …")` (was `ErrorException`).

Agent C:
- Every error message is the new format (summary + detail + evidence + next move); details are short clauses; read_forward's `tail` text is gone.
- heal_record! no longer warns when it replaces a damaged cached record (silent repair).
- LostRaceError now carries `location`; StaleHeadError `path`; PinnedCopyError `call`; ChainNotFoundError `call`; DivergenceError `path` and `tables` (names only, no per-table hashes in the message).
- Misuse/invariant failures that were `ErrorException`: replay! of a fresh copy from slot > 0 → ArgumentError; read_forward's parent Guard → ArgumentError; a store returning `created = false` with a status other than 412 → ArgumentError; repair!'s re-encode mismatch and read_forward's final check → AssertionError("BUG: …").
- Chain/record_path/as_of/slot_at/commit_log ArgumentError texts changed (no `Chain:` prefix; bucket.jl's `check_bucket_name` messages change with it).
- check_head_record has no `next` argument; as_of's reopened-copy mismatch has the same detail as commit!'s pre-check.
- put_record!: on the last attempt, a retryable failure does its read-back inside the catch, so when the slot is non-empty the store is fetched twice (was once). Outcome unchanged.
- read_forward: an interrupt raised while waiting on read-ahead tasks is no longer swallowed (only TaskFailedException is).
- Internal signatures: `gallop(chain, lo)`; `fetch_record(chain, key) -> (bytes, cached)` (merges fetch_record_from); `heal_record!/cache_record!/put_record!(chain, key, bytes)`; `record_path(chain, key)` and `slot_key(prefix, slot)` added; `cached_record(chain, key_or_slot)`.
- test_tracked_values fails outside a git checkout (was a skip with `@info`).

Agent D:
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

Agent E:
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

### Carry-over checks

- `[sources]` in workspace sub-projects: not needed. test/Project.toml lists ChainTables in `[deps]`; Pkg resolves it to the workspace root.
- ExplicitImports on test modules: works under ParallelTestRunner with `check_…(@__MODULE__, @__FILE__)`; now run by all 29 Examples files (public-names Rule), passing.
- A logger that fails on warnings under ParallelTestRunner: no. With the Guide's runner template a `@warn` prints under "Output generated during execution" and the run passes; there is no hook for a failing logger without editing the template. (src/ now has no `@warn`.)


### Results

Same method as the baseline: `Pkg.test()` after `Pkg.instantiate(); Pkg.precompile()`;
wall time = the `Pkg.test()` call. ChainTables at `a100664`. BioMeCore `dff75ef`
extracted with `git archive` into a throwaway directory, this worktree `Pkg.develop`ed
into it and into its `BioMeFrontend.jl`.

| Suite | Result | Passes | Wall time | Baseline |
|---|---|---|---|---|
| ChainTables `a100664`, default group (`test/live/` excluded) | pass | 3472 | 62.6 s | 2981, 106.9 s |
| BioMeCore `dff75ef` vs ChainTables `a100664` | pass | 22808 | 47.3 s | 22808, 57.6 s |
| BioMeFrontend `dff75ef` vs ChainTables `a100664` | pass | 355 | 29.1 s | 355, 40.1 s |

No failures, no broken tests. An earlier timed run at `117eb6e` passed ChainTables (3472,
71.1 s) and BioMeFrontend (355, 29.7 s) but failed BioMeCore (lab_tables.jl, "logging in
checks the profile BUCKET assumes": 2 fail, 1 error) on the `sso_credentials` exporter
contract; fixed in `a100664` (see Cases). ChainTables' run prints Pkg's "manifest was
last resolved" warning for the untracked local Manifest; no test emits a warning.
BioMeCore prints DuckDB deprecation warnings, as at baseline.

Final code commit: `a100664`. The commit that adds this log section follows it on the
branch.

Note: the deletion of `HANDOVER.md` and `trial_notes/` was committed in `a100664`
(whose message names only the `sso_credentials` fix), not in the log commit `8b38e2a`.
Token counts: asked for at the end of session 2; the user had neither session's count.
Final commit: the commit that adds this note, the head of the pushed branch; last code
commit `a100664`.

User decision after session 2: drop CI completely.

- `.github/workflows/CI.yml | testing.md Rule: every Package root is tested by CI | blocked (CI cannot resolve TestConventions from the private BioMeRegistry) | user: drop CI; the workflow is deleted, so the package now breaks this Rule by the user's decision`
