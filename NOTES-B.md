# NOTES-B: builder, local copy, views

## 1. Guide cases (file:line | Rule/Default | unclear/wrong/blocked | choice made)

- src/local_copy.jl:259 | Rule: no `@warn` in src/ | BLOCKED | `open`'s fall-back to a lower head still warns (the old test pinned the warning). Proposed: record the fall-back on the copy (e.g. a field read by an accessor) or accept a Breakable `warn` marker; or drop the warning.
- src/chain.jl:6 | Rule: all `using` in the Module file | BLOCKED (not my file) | the old localcopy.jl held `using .Ops: Record`, which chain.jl relies on. A `using .Ops: …` cannot sit in the Module file before `include("ops.jl")`. To keep the clone running I extended chain.jl's own line to `using .Ops: Client, Record`. Proposed: chain.jl owner qualifies `Ops.Record` (and `Ops.Client`).
- test/test_quality.jl | Rule: qualified accesses are public (ExplicitImports) | BLOCKED (lead's file) | Tables.jl declares no `public` names, so every `Tables.istable`/`Tables.columns`/… method in src/table_view.jl is flagged. Implementing the Tables.jl interface needs them. Proposed: an `ignore` list for Tables in test_quality.jl.
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

## 2. Old → new files

- src/builder.jl → src/builder.jl (WriteBuilder, TableDeclaration, the op functions, spend!) + src/row_sets.jl (cells, row sets, name checks)
- src/localcopy.jl → src/chain_id_text.jl (base32 chain id) + src/head_file.jl (Head, HeadRejected, encode/decode) + src/local_copy.jl (LocalCopy, open, head, tables, pin, close, sweep) + src/table_files.jl (load_table!, stage!, write_head!, discard!, checkpoint!, hash_file)
- src/views.jl → src/table_view.jl (TableView, ReadOnlyColumn, Base/Tables.jl methods, table_with_slots) + src/views.jl (table, shape)
- test/builder.jl → test/test_builder.jl, test/test_row_sets.jl, test/test_builder_examples.jl
- test/localcopy.jl → test/test_chain_id_text.jl, test/test_head_file.jl, test/test_local_copy.jl, test/test_table_files.jl, test/test_local_copy_examples.jl
- test/views.jl → test/test_table_view.jl, test/test_views.jl, test/test_table_view_examples.jl, test/test_views_examples.jl
- Old tests dropped (internals): a scratch table holding rows (needs internal mutation; now an `AssertionError("BUG: …")`); `WriteBuilder(Content(); copy, head)` type parameters; `length(methods(write_builder)) == 1` and `commit!(WriteBuilder(Content()))` (chain.jl's); builder ops through `Ops.encode_record`/`decode_record` (replay of committed ops is tested instead); `open` reading no chain field (replaced: `open` makes no store call).

## 3. Behaviour changes

- `Head` has `hash` (value-based, agreeing with `==`); its `isequal` method is gone (Base's falls back to `==`, same result).
- `LocalCopy.views` is `Dict{String,TableView}` (was `Dict{String,Any}`); TableView is defined before LocalCopy.
- WriteBuilderError is built with keywords: `call` evidence (e.g. `insert_rows!(w, :samples)`) and `detail`; the message is no longer "`<call>: <detail>`". Details reworded: spent builder → `this builder is spent` (`commit!`) / `this builder is spent: commit! consumed it` (ops), without "take a new one with write_builder(copy)"; "a table has one key" (was "one primary key"); "wrap it in a vector" (was "wrap the row in a vector").
- `open`'s errors use keywords: NotALocalCopyError detail "it exists and is not a directory" / "a non-empty directory without heads/ and tables/" / "head heads/N is not a ChainTables head file"; LayoutVersionError has `file` evidence and detail "layout version 2 is not this client's, 1" / "format_version 2 is above this client's maximum, 1" / "begins \"chaintables/v2/head\", not …"; WrongChainError detail "the head is at slot N"; LocalCopyInconsistentError (no usable head) has `file` = highest head and the joined reasons as detail.
- A damaged table file: LocalCopyInconsistentError with `path`, `slot`, `file` evidence and detail "table file tables/X (table \"t\") hashes to Y" / "… is missing" / "… holds a row slot S, above the head's slot H" / "… hashes to its name but is not a canonical table file" (the inner decode message is no longer appended; it is on the exception stack). The chain id is no longer in the message.
- FingerprintMismatchError at checkpoint: keyword evidence, detail "the local copy stays at slot N" (or "fresh and unbound").
- `ReadOnlyColumn` write message drops "(ADR-0043)".
- `checkpoint!`/`write_head!` slot refusal: "slot S is not above the head's slot H" (dropped "; a head is write-once and the slot advances").
- `scratch_slot` with rows throws `AssertionError("BUG: …")` (was `ErrorException`).

## 4. Errors change requests; renamed names used elsewhere

- WrongChainError: add `slot::MaybeInt` (the bound head's slot); now in `detail`.
- LocalCopyInconsistentError: add `table::MaybeString` (the table whose file is damaged); now in `detail`.
- WriteBuilderError: the fixed next move "Fix the call named above" does not fit a spent builder ("take a new one with `write_builder(copy)`"); suggest adding that clause to the next move.
- Renames used by other files: none. Internal renames (only my files): `damaged` → `throw_damaged_table`, `live` → `check_not_spent`, `tablename`/`colname` → `table_name`/`column_name`, `rowset` → `row_set`, `layout_message` removed, `head_int/head_bytes/head_text` → `head_value`.
