# Notes of agent C (store, chain, recovery)

## 1. Guide cases: `file:line | Rule/Default | unclear/wrong/blocked | choice made`

BLOCKED: none.

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

## 2. Old → new file mapping

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

## 3. Behaviour changes

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

## 4. Errors change requests; renamed names used elsewhere

- RewrittenChainError: add `location` (bucket/prefix) and `path` (the local copy); both now go in `detail` or are dropped (old messages named them).
- FingerprintMismatchError: add `path` (the local copy); now in `detail`.
- WriteRefusedError, GatewayMismatchError: add `location`; the old enrichment named it.
- An outer keyword constructor taking a `LocalCopy`/`Head` for the evidence would let throws fit 3 lines without the `evidence` NamedTuple.
- Renamed names used by other files: none. `expected_chain_id(chain::Chain)` lost its docstring (localcopy.jl's fallback holds the one docstring).
