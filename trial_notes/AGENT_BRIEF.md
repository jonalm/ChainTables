# ChainTables Guide trial: shared brief for every rewrite agent

You are one of five agents rewriting the Julia package ChainTables under a Julia style
Guide. The trial asks whether the Guide makes code better. **Follow the Guide as
written. Do not improve on it from your own taste.** Where the Guide is silent, keep the
existing code's behaviour and approach.

## The Guide (read before writing any Julia)

`~/.cache/julia-style/trial-777a0df/JULIA_STYLE.md`, then ALL of its sub-files in
`~/.cache/julia-style/trial-777a0df/julia_style/` (testing, performance,
types_and_dependencies, interfaces, docs_and_comments, layout). Read them in full. Do not
read anything else in `~/.cache/julia-style/` or the GitHub repo jonalm/julia_codestyle.
Scripts.md is not needed. The Glossary for this package is `CONTEXT.md` at the repo root:
use its terms exactly and never its _Avoid_ words.

Scope: this is a rewrite, so bring every function and file you own fully under the
Guide (JULIA_STYLE.md, "Scope"). Migrations are in scope: no `(@ref)` links, no
`ADR-NNNN` in docstrings (ADR references only in comments, form `ADR-NNNN`), no `msg`
fields, no task history comments (`#34 step 7`, `(#92)`), no divider comments.

## Your working copy

A git clone at `<CLONE>` on branch `wip-<G>`. Work and commit only there (several
commits are fine). Never push, never touch other directories, never touch
`~/biome/ChainTables` or `~/biome/ChainTables-trial`.

- Pre-rewrite reference (Runic-formatted original): `git show bd6e4d8:src/<file>.jl`,
  `git show bd6e4d8:test/<file>.jl`. The old tests are deleted from the working tree;
  read them from git. They are the behaviour spec: every behaviour they pin for an API
  name must still be pinned by your new tests (internals' tests may be dropped or moved
  to API names, as testing.md says).
- Before every commit: `runic --inplace <touched .jl files>`, and no line over 92
  columns (`awk 'length > 92' file`).
- Run tests: `julia --startup-file=no --project=test test/runtests.jl test_<name> ...`
  (ParallelTestRunner filters by file name), or `include` one file in
  `julia --project=test`. First run: `julia --project=test -e 'using Pkg; Pkg.instantiate()'`.

## Decisions already made (do not revisit)

1. **Errors** (`src/errors.jl`, `src/local_copy_errors.jl`, `src/attachment_errors.jl`,
   owned by the lead, do not edit them): every own error type subtypes `ChainTablesError`,
   has Evidence fields (`Union{Nothing,T}`, keyword constructor, `nothing` when unknown)
   and a `detail::String` keyword (default `""`), and one `showerror` that writes
   "<Type>: <fixed summary>: <detail>." + the known evidence + the next move. Read the
   three files to see each type's fields. At your throw sites:
   - build with keywords: `throw(StaleHeadError(; path = copy.path, chain_id, slot))`;
   - `detail` is a short clause saying which case happened (the summary and next move
     are already in `showerror`); never repeat evidence or next move in `detail`;
   - a `throw(…)` is ≤ 3 lines; a long fixed text goes in a `const`.
   - `src/legacy_error_constructors.jl` is a temporary shim for the old `T(msg; kw...)`
     form so unrewritten code still runs. **Do not use it**: when you are done, none of
     your files may call an error type with a positional message. The lead deletes it.
   - Internal error types (`ModelError` in model.jl, `CBOR.DecodeError`, `HeadRejected`
     in localcopy.jl) already subtype `ChainTablesError` with a `detail` field; the
     owner of the file finishes them under the same Rules (Evidence fields, one
     `showerror`).
   - `TransportError(detail; status)` is now a `ChainTablesError` (defined in errors.jl).
     So `e isa ChainTablesError` now also matches it: check every such test.
   - Need an Evidence field that is missing, or another error type? Don't edit the
     errors files: write it in your report ("errors change requests") and, meanwhile,
     put the value in `detail`.
2. **Submodules.** `Model` is already flattened into `ChainTables` (src/model.jl, no
   module). Its colliding functions were renamed: `content_table`, `add_table!`,
   `remove_table!`, `append_column!`, `remove_column!`, `insert_table_rows!`,
   `update_table_rows!`, `delete_table_rows!`, `shape_wire`. `CBOR`, `Ops` and `Testing`
   stay submodules and are **public** API (layout.md: a submodule exists only as an API
   name) and move to `src/CBOR/CBOR.jl`, `src/Ops/Ops.jl`, `src/Testing/Testing.jl`.
3. **The public list** is in `src/ChainTables.jl` (the Module file, owned by the lead).
   Do not edit its `public` line. You may edit only the `include` lines of your own
   files there (add, split, rename, reorder your own), nothing else. Say in your report
   what include order your files need. `using` statements: the Guide puts them all in
   the Module file; add the `using` lines your files need there (explicit names), and
   remove `using`/`import` from your own files.
4. `ispinned` is already renamed `is_pinned`.
5. Tests: `test/runtests.jl` is the Guide template and `test/test_quality.jl`
   (Aqua, ExplicitImports, undocumented names) exist; don't edit them. Test deps are in
   `test/Project.toml`: Test, Aqua, ExplicitImports, ParallelTestRunner, TestConventions
   (`check_inferred`, `allocations_after_warmup` only), Random, Sockets, SHA, Tables,
   StableRNGs. Need another? Say so in your report; don't add it.
   Each test file runs alone: `using Test`, `using ChainTables: ChainTables, a, b`,
   includes the fixtures it uses (`include("fixtures/x.jl")`, never from runtests.jl).
   `test/fixtures/gateway.jl` defines `GWT` and `gateway_test_record(user)` (keep
   `GWT` and `gwtest_record`: test/live uses them). Every random call takes
   `StableRNG(seed)`. CBOR reference corpus: `test/data/cbor_corpus/`.
