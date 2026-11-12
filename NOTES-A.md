# NOTES-A: record format core (hashes, CBOR, model, Ops, error tests)

## 1. Guide cases

No BLOCKED item.

file:line | Rule/Default | unclear/wrong/blocked | choice made
---|---|---|---
src/CBOR/decode.jl:47 | `# style: inferred` marker "on the line above the definition" | unclear | A comment between the docstring and `function` detaches the docstring (`Docs.undocumented_names` flagged `decode`). Marker put above the opening `"""`, as for `docstring-length`.
src/CBOR/decode.jl:61 | Boundary function never returns `Dict{String,Any}`; no `Dict{String,Any}`/`Vector{Any}` in signatures | unclear | `CBOR.decode` is a generic codec, not a Boundary function: it returns `Dict{String,Any}`/`Vector{Any}` by nature (return values, not signatures). The Boundary functions on top (`decode_record`, `read_table`, `Shape(wire)`, `op_from_wire`) turn it into typed structs. Marked `# style: inferred`.
src/Ops/op.jl:132, src/shape.jl:72 | same | unclear | `wire`/`shape_wire` keep returning `Dict{String,Any}` (input to `encode`, return value only).
src/Ops/op.jl:6 | no `Vector{Any}` in fields | unclear | `Vector{Vector{Any}}` is not literally `Vector{Any}`; read it as forbidden and typed cells as `Cell = Union{Missing,Int64,Float64,String,Vector{UInt8}}` (`AddColumn.fill::Cell`, rows/keys `Vector{Vector{Cell}}`). Behaviour change, see 3.
test/test_shape.jl:2 (and test_row_checks, test_table, test_content, test_table_file, test_fingerprint, test_ops_op, test_ops_record, test_ops_record_bytes, test_ops_apply) | Default: test through API names | Default does not fit | The model and Ops internals carry the format's spec and frozen literals (state_fingerprint, transaction_hash, table hashes). Tested directly, reason comment above the `using`. Proposal: per testing.md's seam rule, make `Ops.apply!`, `Ops.transaction_hash` and a `state_fingerprint` public (the lead owns the public lists).
src/Ops/record.jl:52,96 | Default ≤ 4 positional arguments | Default does not fit | `Client` (5) and `Record` (7) mirror the envelope field for field; chain.jl calls them positionally. Reason comments added.
src/model_error.jl:9 | own error type holds Evidence fields | unclear | `ModelError` has none: every caller folds its `detail` into another error's detail (`WriteBuilderError`, `MalformedRecordError`, `ArgumentError` in views/localcopy), so table/column/key stay in `detail`.
src/model_error.jl:27 | Guard is `cond || throw(...)`; Default: no pass-through helper | Default does not fit | `fail(detail)` kept for builder.jl, localcopy.jl, recovery.jl (other agents). My files throw `ModelError(; detail)` directly.
src/Ops/apply.jl:64 | Default: `try` only in a Boundary function | Default does not fit | Translating the model's rule into the `MalformedRecordError` of the record that broke it needs the record's slot and op index. Reason comment added.
src/Ops/record_bytes.jl:171 | `detail` never repeats Evidence | unclear | `decode_record` cannot set `op` Evidence for an op that fails to read without translating per op with the slot in hand; the op index stays in `detail` as `op i: …`. `apply!` sets `op` Evidence and leaves it out of `detail`.
src/Ops/record.jl:16-18, src/CBOR/encode.jl:5 | ADR references only in comments | unclear | Some refusal messages contain `(ADR-NNNN)`. Messages are neither docstrings nor file headers; text kept so pinned messages do not move.
src/* (many) | `throw(…)` ≤ 3 lines + 92 columns + keyword constructors | unclear (costly) | Long messages need consts (`NOT_COLUMN_NAME`, `GOT_TYPE`, …) or small `*_text(…)` helpers called inside `throw`, so the non-throwing path does not allocate. Runic expands a split `detail =` to 5–6 lines, so `*`-splitting inside the throw is not available.
src/hashes.jl:73 | no fallback method on a broad abstract type | unclear | `hash_bytes(::Type{T}, x)` refuses anything else with the pinned message ("is 32 bytes or 64 hex characters, got a value of type …"); kept, comment says why.
src/Ops/record.jl:87 | Default: small types for domain values | Default does not fit | `Record.prev_hash`/`state_fingerprint` stay `Vector{UInt8}`: localcopy.jl and chain.jl read them as bytes (`Vector{UInt8}(…)`).
src/table_file.jl:12 | Conformance test for a type implementing a Base interface | unclear | `HashingIO <: IO` implements `write`/`unsafe_write`; testing.md's laws do not cover IO. No Conformance test; covered by `write_table` returning `table_hash`.
test/test_cbor_encode.jl:1 | file ≤ 400 lines (Default) | Default does not fit | 484 lines: the 96-case frozen corpus belongs with the encoder it freezes. Reason comment at the top.
test/test_cbor_encode.jl:400-460 | line ≤ 92 unless it holds just one string literal | unclear | Long frozen hex literals sit alone on a line followed by the call's trailing comma; read as exempt.
test/test_shape.jl etc. | `@test_throws` 3-argument form vs 92 columns | unclear | Long ones written as `@test_throws(T, "msg", expr)` over several lines.

## 2. Old → new files

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

## 3. Behaviour changes

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

## 4. Errors change requests; renames used by other files

- Add `Examples: test/test_errors_examples.jl` as the last docstring line of `ChainTablesError`, `StaleHeadError`, `LostRaceError`, `CommitOutcomeUnknownError`, `UnsupportedStoreError`, `WriteBuilderError`, `ChainNotFoundError`, `RewrittenChainError`, `MalformedRecordError`, `WriteRefusedError`, `GatewayMismatchError`, `TransportError` (src/errors.jl); `Examples: test/test_local_copy_errors_examples.jl` to the eight types in src/local_copy_errors.jl; `Examples: test/test_attachment_errors_examples.jl` to the six types in src/attachment_errors.jl. The testsets exist (`"<name> example"`).
- Optional: `WriteBuilderError` has no Evidence for a record over the cap (size, cap); they are in `detail`.
- No rename of a name used by another file.
