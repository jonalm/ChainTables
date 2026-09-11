# SQLite_jll build uniformity across platforms

Research for [#18](https://github.com/jonalm/S3SQLite/issues/18) (part of
[#1](https://github.com/jonalm/S3SQLite/issues/1)). Graduated from
[#3](https://github.com/jonalm/S3SQLite/issues/3), whose "Not settled" items 1 and
2 this file closes.

**Question.** SQLite's behaviour is configurable at compile time. Two S3SQLite
clients on different operating systems replay the same record sequence against
their own `SQLite_jll` artifact. Can the *build* — as opposed to the version,
which #3 already settled — make them diverge?

**Scope.** `SQLite.jl` 1.8.2, whose registered compat is
`SQLite_jll = "3.51.0 - 3"`
([General registry, `S/SQLite/Compat.toml`](https://github.com/JuliaRegistries/General/blob/master/S/SQLite/Compat.toml)).
The registry currently offers exactly two artifacts in that range —
**3.51.2+0** and **3.53.2+0**
([`jll/S/SQLite_jll/Versions.toml`](https://github.com/JuliaRegistries/General/blob/master/jll/S/SQLite_jll/Versions.toml);
3.49.0+0 is below the floor and was yanked).

**Verdict vocabulary**

- **PINNED** — the value must be fixed by the design and cannot be left to the
  artifact. Either the library must be built/configured to a known value, or the
  design must never depend on the feature.
- **CHECKED** — uniform today but not *guaranteed* uniform; a cheap runtime
  assertion at DB open must confirm it and hard-error otherwise.
- **IGNORED** — cannot change logical database content. No design action.

Claims marked **[empirical]** were produced locally on **macOS aarch64** against
the real `SQLite_jll` artifacts (`3.53.2+0` and `3.51.2+0`), plus `strings`
extraction from the published binaries for twelve further platforms. Everything
else is quoted from sqlite.org, the Yggdrasil recipe, the SQLite source
distribution, or the Julia General registry.

---

## Headline

**The builds are uniform.** Across all 13 `SQLite_jll` v3.53.2+0 platform
artifacts, the 51 entries of `PRAGMA compile_options` are identical except for
`COMPILER=` and `MUTEX_PTHREADS` → `MUTEX_W32` on Windows. There is one recipe,
one build script, no per-platform branching, and the actual `cc` command line
recorded in the build logs is byte-identical apart from `-fPIC` vs `-dynamic`.

**But uniformity is not the same as safety**, and three things fall out of the
investigation that matter more than the answer to the literal question:

1. **`SQLITE_DQS` is `3` in the library** — double-quoted strings are accepted as
   string literals in both DDL and DML — because the recipe never sets it and the
   SQLite default is 3. It does **not** appear in `PRAGMA compile_options` at all,
   because `ctime.c` reports that option only when it is explicitly defined. A
   client that logs compile options sees no DQS line and would wrongly conclude
   nothing is set.
2. **The jll's `sqlite3` CLI is not the jll's library.** The shell is statically
   linked from its own compilation with `-DSQLITE_DQS=0` and six other extra
   options. Probing behaviour with the bundled `sqlite3` binary gives *different
   answers* from `SQLite.jl`, which loads `libsqlite3`.
3. **`PRAGMA compile_options` cannot detect the divergence that actually exists.**
   3.51.2 and 3.53.2 have byte-identical option sets, yet
   `cast(0.1+0.2 AS TEXT)` is `0.3` on one and `0.30000000000000004` on the
   other. The build guard is not a version guard; both are needed.

---

## Verdict table

| Option / property | Value in `SQLite_jll` | Can change results? | Verdict |
|---|---|---|---|
| `SQLITE_DQS` | **3** (library), 0 (bundled CLI) | Yes — `"x"` is a string literal, not an identifier | **PINNED** (never emit a double-quoted literal; always quote identifiers) |
| `SQLITE_ENABLE_ICU` | **absent** | Yes — replaces `upper`/`lower`/`LIKE`, adds locale collations | **CHECKED** (assert absent) |
| `SQLITE_ENABLE_MATH_FUNCTIONS` | **present** | Yes — values come from the platform's libm | **PINNED** (exclude math functions from anything hashed) |
| `SQLITE_ENABLE_PERCENTILE` | **present** | Yes, if used | **PINNED** (exclude, same reason) |
| `SQLITE_THREADSAFE` | 1 (serialized) | No — concurrency only | IGNORED |
| `SQLITE_MAX_LENGTH` | 1000000000 (default) | Accept/reject boundary only, not values | **CHECKED** (cheap, and `sqlite3_limit()` can lower it per connection) |
| `SQLITE_MAX_VARIABLE_NUMBER` | 250000 | Accept/reject boundary only | IGNORED |
| `SQLITE_MAX_EXPR_DEPTH` | 10000 | Accept/reject boundary only | IGNORED |
| `SQLITE_MAX_SQL_LENGTH`, `MAX_COLUMN`, `MAX_ATTACHED`, … | SQLite defaults | Accept/reject boundary only | IGNORED |
| `SQLITE_DEFAULT_SYNCHRONOUS` | 2 (`NORMAL`) | No — durability, not content | IGNORED |
| `SQLITE_SECURE_DELETE` | present | File bytes only, not logical content | IGNORED (but see "the file is not the fingerprint") |
| `SQLITE_DEFAULT_AUTOVACUUM` | reported, but **value is 0** | File layout only | IGNORED |
| `SQLITE_DEFAULT_RECURSIVE_TRIGGERS` | reported, but **value is 0** | Would matter if nonzero | IGNORED (triggers excluded by #3 anyway) |
| `SQLITE_DEFAULT_PAGE_SIZE`, `DEFAULT_CACHE_SIZE`, `DEFAULT_MMAP_SIZE`, `DEFAULT_WAL_*` | SQLite defaults | File bytes / performance only | IGNORED |
| `SQLITE_ENABLE_FTS3/4/5`, `RTREE`, `GEOPOLY` | FTS3/4/5 + RTREE present | Yes, if used (tokenizers, R-tree geometry) | **PINNED** (exclude from the op grammar) |
| `SQLITE_ENABLE_COLUMN_METADATA`, `DBSTAT_VTAB`, `STMTVTAB`, `UNLOCK_NOTIFY`, `USE_URI`, `FTS3_TOKENIZER`, `FTS3_PARENTHESIS` | present | No — introspection / API surface | IGNORED |
| `SQLITE_MIXED_ENDIAN_64BIT_FLOAT` | **absent** everywhere | Yes — would break REAL bit-identity in the file | **CHECKED** (assert absent; #3 hazard 7) |
| `SQLITE_OMIT_*` | **none present** | Yes, if any appeared | **CHECKED** (assert none) |
| `SQLITE_DEFAULT_FOREIGN_KEYS` | **absent** (FK off) | Yes — #3 hazard 18 | **CHECKED** (assert absent) *and* set `PRAGMA foreign_keys` explicitly |
| `COMPILER=` | `gcc-4.8.5` / `gcc-14.2.0` / `clang-18.1.7` | No | IGNORED — **must be stripped before any comparison** |
| `MUTEX_PTHREADS` / `MUTEX_W32` | POSIX / Windows | No | IGNORED — **must be stripped before any comparison** |
| long double / x87 excess precision | no `long double` in the source at all | No | IGNORED |
| float ↔ text conversion | pure integer arithmetic in SQLite's own code | No *across builds* — but **yes across versions** | **PINNED** (#3 hazard 8 stands: never route a float through SQLite text) |
| `SQLITE_AVOID_U64_DIVIDE` | auto-defined on arm32 / ppc32 by the *source*, invisible to `compile_options` | No (a division strategy, same digits) | IGNORED, with a caveat — see below |
| `sqlite_version()` | 3.51.2 or 3.53.2, both admitted | **Yes** — this is the live divergence | **PINNED** (exact version, or a floor + recorded version; #3 hazard 22) |

---

## Detail

### 1. The Yggdrasil recipe is one script for every platform

[`JuliaPackaging/Yggdrasil`, `S/SQLite/build_tarballs.jl`](https://github.com/JuliaPackaging/Yggdrasil/blob/master/S/SQLite/build_tarballs.jl)
(at `version = v"3.53.2"`) sets:

```
export CPPFLAGS="-DSQLITE_ENABLE_COLUMN_METADATA=1 \
                 -DSQLITE_ENABLE_UNLOCK_NOTIFY \
                 -DSQLITE_ENABLE_DBSTAT_VTAB=1 \
                 -DSQLITE_ENABLE_FTS3_TOKENIZER=1 \
                 -DSQLITE_ENABLE_FTS3_PARENTHESIS \
                 -DSQLITE_SECURE_DELETE \
                 -DSQLITE_ENABLE_STMTVTAB \
                 -DSQLITE_MAX_VARIABLE_NUMBER=250000 \
                 -DSQLITE_MAX_EXPR_DEPTH=10000 \
                 -DSQLITE_ENABLE_MATH_FUNCTIONS \
                 -DSQLITE_USE_URI"

./configure --prefix=${prefix} --build=${MACHTYPE} --host=$target \
    --disable-static --enable-fts3 --enable-fts4 --enable-fts5 --enable-rtree
```

Structurally there is **no per-platform branching**: `script` is a single `raw"""
"""` string, `platforms = supported_platforms()`, and the only platform-conditional
line in the whole file is a `Dependency("dlfcn_win32_jll"; platforms=filter(Sys.iswindows, platforms))`.
The recipe is copied from the Arch Linux `PKGBUILD`, per its own comment.

**The recipe is not the whole flag set.** `configure` (autosetup since 3.49.0)
adds more. `autosetup/sqlite-config.tcl` in the 3.53.2 tarball declares
`math=1`, `json=1`, `threadsafe=1`, `load-extension=1` as default-enabled
features, and `sqlite-handle-math` appends
`-DSQLITE_ENABLE_MATH_FUNCTIONS -DSQLITE_ENABLE_PERCENTILE`. If libm is missing
the build *fails* (`user-error "Cannot find libm functions"`) rather than silently
dropping the functions — so this cannot diverge silently per platform.

The recipe body has not changed across the admitted range. Yggdrasil commit
[`bd0a8465`](https://github.com/JuliaPackaging/Yggdrasil/commit/bd0a8465) (the
3.51.2 → 3.53.2 bump) touches only `version` and the source URL + SHA256; the
`CPPFLAGS` / `configure` block is untouched. The previous commit
[`b3bc6f85`](https://github.com/JuliaPackaging/Yggdrasil/commit/b3bc6f85) (3.49.0
→ 3.51.2) likewise only removes the yank note and bumps the version. The flags
themselves were last edited in
[`7e65987a`](https://github.com/JuliaPackaging/Yggdrasil/commit/7e65987a),
December 2022.

### 2. The actual compile command, per platform

**[empirical]** From the published build logs
(`SQLite-logs.v3.53.2.<platform>.tar.gz`, asset of
[`SQLite-v3.53.2+0`](https://github.com/JuliaBinaryWrappers/SQLite_jll.jl/releases/tag/SQLite-v3.53.2%2B0)),
the line that compiles the amalgamation is character-for-character the same on
`i686-linux-gnu`, `x86_64-linux-gnu` and `aarch64-apple-darwin` except for the
PIC flag:

```
cc -c .../sqlite3.c -o sqlite3.o -O2 -DSQLITE_SECURE_DELETE
   -DSQLITE_MAX_VARIABLE_NUMBER=250000 -DSQLITE_MAX_EXPR_DEPTH=10000
   -DSQLITE_USE_URI -I. -fPIC          <- (-dynamic on macOS)
   -DSQLITE_ENABLE_COLUMN_METADATA=1 -DSQLITE_ENABLE_DBSTAT_VTAB=1
   -DSQLITE_ENABLE_FTS3 -DSQLITE_ENABLE_FTS3_PARENTHESIS
   -DSQLITE_ENABLE_FTS3_TOKENIZER=1 -DSQLITE_ENABLE_FTS4 -DSQLITE_ENABLE_FTS5
   -DSQLITE_ENABLE_MATH_FUNCTIONS -DSQLITE_ENABLE_PERCENTILE
   -DSQLITE_ENABLE_RTREE -DSQLITE_ENABLE_STMTVTAB -DSQLITE_ENABLE_UNLOCK_NOTIFY
   -DSQLITE_HAVE_ZLIB=1 -DSQLITE_THREADSAFE=1
```

No `-ffast-math`, no `-march`, no `-mfpmath`, no `-Ofast`. Plain `-O2`. That is
the answer to the "anything touching floating point" part of the question at the
*flag* level; §5 answers it at the *source* level.

### 3. Thirteen platforms, compared binary-to-binary

**[empirical]** All 13 v3.53.2+0 artifacts were downloaded and their
`libsqlite3` string tables searched for every option name that appears in
`ctime.c`'s option array (259 candidates). Method validated: on
`aarch64-apple-darwin` the extraction reproduces the live
`PRAGMA compile_options` output exactly (51 rows), modulo four SQL type-name
strings (`BLOB`, `INTEGER`, `REAL`, `TEXT`) that are not compile options.

Platforms compared: `aarch64-apple-darwin`, `x86_64-apple-darwin`,
`x86_64-linux-gnu`, `i686-linux-gnu`, `aarch64-linux-gnu`, `x86_64-linux-musl`,
`aarch64-linux-musl`, `armv7l-linux-gnueabihf`, `powerpc64le-linux-gnu`,
`riscv64-linux-gnu`, `x86_64-unknown-freebsd`, `x86_64-w64-mingw32`,
`i686-w64-mingw32`.

The **complete** set of differences:

| Difference | Platforms |
|---|---|
| `COMPILER=gcc-4.8.5` | the nine Linux and Windows builds (all but riscv64) |
| `COMPILER=gcc-14.2.0` | `riscv64-linux-gnu` |
| `COMPILER=clang-18.1.7` | the two Apple builds and `x86_64-unknown-freebsd` |
| `MUTEX_PTHREADS` → `MUTEX_W32` | the two mingw builds |

Everything else — all 48 remaining options, including every `MAX_*`, every
`DEFAULT_*`, `THREADSAFE=1`, `TEMP_STORE=1`, `SECURE_DELETE`, `USE_URI`,
`ATOMIC_INTRINSICS=1`, and the full `ENABLE_*` set — is identical on all 13.

**Nothing results-affecting is enabled that shouldn't be.** Absent on every
platform: `ENABLE_ICU`, `MIXED_ENDIAN_64BIT_FLOAT`, `DEFAULT_FOREIGN_KEYS`,
`ENABLE_UPDATE_DELETE_LIMIT`, `CASE_SENSITIVE_LIKE`, `LIKE_DOESNT_MATCH_BLOBS`,
and every `OMIT_*`.

**[empirical]** The same comparison between `3.51.2+0` and `3.53.2+0` on
`x86_64-linux-gnu` shows **zero** differences in the option set.

### 4. `SQLITE_DQS` — the one that is set wrong, uniformly

The library carries the SQLite default. From the 3.53.2 amalgamation:

```c
#if !defined(SQLITE_DQS)
# define SQLITE_DQS 3
#endif
```

and from <https://www.sqlite.org/compile.html>:

> "The recommended setting is 0, meaning that double-quoted strings are
> disallowed in all contexts. However, the default setting is 3 for maximum
> compatibility with legacy applications."

with the table: `3` = double-quoted strings allowed in DDL *and* DML.

**[empirical]** Through `SQLite.jl` 1.8.2 on `SQLite_jll` 3.53.2:
`SELECT "a bare double quoted string"` returns the **string**
`"a bare double quoted string"`, not an error. Confirmed at the library level,
not the shell.

Two traps follow.

**Trap 1: it is invisible.** `ctime.c` emits the DQS row under `#ifdef SQLITE_DQS`
— i.e. only when it was defined on the command line. Since the recipe does not
define it, `PRAGMA compile_options` on `libsqlite3` contains **no DQS row at
all**, while the effective value is the most permissive one. Absence of a row is
not evidence of a safe default. (The same `#ifdef`-on-an-always-defined-macro
shape makes `DEFAULT_AUTOVACUUM` and `DEFAULT_RECURSIVE_TRIGGERS` appear in every
build's option list with their *values* — both `0` — suppressed;
**[empirical]** `PRAGMA auto_vacuum` = 0 and `PRAGMA recursive_triggers` = 0 on
the same connection that lists both strings.)

**Trap 2: the CLI lies about the library.** `autosetup/sqlite-config.tcl` defines
an `OPT_SHELL` list, "defaults which are always applied", whose first entry is
`-DSQLITE_DQS=0`; `static-shell` defaults to 1, so the bundled `sqlite3` is
compiled separately with those flags. **[empirical]** `PRAGMA compile_options`
from the jll's own `bin/sqlite3` has 58 rows against the library's 51; the seven
extras are `DQS=0`, `ENABLE_BYTECODE_VTAB`, `ENABLE_DBPAGE_VTAB`,
`ENABLE_EXPLAIN_COMMENTS`, `ENABLE_OFFSET_SQL_FUNC`,
`ENABLE_UNKNOWN_SQL_FUNCTION`, `STRICT_SUBTYPE`. Any behavioural probe run
through the CLI must be re-run through `SQLite.jl` before it is believed.

`SQLite.jl` cannot fix this for us: it defines `SQLITE_DBCONFIG_DQS_DML` /
`SQLITE_DBCONFIG_DQS_DDL` as constants in `src/capi.jl` but **does not wrap
`sqlite3_db_config` at all**, so there is no supported call to turn DQS off. This
is consistent with #3's verdict (hazard 24): exclude DQS *by construction* —
single-quote every literal, always quote identifiers — rather than relying on the
engine to reject it.

### 5. Floating point: safe by source, not by luck

The concern was long double width, x87 vs SSE on i686, and `-ffast-math`. All
three are answered in the source rather than the build:

- **`long double` does not appear anywhere in the 3.53.2 amalgamation.** Neither
  does `LONGDOUBLE_TYPE`. No arithmetic path can widen to the 80-bit x86 or
  128-bit aarch64 long double, because no such type is used.
- **Float→text is pure integer arithmetic.** `sqlite3FpDecode()` `memcpy`s the
  double into a `u64`, extracts sign/exponent/mantissa by bit masking, and hands
  them to `sqlite3Fp2Convert10()`, which works from a table of
  `pow(10,p) << k` constants. No `printf("%f")`, no libc `dtoa`, no FP
  arithmetic. Text→float (`sqlite3AtoF`) is the mirror image: `u64 s` mantissa
  plus an `int d` decimal exponent (`/* Value is s * pow(10,d) */`), converted
  through the same integer tables.
- **`sum()` uses Kahan-Babuška-Neumaier accumulation over a `volatile SumCtx`.**
  The `volatile` forces each step through memory, which defeats x87 excess
  precision retention as well as compiler reassociation.
- **No `-ffast-math` or precision flag** appears in the recipe, in
  `sqlite-config.tcl`, in `Makefile.in`, or in the recorded `cc` lines.

The residual x87 exposure is ordinary `double` arithmetic in the VDBE's
arithmetic opcodes on i686 with GCC's default `-mfpmath=387`. **This is out of
reach for v1 by premise**: #1 settles that ops are *fully materialized* — the
client evaluates predicates and expressions in Julia and writes the resulting
values into the record — so SQLite is never asked to compute a floating-point
expression whose result is stored. It becomes reachable again the day a predicate
or expression grammar is added, and that is the moment to revisit i686.

One target-conditional code path does exist and is **invisible to
`compile_options`**: the source self-defines

```c
#if (defined(__arm__) && !defined(__aarch64__)) || \
    (defined(__ppc__) && !defined(__ppc64__))
# define SQLITE_AVOID_U64_DIVIDE 1
#endif
```

on 32-bit ARM and 32-bit PowerPC, switching integer→text rendering to a
u32-division strategy. It is a performance strategy producing the same digits,
and `SQLITE_AVOID_U64_DIVIDE` is not in `ctime.c`'s list, so no runtime guard can
see it. It is the proof that "compile options match" is a weaker statement than
"the same code was compiled".

### 6. `SQLITE_ENABLE_MATH_FUNCTIONS` — uniform option, non-uniform values

This is the sharpest *results* risk in the option set, and it is sharp precisely
because the option **is** uniformly enabled.

<https://www.sqlite.org/lang_mathfunc.html>:

> "The math functions shown below are a subgroup of scalar functions that are
> built into the SQLite amalgamation source file but are only active if the
> amalgamation is compiled using the `-DSQLITE_ENABLE_MATH_FUNCTIONS`
> compile-time option."
>
> "The values returned by these functions are often approximations."

In the source, `pow`, `mod`, `atan2`, `ceil`, `floor`, `trunc` and friends are
registered through `MFUNCTION(...)` macros that name the **C library function
directly** (`MFUNCTION(pow, 2, pow, math2Func)`), and `logFunc` / `math1Func` call
libm likewise. The `ENABLE_` flag is therefore identical everywhere while the
*implementation* is glibc on one client, musl on another, Apple's libm on a
third, and mingw's on a fourth. libm is not required to be correctly rounded for
`pow`, `exp`, `log` or the trigonometric functions, and these implementations are
known to differ in the last ulp.

**[empirical]** On macOS aarch64, `SELECT pow(1.0000001, 1e7)` returns
`2.7182816941320818` (bits `0x4005bf0a790ce6f2`). There is no reason to expect
the same bits from glibc's `pow` on x86-64, and no documented guarantee that
there would be.

Same argument for `SQLITE_ENABLE_PERCENTILE` (interpolating percentiles do
floating-point arithmetic) and for FTS5's ranking. The v1 posture already
excludes all of this — records carry materialized values, not expressions — so
the verdict is PINNED-as-excluded rather than CHECKED.

### 7. `SQLITE_ENABLE_ICU` — absent, and must stay absent

Not enabled on any platform. If it ever were, it would change results
immediately. From the extension's own README
(<https://sqlite.org/src/doc/trunk/ext/icu/README.txt>):

> "SQLite's built-in implementations of these two functions [`upper()`,
> `lower()`] only provide case mapping for the 26 letters used in the English
> language. The ICU based functions provided by this extension provide case
> mapping, where defined, for the full range of unicode characters."
>
> "The implementation of LIKE included in this extension uses the ICU function
> `u_foldCase()` to provide case independent comparisons for the full range of
> unicode characters."

So ICU *replaces* `upper`, `lower` and `LIKE`, and adds `icu_load_collation()`.
Worse than a build difference, it makes results depend on the ICU library's CLDR
data version. This is the one option whose presence should be a hard error at
open. Its absence is also what makes #3 hazard 4 ("built-in collations are safe,
ASCII-only by definition") true for these artifacts.

### 8. Limits, durability, threading — not results

- **`SQLITE_MAX_LENGTH=1000000000`** (SQLite's default; not set by the recipe).
  <https://www.sqlite.org/limits.html> describes it as the maximum bytes in a
  string or BLOB. It decides whether an operation is *accepted*, never what value
  an accepted operation stores. Uniform across all 13. It is nonetheless worth
  a CHECK, because `sqlite3_limit()` can lower it per connection at runtime and
  a lowered limit would turn a record that replayed fine on one client into an
  error on another — a fail-fast divergence rather than a silent one, but still a
  fork.
- **`SQLITE_DEFAULT_SYNCHRONOUS=2`** (= `NORMAL`) is a durability/fsync setting.
  **[empirical]** `PRAGMA synchronous` = 2. Nothing about content.
- **`SQLITE_THREADSAFE=1`** — serialized mode. compile.html describes
  `-DSQLITE_THREADSAFE=0` purely as omitting "all of the mutex and thread-safety
  logic … about 2% faster". Concurrency, not results. (It is also the one option
  `ctime.c` special-cases to report even when undefined, falling back to
  `"THREADSAFE=1"`.)
- **`SQLITE_SECURE_DELETE`, `DEFAULT_AUTOVACUUM`, `DEFAULT_PAGE_SIZE`** change the
  *bytes of the file* without changing its logical content. They are IGNORED only
  because #1 already settles that the `state_fingerprint` is over logical content.
  They are an independent proof that hashing the `.sqlite` file itself would never
  have worked.

### 9. `PRAGMA compile_options` as a runtime guard

It is cheap and it works, with three caveats that determine its shape.

<https://www.sqlite.org/pragma.html#pragma_compile_options>:

> "This pragma returns the names of compile-time options used when building
> SQLite, one option per row. The 'SQLITE_' prefix is omitted from the returned
> option names. See also the `sqlite3_compileoption_get()` C/C++ interface and
> the `sqlite_compileoption_get()` SQL functions."

Caveats, all established above:

1. **A pinned full list is wrong.** `COMPILER=` differs on three of the thirteen
   platforms, and `MUTEX_PTHREADS`/`MUTEX_W32` differs on Windows. A byte-compare
   of the 51-row list against a recorded baseline fails on macOS, on Windows and
   on riscv64 for reasons that mean nothing.
2. **Defaults are not reported.** The most dangerous setting in the build —
   `DQS=3` — produces no row. A guard can only assert about options that are
   *present*; it can never read a default off this list.
3. **It does not identify the version.** 3.51.2 and 3.53.2 have identical option
   sets and *different results*.

The usable shape is therefore an **allowlist with values plus a denylist**, not a
hash of the whole list:

- assert equality on the results-relevant subset:
  `ENABLE_MATH_FUNCTIONS`, `SECURE_DELETE`, `THREADSAFE=1`, `TEMP_STORE=1`,
  `MAX_LENGTH=1000000000`, `MAX_VARIABLE_NUMBER=250000`, `MAX_EXPR_DEPTH=10000`,
  `DEFAULT_SYNCHRONOUS=2`, `ENABLE_FTS3/4/5`, `ENABLE_RTREE`;
- assert **absence** of `ENABLE_ICU`, `MIXED_ENDIAN_64BIT_FLOAT`,
  `DEFAULT_FOREIGN_KEYS`, `ENABLE_UPDATE_DELETE_LIMIT`, `CASE_SENSITIVE_LIKE`,
  `LIKE_DOESNT_MATCH_BLOBS`, and any row beginning `OMIT_`;
- ignore `COMPILER=` and `MUTEX_*` explicitly, by name, so the ignore is a
  decision rather than an accident;
- and carry `sqlite_version()` separately, because the option list cannot stand in
  for it.

A hash over the *filtered, sorted* subset is fine and is cheaper to store in the
envelope than the list; a hash over the raw list is not.

Note for the record: none of this defends against a user's `libsqlite3` that is
not the jll's (e.g. `LD_PRELOAD`, a system library, a distro Julia). The guard
should read the loaded library's own answers — which `PRAGMA compile_options` and
`sqlite_version()` do — rather than the `SQLite_jll` version string.

### 10. Does sqlite.org flag any option as affecting results?

**No — there is no such taxonomy.** <https://www.sqlite.org/compile.html> is
organised by mechanism (§"Options To Set Default Parameter Values", §"Options To
Set Size Limits", §"Options To Control Operating Characteristics", §"Options To
Omit Features"), not by risk to query results, and searching the page for
"result", "answer", "different result" turns up only performance and API text. The
closest thing to a warning is the *Recommended Compile-time Options* section,
whose first entry is:

> "`SQLITE_DQS=0`. This setting disables the double-quoted string literal
> misfeature."

— which is exactly the option `SQLite_jll` leaves at its permissive default.

The practical reading: sqlite.org will not tell a client which options are safe.
The allowlist in §9 has to be curated by us and reviewed when the recipe changes.

### 11. `CHECK` constraints: closed, and the answer is "never enforced"

#3 left this open, suspecting a version boundary. There is none, and the docs are
not in conflict with the observed behaviour — #3 simply had not read far enough
down the page. <https://www.sqlite.org/deterministic.html> §2.1, *Historical
exception for CHECK constraints* (page last updated 2026-05-20):

> "It is stated above that non-deterministic functions are not allowed in CHECK
> constraints. That really ought to be the case, but due to an historical bug and
> the desire to maintain backwards compatibility, that restriction is not
> actually enforced. You can put a non-deterministic function inside of a CHECK
> constraints and SQLite will not complain. Doing so will not cause a crash or
> memory error. But apart from not crashing, no guarantees are made about how
> that CHECK constraint will function. You ought not do this. If you ignore this
> advice and you get unexpected behavior, that will not be considered a bug
> (unless it crashes, as crashes are always considered bugs)."

Non-enforcement is therefore **permanent policy**, not a bug awaiting a fix. The
partial-index, expression-index and generated-column contexts *are* enforced; only
`CHECK` is exempt.

**[empirical]**, through `SQLite.jl` on the real library:

| `SQLite_jll` | `CREATE TABLE t(x INTEGER, CHECK (x < random()))` | Behaviour |
|---|---|---|
| 3.53.2+0 | accepted | 10 of 20 sequential `INSERT`s succeeded, at random |
| 3.51.2+0 | accepted | accepted |

`DEFAULT (random())` is likewise accepted on 3.53.2 and produced two different
64-bit values on two `INSERT ... DEFAULT VALUES` — confirming #3 hazard 16 at the
newest admitted version.

Changelog search for the boundary: <https://www.sqlite.org/changes.html> mentions
non-determinism enforcement exactly once, at **3.35.2 (2021-03-17)** — "Ensure
that date/time functions with no arguments … are treated as non-deterministic
functions", ticket `2c6c8689fb5f3d2f` — which tightened the *other* contexts, not
`CHECK`. **There is no version floor that buys `CHECK` safety.** The design must
validate `CHECK` expressions itself, exactly as #3 concluded.

### 12. The live divergence is still the version, not the build

**[empirical]** Same machine, same `SQLite.jl` 1.8.2, same 51 compile options,
only the jll version pinned differently:

| | `cast(0.1+0.2 AS TEXT)` | `cast(1.0/3.0 AS TEXT)` |
|---|---|---|
| `SQLite_jll` 3.51.2+0 | `0.3` | `0.333333333333333` |
| `SQLite_jll` 3.53.2+0 | `0.30000000000000004` | `0.33333333333333332` |

Both versions satisfy `SQLite.jl` 1.8.2's `SQLite_jll = "3.51.0 - 3"`, so two
clients that both did `Pkg.add("SQLite")` a few months apart get these two
libraries. This is #3 hazard 8 and 22 demonstrated end-to-end rather than inferred
from the changelog, and it is the reason the build guard must never be mistaken
for a version guard.

---

## Actions this implies

1. **Guard at open, with two independent assertions**: `sqlite_version()` against
   the declared supported set, and the `PRAGMA compile_options` allowlist/denylist
   of §9. Hard-error on either. Both go in the same open-time check as #3's
   action 8.
2. **Record both in the envelope**: the version string, and a hash of the
   *filtered* option subset. `COMPILER=` and `MUTEX_*` are excluded by name.
3. **Never probe behaviour with the bundled `sqlite3` CLI.** It is a different
   build. Every determinism test must go through `SQLite.jl`/`libsqlite3`.
4. **Treat DQS as unfixable at the library level**: the builder always
   single-quotes literals and always double-quotes (or brackets) identifiers, and
   DDL validation rejects any double-quoted token in a value position. There is no
   `sqlite3_db_config` wrapper in `SQLite.jl` to fall back on.
5. **Exclude math functions, `percentile`, FTS ranking and R-tree from anything
   that reaches the fingerprint.** They are enabled on every artifact and their
   values come from the platform's libm.
6. **`CHECK` is validated by us or not permitted at all.** SQLite will never
   reject a non-deterministic one.
7. **If a predicate/expression grammar is ever added** (explicitly deferred by
   #1), re-open the i686 x87 question: at that point SQLite starts evaluating
   floating-point arithmetic whose result is stored, and `-mfpmath=387` on the
   32-bit builds becomes reachable.

---

## Not settled

1. **Whether the guard should pin an exact version or a range.** This research
   shows the two admitted versions *do* differ in results, which argues for an
   exact pin — but an exact pin in `SQLite.jl`'s dependency graph is not something
   this package can enforce for the user, only detect. The shape of the failure
   (refuse to open, or refuse to write) belongs to
   [#9](https://github.com/jonalm/S3SQLite/issues/9)/[#10](https://github.com/jonalm/S3SQLite/issues/10).
2. **Whether the option allowlist should be versioned alongside the record schema
   version.** A future Yggdrasil recipe edit (the flags last changed in 2022, but
   they *can* change) would make every existing client reject every new client.
   The allowlist needs its own evolution rule, which is the same open question as
   record-schema evolution in #1's "Not yet specified".
3. **Actual cross-platform libm divergence, measured.** §6 argues from the source
   and the absence of any guarantee; I did not run the same `pow`/`log` inputs on
   glibc, musl, Apple and mingw builds and diff the bits. Doing so would only
   strengthen an exclusion the design already makes, so it was not worth the
   cross-compilation; if anyone ever wants math functions inside the chain, that
   measurement is the prerequisite.
4. **Windows and FreeBSD were compared as binaries, not run.** The 13-platform
   comparison is a string-table extraction validated against a live pragma on one
   platform. It would take a real CI matrix to show that the *behaviour* matches,
   not just the option list — and §5's `SQLITE_AVOID_U64_DIVIDE` shows the option
   list is not the whole story.
5. **Non-jll libraries.** If a user's Julia loads a system `libsqlite3` (distro
   packages frequently enable ICU), all of the above is void and only the runtime
   guard catches it. Whether to refuse outright or warn is a policy question for
   the error taxonomy.
