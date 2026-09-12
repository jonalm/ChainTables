# DuckDB.jl facts for the read surface

Research for [issue #25](https://github.com/jonalm/S3SQLite/issues/25), part of the
[v1 design spec map (#1)](https://github.com/jonalm/S3SQLite/issues/1).
Sources verified 2026-09-12.

Measurement platform, everywhere "measured" appears below unless stated otherwise:
**DuckDB.jl v1.5.2 (registry latest) / DuckDB_jll v1.5.5+0 (library `v1.5.5`) /
Julia 1.12.7 / arm64-apple-darwin25.5.0**, in a throwaway environment created by
`Pkg.add("DuckDB")` in an empty project. A second environment on DuckDB.jl
`main` (`Project.toml` version `1.5.5`, unreleased, commit `0c11cb72`
2026-07-24) was used where the two differ. Probe scripts are not committed;
every number here is reproducible from the description given.

---

## Headline

**DuckDB.jl is fit for the optional read engine, with three facts that shape
the extension's design.** (1) Registration is Tables.jl-generic and scan-in-place:
`register_table(con, tbl, name)` calls `Tables.columntable` and keeps a reference
to the *same* Julia vectors, which DuckDB re-reads on every query — a
`NamedTuple` of vectors works, DataFrames is not a dependency (direct deps are
`DBInterface`, `DuckDB_jll`, `FixedPointDecimals`, `Tables`, `WeakRefStrings`,
`Dates`, `UUIDs`; 26 manifest entries in an empty env, 9 of them stdlib). (2)
**Blobs are the one broken value type in the registered release**: DuckDB.jl
v1.5.2 has no `create_logical_type(::Type{Vector{UInt8}})`, so a
`Vector{UInt8}` column cannot be registered at all, the Appender's blob path
throws inside its own `ccall`, and BLOB results come back as
`Base.CodeUnits{UInt8,String}`; all three are fixed on unreleased `main`
(BLOB ↔ `Vector{UInt8}` both directions, merged upstream 2026-03-11 as
duckdb/duckdb#21225) but no 1.5.5 is in the General registry yet. Until then, a
blob column must reach DuckDB as a hex or base64 `String` column decoded with
`unhex()` / `from_base64()` in a view — measured byte-exact — or be materialised
with a prepared `INSERT` (the bind path for exactly `Vector{UInt8}` works).
(3) Two silent conversions that the fingerprint path never sees but the read
surface must document: a Julia `String` that is not valid UTF-8 becomes **NULL**
on scan (DuckDB's C API validates and marks the row invalid, no error), and
`-0.0` survives a round trip bit-exactly but **compares equal to `0.0`** — `=`,
`ORDER BY`, `DISTINCT` and `GROUP BY` all treat them as one value. Parquet export
via `COPY <view> TO 'f' (FORMAT PARQUET)` works from a registered table and all
four types plus NULL, `-0.0`, `±Inf`, `NaN` and embedded `U+0000` survive a
DuckDB read-back. Identifiers are double-quoted with `""` escaping and are
**case-insensitive under ASCII folding** — two chain names that differ only in
ASCII case collide with a catalog error — and DuckDB.jl's own `register_table`
interpolates the view name into SQL **unescaped**, so the extension must
register under a name it generates and alias the chain's name itself.

---

## Findings by question

### 1. Type mapping, both directions

**Documented mapping (DuckDB.jl source).** Result columns are typed from
`JULIA_TYPE_MAP` in
[`src/ctypes.jl`](https://github.com/duckdb/DuckDB.jl/blob/v1.5.2/src/ctypes.jl)
(v1.5.2, lines 382–412): `BIGINT => Int64`, `DOUBLE => Float64`,
`VARCHAR => String`, `BLOB => Base.CodeUnits{UInt8, String}` (also `BIT` and
`GEOMETRY`). Registered columns are typed through `create_logical_type` in
[`src/logical_type.jl`](https://github.com/duckdb/DuckDB.jl/blob/v1.5.2/src/logical_type.jl):
`Int64 → BIGINT`, `Float64 → DOUBLE`, `AbstractString → VARCHAR`, and a
fallback `throw(NotImplementedException("Unsupported type for create_logical_type"))`
for everything else — including `Vector{UInt8}`. Bound parameters go through
[`src/statement.jl`](https://github.com/duckdb/DuckDB.jl/blob/v1.5.2/src/statement.jl)
lines 52–71: `AbstractString → duckdb_bind_varchar_length`, `Vector{UInt8} →
duckdb_bind_blob`, `Missing`/`Nothing → duckdb_bind_null`, any other
`AbstractVector` → a DuckDB LIST value.

**Measured, DuckDB → Julia** (`SELECT 1::BIGINT, 1.5::DOUBLE, 'abc',
'\x00\xFF'::BLOB, NULL::BIGINT, NULL`):

| DuckDB | Julia column type (v1.5.2) | Julia column type (`main`) |
|---|---|---|
| `BIGINT` | `Vector{Int64}` | same |
| `DOUBLE` | `Vector{Float64}` | same |
| `VARCHAR` | `Vector{String}` | same |
| `BLOB` | `Vector{Base.CodeUnits{UInt8,String}}` | `Vector{Vector{UInt8}}` |
| `NULL::BIGINT` | `Vector{Union{Missing,Int64}}` | same |
| bare `NULL` | `Vector{Union{Missing,Int32}}` (DuckDB types it INTEGER) | same |

Two behaviours the read surface must not assume away:

- **Column eltype is data-dependent.** `QueryResult` declares every column
  `Union{Missing, T}`
  ([`result.jl` line 29](https://github.com/duckdb/DuckDB.jl/blob/v1.5.2/src/result.jl)),
  but `convert_column_loop` (lines 352–380) scans the chunks for NULLs first and
  allocates `Vector{T}` when none are present, `Vector{Union{Missing,T}}`
  otherwise. Measured: the same nullable `BIGINT` column comes back as
  `Vector{Int64}` from one query and `Vector{Union{Missing,Int64}}` from another.
- **Decimal literals are not `Float64`.** `SELECT 0.0 * -1` returns
  `FixedPointDecimals.FixedDecimal{Int64,1}` (measured), because DuckDB types the
  literal `0.0` as `DECIMAL`, not `DOUBLE`. Only `::DOUBLE` columns become
  `Float64`. Our model's columns are typed, so this only bites ad-hoc SQL.

**Measured, Julia → DuckDB via `register_table`** (a `NamedTuple` with columns
`Int64`, `Float64`, `String`, `Union{Missing,Int64}`): `DESCRIBE` reports
`BIGINT`, `DOUBLE`, `VARCHAR`, `BIGINT`, all `null=YES`. Int64 round-trips
`typemin`/`typemax` exactly. `Union{Missing,T}` is the only accepted nullable
form — `Vector{Any}`, `Union{Nothing,Int}`, `Union{Int,String}`, `Symbol`,
`Char`, `Nothing` all fail at bind time with `Unsupported type for
create_logical_type` or a `MethodError` (measured). **The Julia model must hold
concretely-eltyped column vectors** (`Vector{Union{Missing,Int64}}`, not
`Vector{Any}`), which also makes the scan monomorphic.

**Float64 and `-0.0`.** Measured with a registered column `[-0.0, 0.0, -Inf,
Inf, 1.5]`:

- `-0.0` **survives the round trip**: `signbit.(result) == [1,0,1,0,0]`, matching
  the input. Through Parquet too (`COPY` then `read_parquet`: signbits preserved,
  and `NaN` and `±Inf` come back as themselves).
- **DuckDB treats `-0.0` and `0.0` as equal**: `f = 0.0` is true for both,
  `f < 0.0` false for both, `f IS DISTINCT FROM 0.0` false for both;
  `SELECT DISTINCT` over `{-0.0, 0.0}` yields one row, `GROUP BY` yields one
  group of count 2, and `ORDER BY` places them adjacent in input order (which of
  the two survives `DISTINCT` is unspecified; measured `0.0`). DuckDB's
  `signbit(f)` distinguishes them if a query needs to.
- Ordering (measured, `ORDER BY x` over `{NaN, 1.0, -Inf, NULL, Inf, -0.0, 0.0}`):
  ascending `-Inf, 0.0, 0.0, 1.0, Inf, NaN, NULL`; descending
  `NaN, Inf, 1.0, 0.0, 0.0, -Inf, NULL`. This matches the docs:
  "NaN compares equal to NaN and greater than any other floating point number"
  ([Numeric types](https://duckdb.org/docs/current/sql/data_types/numeric.html))
  and "By default, DuckDB sorts ASC and NULLS LAST" — NULLs stay last under
  `DESC` too, unlike PostgreSQL
  ([ORDER BY](https://duckdb.org/docs/current/sql/query_syntax/orderby.html)).
  The numeric-types page says nothing about negative zero; the equality
  behaviour above is measured only.
- Literal gotcha: `-0.0::DOUBLE` yields `-0.0` but `(-0.0)::DOUBLE` yields
  `+0.0`, because DuckDB parses the literal `-0.0` as a `DECIMAL`, which has no
  negative zero (measured). Bind parameters from Julia are unaffected.

**String.** DuckDB's `VARCHAR` is UTF-8 internally and length-unbounded
([Text types](https://duckdb.org/docs/current/sql/data_types/text.html): "the
data is encoded as UTF-8"; the declared length "has no effect"). Measured:

- Empty string, `"héllo"` and `"a\0b"` (embedded `U+0000`) round-trip exactly
  through the table scan and through Parquet; `length('a'||chr(0)||'b') = 3`
  in SQL. DuckDB itself has no problem with NUL in text.
- **Invalid UTF-8 becomes NULL, silently, on the scan path.** A registered
  column `["\xff\xfe"]` (and `"a\xffb"`, and the overlong `"\xc0\x80"`) reads
  back as `missing` with `s IS NULL` true, on both v1.5.2 and `main`. The cause
  is in DuckDB's C API, not DuckDB.jl:
  [`src/main/capi/data_chunk-c.cpp`](https://github.com/duckdb/duckdb/blob/v1.5.5/src/main/capi/data_chunk-c.cpp)
  lines 155–167 at v1.5.5 — `duckdb_vector_assign_string_element_len` runs
  `duckdb_valid_utf8_check` on VARCHAR vectors and, on failure,
  `duckdb_validity_set_row_invalid(...)` and returns. No error surfaces.
  `CREATE TABLE AS` from such a view persists the NULL.
- **Invalid UTF-8 as a bind parameter raises.** `DBInterface.execute(stmt,
  ["\xff\xfe"])` fails with "Failed to bind parameter": `duckdb_bind_varchar_length`
  constructs a `Value(std::string)`
  ([`prepared-c.cpp`](https://github.com/duckdb/duckdb/blob/v1.5.5/src/main/capi/prepared-c.cpp)
  line 392), whose constructor throws `InvalidUnicodeError` when
  `Value::StringIsValid` fails
  ([`value.cpp`](https://github.com/duckdb/duckdb/blob/v1.5.5/src/common/types/value.cpp)
  line 161).
- **Embedded NUL as a bind parameter raises on the Julia side**: the `ccall`
  declares the argument `Cstring`
  ([`api.jl`](https://github.com/duckdb/DuckDB.jl/blob/v1.5.2/src/api.jl)
  line 2488), so Julia throws `embedded NULs are not allowed in C strings`
  before DuckDB sees it. The scan path passes `Ptr{UInt8}` + length (line 4808)
  and is fine. The same `Cstring` rule means a NUL cannot appear in SQL text at
  all through DuckDB.jl (also measured for a NUL in an identifier).

The chain's text values are ADR-0021 strings; whether they are guaranteed valid
UTF-8 is the writer's rule, not DuckDB's. If the model can hold invalid UTF-8,
the read surface must either validate and refuse up front (fail-fast) or
document that such values read as NULL in DuckDB.

**`Vector{UInt8}` (blob).** This is where the registered release falls short.

| path | v1.5.2 (registry) | `main` (unreleased 1.5.5) |
|---|---|---|
| BLOB result column | `Base.CodeUnits{UInt8,String}` (a `DenseVector{UInt8}`; `Vector{UInt8}(x)` copies) | `Vector{UInt8}` |
| `register_table` with `Vector{UInt8}` column | **fails**: `Unsupported type for create_logical_type` | works, `DESCRIBE` says `BLOB`, byte-exact round trip incl. `0x00` and empty |
| `register_table` with `Union{Missing,Vector{UInt8}}` | fails, same error | works |
| `register_table` with `Base.CodeUnits` / `SubArray{UInt8}` column | fails | still fails (only the concrete `Vector{UInt8}` has a method) |
| prepared-statement bind of `Vector{UInt8}` | works (`duckdb_bind_blob`) | works |
| bind of `Base.CodeUnits` / `SubArray{UInt8}` | `Unimplemented type for cast (UTINYINT[] -> BLOB)` — routed to the generic LIST path | same |
| `Appender.append(::Vector{UInt8})` | **throws** `cannot convert a value to nothing`: the `ccall` declares the data argument `Ref{Cvoid}` ([`api.jl` line 7261](https://github.com/duckdb/DuckDB.jl/blob/v1.5.2/src/api.jl)) | works (`Ptr{Cvoid}`) |
| Appender `missing` and `String` into a BLOB column | works | works |

The fix is duckdb/duckdb [PR #21225](https://github.com/duckdb/duckdb/pull/21225)
"[Julia] Add BLOB support" (merged 2026-03-11: "Map BLOB/BIT to `Vector{UInt8}`
instead of `CodeUnits`", "Support BLOB in … table scan", "Fix `duckdb_append_blob`
ccall signature"). The v1.5.2 tag (2026-04-16, commit `8403cfff`) was cut from a
line that does not include it; `main` of
[duckdb/DuckDB.jl](https://github.com/duckdb/DuckDB.jl) does. As of
2026-09-12 the General registry's newest `DuckDB` version is `1.5.2` and the
package's own `Project.toml` on `main` says `1.5.5`, so the next registered
release will change the blob result type from `CodeUnits` to `Vector{UInt8}`.
The extension should accept `AbstractVector{UInt8}` on the way out and pin
`DuckDB = "1.5"` with a test that exercises the blob path under both.

**Workaround measured on v1.5.2, byte-exact for `[0x00,0xff,0x5c,0x27]`, `[]`,
`[0x80]`:** register the blob column as `bytes2hex.(col)` (or
`Base64.base64encode.(col)`) and expose `unhex(h)` (resp. `from_base64(b64)`)
in a view; both return `BLOB`. Smuggling raw bytes as `String(copy(bytes))` and
casting `::BLOB` does **not** work: DuckDB's VARCHAR→BLOB cast requires
non-ASCII bytes to be `\xAA`-escaped and the invalid-UTF-8 rows are already NULL
before the cast (measured: `[missing, [], missing]`). Alternatively materialise
into a DuckDB table with a prepared `INSERT` binding `Vector{UInt8}` (works on
both versions) at the cost of a copy.

**NULL ↔ `missing`.** Both directions, measured: NULLs read back as `missing`;
`missing` and `nothing` both bind as NULL (`statement.jl` lines 62–63); a
`Union{Missing,T}` column registers as nullable and its `missing`s become NULL.
The Appender documents the same: "Missing and Nothing are stored as NULL in
duckdb, but will be converted to Missing when the data is queried back"
([`appender.jl` line 10](https://github.com/duckdb/DuckDB.jl/blob/v1.5.2/src/appender.jl)).

### 2. Registering Julia tables without DataFrames

**What `register_table` accepts.** The whole implementation is
([`src/table_scan.jl`](https://github.com/duckdb/DuckDB.jl/blob/v1.5.2/src/table_scan.jl)):

```julia
function register_table(con::Connection, tbl, name::AbstractString)
    con.db.registered_objects[name] = columntable(tbl)
    DBInterface.execute(
        con,
        string("CREATE OR REPLACE VIEW \"", name, "\" AS SELECT * FROM julia_tbl_scan('", name, "')")
    )
    return
end
register_table(db::DB, tbl, name::AbstractString) = register_table(db.main_connection, tbl, name)
const register_data_frame = register_table
```

`columntable` is `Tables.columntable`, so **any Tables.jl source is accepted**;
`register_data_frame` is literally an alias. Measured: a `NamedTuple` of
vectors, a `Vector{NamedTuple}` (row table), a `Dict{Symbol,Vector}`, a custom
type implementing `Tables.istable`/`columnaccess`/`columns`, and columns that
are `UnitRange` or `SubArray` all register and query correctly. Not accepted
per column: anything without a `create_logical_type` method (see §1) — and
`AbstractVector{UInt8}` columns other than exactly `Vector{UInt8}` even on
`main`.

**DataFrames is not a dependency.** `Project.toml` `[deps]` of DuckDB.jl
v1.5.2, in full: `DBInterface`, `Dates`, `DuckDB_jll`, `FixedPointDecimals`,
`Tables`, `UUIDs`, `WeakRefStrings`; `[compat]`: `DBInterface = "2.5"`,
`DuckDB_jll = "1.5.2"`, `FixedPointDecimals = "0.4, 0.5, 0.6"`, `Tables = "1.7"`,
`WeakRefStrings = "1.4"`, `julia = "1.10"`. The only mentions of `DataFrame` in
`src/` are a docstring example, a comment, and the legacy `toDataFrame`, which
now returns `Tables.columntable(r)`
([`old_interface.jl` line 11](https://github.com/duckdb/DuckDB.jl/blob/v1.5.2/src/old_interface.jl)).

**Scan-in-place, not a copy.** The README states "the DataFrames are directly
read by DuckDB - they are not inserted or copied into the database itself"
(same sentence on the [Julia client docs
page](https://duckdb.org/docs/lts/clients/julia)). Measured to be literally true
for the vectors: after `register_table(con, (v = v,), "live")`,
`con.handle.registered_objects["live"].v === v`; `v[1] = 100` changes
`SELECT sum(v)` from 6 to 105 on the next query, and `push!(v, 1000)` changes
`count(*)` to 4. `Tables.columntable` on a `NamedTuple` of `AbstractVector`s
returns the same array objects; on other sources it materialises columns once
at registration. Each query then copies the scanned rows into DuckDB
`DataChunk`s 2048 rows at a time (`tbl_scan_column` / `tbl_scan_string_column`,
which write into `get_array(vector, T)` — an `unsafe_wrap` over DuckDB's own
buffer) and DuckDB parallelises over row groups with Julia threads
(`tbl_global_init_function` sets `max_threads = ceil(rows / ROW_GROUP_SIZE)`).
`CREATE TABLE AS SELECT * FROM view` makes a DuckDB-owned copy (measured: later
mutation of the Julia vector does not affect it). `unregister_table` drops the
view and the reference. The registry is a `Dict{Any,Any}` per `DB`
(`db.handle.registered_objects`), and `_add_table_scan` registers the
`julia_tbl_scan` table function once per `DB`.

Consequence for the model: the extension can hand DuckDB the model's own column
vectors with **no copy and no conversion**, as long as they are concretely
typed and blobs are handled per §1. The view reflects whatever the vectors hold
at query time, so a model that mutates in place under a live query is a
data race — register a snapshot or hold a lock.

A side-finding on integer arithmetic: `SELECT sum(v)` over a `BIGINT` column
returns `HUGEINT` → `Int128` (measured). SQL aggregates widen; callers must not
assume `Int64` back.

### 3. Parquet write via `COPY … TO … (FORMAT PARQUET)`

Documented ([COPY](https://duckdb.org/docs/current/sql/statements/copy.html)):
"COPY ... TO exports data from DuckDB to an external CSV, Parquet, JSON or
BLOB file"; "When a table name is specified, the contents of the entire table
will be written … When a query is specified, the query is executed and the
result of the query is written". Parquet options and defaults from the same
page: `COMPRESSION` snappy, `COMPRESSION_LEVEL` 3, `ROW_GROUP_SIZE` 122880,
`ROW_GROUP_SIZE_BYTES` row_group_size × 1024, `PARQUET_VERSION` V1,
`FIELD_IDS` and `KV_METADATA` empty, `DICTIONARY_SIZE_LIMIT` row_group_size/5,
`WRITE_BLOOM_FILTER` true, `USE_TMP_FILE` auto ("write to a temporary file
first if the original file exists … prevents overwriting an existing file with
a broken file in case the writing is cancelled"), `OVERWRITE_OR_IGNORE` false
(multi-file outputs only).

Measured, `COPY t TO '<path>' (FORMAT PARQUET)` where `t` is the registered
view from §1:

- Works directly from the view (601 bytes for 5 rows × 4 columns). `COPY
  (SELECT * FROM t ORDER BY i) TO … (FORMAT PARQUET, COMPRESSION ZSTD,
  ROW_GROUP_SIZE 1000)` also works and `parquet_metadata()` confirms `ZSTD`.
- `parquet_schema()`: `i INT64` (converted type `INT_64`), `f DOUBLE`,
  `s BYTE_ARRAY` (converted type `UTF8`), `n INT64`; a BLOB column is
  `BYTE_ARRAY` with no logical/converted type. Reading back with
  `read_parquet()` gives `Vector{Int64}`, `Vector{Float64}`,
  `Vector{Union{Missing,String}}`, `Vector{Union{Missing,Int64}}` and, for
  blobs, `Vector{Union{Missing,Base.CodeUnits{UInt8,String}}}` on v1.5.2 /
  `Vector{Vector{UInt8}}` on `main` — i.e. the four types are recovered with
  the same Julia mapping as any other query.
- Values: full `Int64` range, `-0.0` (signbit preserved), `±Inf`, `NaN`,
  NULL, empty string, embedded NUL, non-ASCII text, empty blob and `0x00`
  bytes all survive the write/read pair byte- and bit-exact. The invalid-UTF-8
  row was already NULL on scan (§1) and is written as NULL.
- On `main`, a registered `Vector{UInt8}` column copies straight to Parquet
  and reads back byte-exact; on v1.5.2 export the `unhex()` view or a
  materialised table instead.
- `parquet_file_metadata()` reports `created_by = "DuckDB version v1.5.5
  (build d8cdaa33fd)"` — the writer build hash is embedded, as the
  serialization-format research already noted for Parquet in general
  (`docs/research/record-serialization-format.md`). Parquet output is an
  export, never an identity; nothing here should be hashed.
- The file path is interpolated into SQL text as a single-quoted string
  literal; the extension must escape `'` as `''` in it (not measured with a
  quote in the path; the rule is the standard SQL literal rule and the same
  one DuckDB.jl relies on for the view name in §6).

### 4. Artifacts

**DuckDB_jll.** Built from the Yggdrasil recipe
[`D/DuckDB/build_tarballs.jl`](https://github.com/JuliaPackaging/Yggdrasil/blob/1f0e56313e11f77ebe5c1cf66e02c1d00c33a8c2/D/DuckDB/build_tarballs.jl)
(commit `1f0e5631`, `version = v"1.5.5"`, from duckdb/duckdb revision
`d8cdaa33fda8df955cc76ef58a280f68f4cd43fa`; `-DBUILD_EXTENSIONS='parquet;json'`,
`-DENABLE_EXTENSION_AUTOLOADING=1`, `-DENABLE_EXTENSION_AUTOINSTALL=1`,
`-DBUILD_SHELL=TRUE`; `platforms = expand_cxxstring_abis(supported_platforms())`
minus `powerpc64le`; `julia_compat="1.6"`). Parquet is compiled in, so the
export in §3 needs no download at runtime. The jll's `Project.toml` says
`julia = "1.6"`, `JLLWrappers = "1.7.0"`.

The 17 platforms in the jll's `Artifacts.toml` (v1.5.5+0), with compressed
tarball sizes measured by `HEAD` on the release URLs
(`Content-Length`, 2026-09-12):

| platform | MiB | | platform | MiB |
|---|---|---|---|---|
| **aarch64-apple-darwin** | **47.4** | | i686-linux-gnu-cxx11 | 62.9 |
| **x86_64-apple-darwin** | **49.8** | | i686-linux-musl-cxx11 | 62.5 |
| **x86_64-w64-mingw32-cxx11** | **49.8** | | i686-w64-mingw32-cxx11 | 57.5 |
| x86_64-linux-gnu-cxx11 | 51.8 | | armv6l-linux-gnueabihf-cxx11 | 51.4 |
| x86_64-linux-musl-cxx11 | 51.5 | | armv6l-linux-musleabihf-cxx11 | 50.9 |
| aarch64-linux-gnu-cxx11 | 48.8 | | armv7l-linux-gnueabihf-cxx11 | 51.2 |
| aarch64-linux-musl-cxx11 | 48.4 | | armv7l-linux-musleabihf-cxx11 | 50.7 |
| x86_64-unknown-freebsd | 53.6 | | riscv64-linux-gnu-cxx11 | 85.3 |
| aarch64-unknown-freebsd | 52.2 | | | |

macOS arm64 and x86_64 and Windows x86_64 (and i686) are all covered. The
unpacked artifact is 177 MB on disk (measured, `du -sh`), of which
`libduckdb.dylib` is 46.5 MB on aarch64-apple-darwin; the rest is the `duckdb`
shell and headers. Only the `cxx11` string ABI is shipped for glibc/musl/mingw.

**Julia compat.** DuckDB.jl `1.4`–`1.5.2`: `julia = "1.10"` (registry
`Compat.toml`, `["1.4 - 1"] julia = "1.10.0 - 1"`); `1.3.2`–`1.3.x` still
allowed `1.6`. DuckDB.jl `1.5.2` requires `DuckDB_jll = "1.5.2"` (i.e. ≥1.5.2,
<2), which is why the resolver paired it with `DuckDB_jll 1.5.5+0`; the
library version and the wrapper version are not pinned to each other.

**Load time, measured** (fresh process each run, compile cache already warm,
`julia --project=<env> script.jl`, three runs):

| step | run 1 | run 2 | run 3 |
|---|---|---|---|
| `@time using DuckDB` | 0.151 s | 0.100 s | 0.101 s |
| `DBInterface.connect(DuckDB.DB, ":memory:")` (first, incl. JIT) | 0.194 s | 0.144 s | 0.146 s |
| first `execute("SELECT 1")` | 0.216 s | 0.219 s | 0.217 s |
| first `register_table` | 0.194 s | 0.173 s | 0.163 s |
| first query over the registered table | 0.612 s | 0.360 s | 0.341 s |
| whole process wall (`time`) | 1.77 s | 1.39 s | 1.35 s |

Bare `julia -e 1` on the same machine: 0.14 s wall. So `using DuckDB` costs
~0.1 s, and the first-use JIT of the scan and result paths costs another
~0.9 s (mostly compilation, per `@time`'s "compilation time" figures of
70–99 %). DuckDB.jl does not use `PrecompileTools` itself (it is in the
manifest only transitively), which is consistent with the first-query JIT
cost; an extension could add its own precompile workload for the scan and
result paths.

**Precompile, measured cold** (empty `JULIA_DEPOT_PATH`, registry added, then
`Pkg.add("DuckDB")`): 15.2 s wall for download + install + precompile of
everything; the precompile phase alone reported "19 dependencies successfully
precompiled in 10 seconds" (parallel), the largest being `Parsers` 4.2 s,
`DuckDB` 2.8 s, `Tables` 2.8 s, `DuckDB_jll` 1.2 s. Resulting depot: `compiled/`
86 MB, `artifacts/` 177 MB, `packages/` 3 MB.

### 5. Weak-dependency fitness

- **A normal registered package.** `DuckDB` is in the General registry
  (uuid `d2f5444f-75bc-4fdf-ac35-56f514c445e1`, repo
  `https://github.com/duckdb/DuckDB.jl.git`, MIT). The module file
  [`src/DuckDB.jl`](https://github.com/duckdb/DuckDB.jl/blob/v1.5.2/src/DuckDB.jl)
  is `using` lines, two marker structs, and 22 `include`s; **there is no
  `__init__`** in DuckDB.jl (`grep -rn __init__ src/` finds nothing), no
  `Requires`, no `[weakdeps]`/`[extensions]` of its own. The only load-time side
  effect is `DuckDB_jll`'s JLLWrappers-generated `__init__`, which `dlopen`s
  `libduckdb` — standard for every jll. It exports exactly `DBInterface` and
  `DuckDBException`. Nothing here obstructs use as a
  `[weakdeps]` trigger; the mechanism needs Julia ≥ 1.9 and DuckDB.jl already
  requires ≥ 1.10.
- **Package health, for the record.** The repository moved out of
  `duckdb/duckdb/tools/juliapkg` (which no longer exists on `main`) into
  `duckdb/DuckDB.jl` in July 2026 (first commits 2026-07-24, "Update to use
  latest specs"); 4 stars, 2 open issues/PRs, CI workflow `Julia.yml` active,
  TagBot active. Open PR #2 "Fix and improve Julia Appender" (2026-08-11)
  notes the `Appender` does not hold a reference to its connection, so the GC
  can collect the DB under a live appender — another reason to prefer the
  registered-view path over the Appender for our use.
- **Transitive footprint, measured** in an empty environment: **26 manifest
  entries** including `DuckDB` itself. Non-stdlib (17): `BitIntegers`,
  `DBInterface`, `DataAPI`, `DataValueInterfaces`, `DuckDB`, `DuckDB_jll`,
  `FixedPointDecimals`, `InlineStrings`, `IteratorInterfaceExtensions`,
  `JLLWrappers`, `OrderedCollections`, `Parsers`, `PrecompileTools`,
  `Preferences`, `TableTraits`, `Tables`, `WeakRefStrings`. Stdlib (9):
  `Artifacts`, `Dates`, `Libdl`, `Printf`, `Random`, `SHA`, `TOML`, `UUIDs`,
  `Unicode`. **No DataFrames, no CSV, no Arrow.** The heavy ones are the
  artifact (§4) and `Parsers` (pulled by `WeakRefStrings` → `InlineStrings`;
  4.2 s precompile). The `⌅` markers in `Pkg.status` show `InlineStrings` and
  `Parsers` held back by `WeakRefStrings`' compat, not by us.
- **Threading.** The README: "It uses Julia threads/tasks for this purpose.
  If you wish to run queries in parallel, you must launch Julia with
  multi-threading support". The scan sets `max_threads` from the row count,
  so a single-threaded Julia still works (measured with `-t auto` = 10 threads
  here; not measured at `-t 1`).

### 6. Identifier quoting in DuckDB SQL

Documented ([Keywords and
identifiers](https://duckdb.org/docs/current/sql/dialect/keywords_and_identifiers.html)):

> Identifiers can be quoted using double-quote characters (`"`). Quoted
> identifiers can use any keyword, whitespace or special character. Double
> quotes can be escaped by repeating the quote character.

> Identifiers in DuckDB are always case-insensitive … Case-insensitivity is
> implemented using an ASCII-based comparison: `col_A` and `col_a` are equal
> but `col_á` is not equal to them. … DuckDB treats identifiers in a
> case-insensitive manner, it preserves the cases of these identifiers …
> When the same identifier is spelt with different cases, one will be selected
> randomly.

Unquoted identifiers "must not be a reserved keyword", "must not start with a
number or special character", "cannot contain whitespaces". The
`preserve_identifier_case` setting only affects display casing.

Measured:

- `CREATE TABLE "Weird ""name"" ; --x" ("Col A" BIGINT, "col_b" BIGINT)`
  works; `duckdb_tables()` reports the name as `Weird "name" ; --x` and the
  columns with their case preserved. A quoted keyword (`"select"`) and a
  Unicode name (`"ünï ✓ 名"`) work. Names of length 255, 256, 1000 and 10000
  all work (no length limit found).
- **Case collisions are errors, not merges.** `CREATE TABLE casecols("Col A"
  BIGINT, "col a" BIGINT)` → `Catalog Error: Column with name col a already
  exists!`; `CREATE TABLE mixedcase(…)` after `MixedCase` exists → `Table with
  name "mixedcase" already exists!`. `SELECT * FROM "MIXEDCASE"` resolves
  `MixedCase` — quoting does **not** make names case-sensitive, unlike
  PostgreSQL. So: **two chain names that differ only in ASCII case cannot both
  exist in one DuckDB catalog**; the read surface must either mangle or refuse.
  Names differing only in non-ASCII case (`É` vs `é`) are distinct.
- **Two characters cannot be quoted at all.** The empty identifier `""` is a
  parser error (`zero-length delimited identifier`), and a `U+0000` inside SQL
  text is rejected by DuckDB.jl's `Cstring` `ccall` before DuckDB sees it. If
  the chain's shape rules allow either, the read surface must refuse them.
- **DuckDB.jl's own `register_table` does not escape the name.** It builds
  `CREATE OR REPLACE VIEW "<name>" AS SELECT * FROM julia_tbl_scan('<name>')`
  by string concatenation. Measured: a name containing `"` fails with a parser
  error, a name containing `'` fails with a parser error, and the name
  `x" AS SELECT 42 AS a --` **succeeds and creates a view `x` that returns 42**
  — an injection through the table name. Column names are not affected (they
  go through `duckdb_bind_add_result_column` as bytes; `"Col A"`, `"a""b"` and
  `"select"` all measured fine).

**Safe quoting rule for a name from user data:** `'"' * replace(name, '"' =>
"\"\"") * '"'`, after refusing the empty name and any name containing
`U+0000`, and after checking ASCII-case-insensitive uniqueness across the
tables (and across the columns of each table) being exposed. Because
`register_table` cannot be given an arbitrary name safely, the extension
should **register under a name it generates** (e.g. `s3sqlite_tbl_<n>`, ASCII,
no quotes) and then itself run `CREATE VIEW <safely-quoted chain name> AS
SELECT * FROM <generated name>`, or simply expose the generated names plus a
mapping.

---

## What this means for the extension

- **Model columns**: concretely typed vectors, `Union{Missing,T}` for nullable,
  never `Vector{Any}`. Then `register_table(con, nt, name)` with the model's
  own `NamedTuple` is zero-copy and correct for `Int64`, `Float64`, `String`
  and NULL on the registered release today.
- **Blobs**: register a `bytes2hex` (or base64) shadow column and expose
  `unhex()` in a view until a DuckDB.jl ≥ 1.5.5 is registered; write the
  blob test against `AbstractVector{UInt8}` so it passes on both. Do not use
  the `Appender` at all on 1.5.2.
- **Strings**: decide, and document, whether invalid UTF-8 can exist in the
  model; if it can, DuckDB will show it as NULL without telling anyone.
- **`-0.0`**: bit-preserved, value-equal. Fine for a read engine; irrelevant to
  the fingerprint, which never goes through DuckDB.
- **Names**: refuse empty and NUL; enforce ASCII-case-insensitive uniqueness;
  never pass a chain name to `register_table`.
- **Parquet**: `COPY (SELECT * FROM <view> ORDER BY <pk>) TO '<escaped path>'
  (FORMAT PARQUET)`; treat the output as an export, never as an identity.
- **Cost**: ~50 MiB download, ~0.1 s load, ~1 s first-query JIT, 26 manifest
  entries, no DataFrames.