6. Not Hot: no function is declared Hot (no `Allocations:` lines), unless the old code
   or tests pinned an allocation count; then ask in your report.

## Cross-agent contract (the other four agents work in parallel on other files)

- **Names used outside your files stay**: any function, type, const or field used by a
  file you don't own keeps its name, its positional arity and its keywords (you may add
  methods or keywords). Check with `grep -rn "<name>" src/` before renaming anything.
  Rename freely what only your files use.
- **test/live/ must keep working and is never edited.** It calls these internals
  through `GWT.` and `using ChainTables: …`: keep their names, positional arity and
  keyword names: `sync! mint open commit! write_builder slot_key record_author is_aws
  insert_rows! upload_minted table s3_request create_chain attachment_key verify sha256
  record_cap Ops.decode_record head current_credentials column! checksum_sha256
  cache_namespace stat_object request_headers put_object_if_absent primary_key!
  list_objects http_stream fetch_object create_table! AbstractObjectStore Bucket Chain
  GatewayObjectStore PutOutcome TransportError WriteRefusedError WriteBuilderError
  LostRaceError AttachmentChangedError AttachmentAbsentError attachment put_attachment
  touch_attachment`. It reads `e.status`, `e.reason`, `e.key`, `e.caller`, `e.slot` and
  expects these in `sprint(showerror, e)`: "this builder is spent" (WriteBuilderError),
  the S3 error code such as "AccessDenied" or the gateway's "not_a_slot" (TransportError
  detail). `PutOutcome(false, 412)` stays a valid positional call. To read exactly what
  it calls: `grep -n "GWT\.\|using ChainTables" test/live/*.jl`.
- **Downstream (BioMeCore, BioMeFrontend) must keep working.** They use: `head(copy)`
  (`.slot`), `table`, `tables`, `open`, `Chain(...; store, cache_dir, credentials, login,
  profile)`, `sync!`, `write_builder`, `commit!(w; comment)`, `commit_log(copy; last)`
  (`.slot .transaction_hash .author .host .time_ms`), `TableView` (`keys(v)`, rows,
  `Tables.jl`), `insert_rows!`, `update_rows!`, `delete_rows!`, `try_create_chain`,
  `shape(copy, name)`, `record_author`, `primary_key!`, `LocalCopy`, `create_table!`,
  `column!`, `add_column!`, `Bucket`, `table_with_slots(v)._slot`, `Credentials`,
  `sso_credentials`, `StaleHeadError`, `LostRaceError`,
  `CommitOutcomeUnknownError` (`.slot .transaction_hash .cause`),
  `Testing.InMemoryObjectStore()` with a mutable `fault` field they set to a
  `(verb, key, phase) -> …` function that may `error("network down")` (an
  `ErrorException`, not a `TransportError`) — such a failure of the record put must
  still end as `CommitOutcomeUnknownError`, never as a silent success or another type.
  Keep these behaviours exactly.
- The `==`/`isequal` Rule (interfaces.md, Equality) requires `hash` wherever `==` or
  `isequal` is defined; fix it where you own the type, and list each such fix in your
  notes as a behaviour change.

## Public names: what each needs

Every public name you own (listed in your task) needs: a docstring in the Guide's form
ending with `Examples: test/test_<stem>_examples.jl` (API functions/types; error types
too), one `@testset "<name> example"` in that Examples file (public names only), and an
inference test in the unit file (`@inferred` or `check_inferred`; or a
`# style: inferred <reason>` marker on the line above the definition when intentionally
unstable). A type implementing a Base interface gets a Conformance test (testing.md).

## Notes you must keep: `<CLONE>/NOTES-<G>.md` (commit it)

1. One line per case where the Guide was unclear, a Default did not fit, or a Rule
   blocked you: `file:line | Rule/Default | unclear/wrong/blocked | choice made`.
   - Unclear, or a Default doesn't fit: choose the least complicated reading, continue,
     log it. A broken Default also gets its one-line reason comment above the construct.
   - A Breakable Rule blocks you: write `# style: <name> <reason>` and log it.
   - Any other Rule blocks you or seems wrong: **do not break it silently and do not
     stop the whole task**: keep the construct as close to the Rule as you can, log it
     with `BLOCKED` in the third column and a proposed resolution, and continue. The
     lead will ask the user.
2. Old→new file mapping for your files (src and test), merged/split files as groups.
3. Behaviour changes (anything a caller could observe), one line each.
4. Errors change requests, and names you renamed that other files use (should be none).

## Done when

- Every file you own is rewritten under the Guide; old tests' behaviours are pinned by
  new `test/test_*.jl` files; your test files pass when run alone and together
  (`julia --project=test test/runtests.jl test_a test_b …`). Failures caused by another
  agent's not-yet-rewritten file are expected only where your code calls theirs; say
  which in your report.
- `runic --inplace` run, no line over 92 columns, committed on `wip-<G>`.
- Your final message (your report to the lead) lists: commits, include lines needed,
  `using` lines added, notes summary (BLOCKED items first), behaviour changes, errors
  change requests, anything the lead must do at merge. Keep it concise.
