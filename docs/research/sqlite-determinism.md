# SQLite replay determinism hazards

Research for [#3](https://github.com/jonalm/S3SQLite/issues/3) (part of [#1](https://github.com/jonalm/S3SQLite/issues/1)).

**Question.** Two S3SQLite clients replay the *same* sequence of structured write
operations against their own local SQLite file. What can make their resulting
**logical database content** differ?

**Model assumed** (settled premises of #1): records carry structured ops, not SQL
text; v1 ops are *fully materialized* (the client evaluates predicates locally and
puts the resulting row set in the record); DDL is in the same chain; every record
carries a `state_fingerprint` over the whole logical content, recomputed and
hard-checked by every client.

**Verdict vocabulary**

- **exclude** — the v1 op/DDL design must make this unreachable. A record that
  could express it is a bug in the design.
- **pin** — it is reachable and must be *fixed by the library*: a pragma set on
  every connection, a version floor checked at open, or a rule baked into the
  canonical encoding / fingerprint definition.
- **ignore** — deterministic given the same op sequence, or already excluded by a
  premise; no design action needed.

Sources are sqlite.org and the Julia General registry. Claims marked
**[empirical]** were produced locally against `sqlite3` **3.43.2** (macOS
arm64) and are *not* documented guarantees — they show what one build does, not
what any build must do.

---

## Verdict table

| # | Hazard | Verdict | One-line reason |
|---|--------|---------|-----------------|
| 1 | Implicit `rowid` assignment on INSERT | **exclude** | Assignment is max+1, but becomes *random* once the max rowid is `2^63-1`; rowids are also silently reused after DELETE, so a rowid is not a stable identity. |
| 2 | `AUTOINCREMENT` / `sqlite_sequence` | **exclude** | Adds a hidden mutable counter table to the file that replay must also reproduce, and hard-fails `SQLITE_FULL` at the ceiling. Explicit keys make it pointless. |
| 3 | `WITHOUT ROWID` tables | **ignore** | Documented to give the same answers to the same SQL; removes the rowid hazard entirely. Permit, even prefer. |
| 4 | Built-in collations `BINARY` / `NOCASE` / `RTRIM` | **ignore** | Defined by `memcmp` / `sqlite3_strnicmp` over the 26 ASCII letters; no changelog entry has ever altered them. Stable across versions and builds. |
| 5 | User-defined / ICU collations named in a schema | **exclude** | A client without that collation registered cannot even prepare the statement (`no such collation sequence`), and its semantics live outside the chain. |
| 6 | Type affinity / implicit conversion on INSERT | **pin** | The stored value routinely differs from the supplied one (`'500.0'` into `NUMERIC` stores integer `500`). Pin by requiring `STRICT` tables, or by applying affinity in the builder before hashing. |
| 7 | `REAL` bit-identity across platforms | **ignore** (storage) / **pin** (any text path) | Stored as big-endian IEEE-754 binary64 in the file format — bit-identical. But `SQLITE_MIXED_ENDIAN_64BIT_FLOAT` builds exist, and float↔text is version-dependent (see 8). |
| 8 | Float↔text conversion changed in 3.53.0 | **pin** | Default rounding went 15 → 17 significant digits in 3.53.0. Never route a float through SQLite text in the record encoding or the fingerprint. |
| 9 | `Inf` / `NaN` in `REAL` columns | **exclude** | `NaN` is silently coerced to `NULL`; `±Inf` stores fine but `CAST('Inf' AS REAL)` is `0.0`, so it does not survive a text round-trip. |
| 10 | Database text encoding (`PRAGMA encoding`) | **pin** | Fixed at file creation and unchangeable; `BINARY` compares "regardless of text encoding", so UTF-16 and UTF-8 files order the same strings differently. Pin UTF-8. |
| 11 | Unicode normalization of `TEXT` | **pin** (as: none) | SQLite performs no normalization — NFC and NFD are distinct values. The canonical encoding must be byte-preserving and must not normalize. |
| 12 | Embedded `U+0000` in `TEXT` | **exclude** | Documented quirk: NUL is allowed mid-string, but `NOCASE` treats it as a string terminator. |
| 13 | Row order without `ORDER BY` (fingerprint only) | **pin** | Explicitly *undefined*, and observably flips when an index appears. The fingerprint must impose its own total order. |
| 14 | `NULL` ordering / ties in `ORDER BY` | **pin** | NULLs first is documented, but the order of rows whose `ORDER BY` keys are all equal is *undefined*. The fingerprint's order must be total. |
| 15 | Non-deterministic functions (`random`, `randomblob`, date/time, `CURRENT_TIMESTAMP`) | **exclude** | Already excluded by the "fully materialized ops" premise — but only if the builder is *unable* to emit them, not merely discouraged. |
| 16 | Column `DEFAULT` expressions | **exclude** | `DEFAULT (random())`, `DEFAULT (randomblob(4))` and `DEFAULT CURRENT_TIMESTAMP` are all explicitly legal and evaluated **per inserted row**. This is the sharpest hazard in DDL. |
| 17 | `CHECK` constraints | **exclude** (non-literal exprs) | The docs say non-deterministic functions are barred from `CHECK`; 3.43.2 accepts `CHECK(x < random())` and evaluates it at INSERT, so the insert succeeds or fails at random. |
| 18 | `PRAGMA foreign_keys` skew | **pin** | Off by default, per-*connection*, not stored in the file, and **SQLite.jl does not set it** — so the same `DELETE` cascades on one client and not another. |
| 19 | FK actions (`CASCADE`, `SET NULL`, `SET DEFAULT`, `RESTRICT`) | **exclude** (as implicit effects) | Deterministic *given* 18, but they mutate rows the record never mentions; `SET DEFAULT` re-opens 16. Materialize the effects into the record. |
| 20 | Triggers | **exclude** | Firing order among several triggers on one event is undocumented; BEFORE-trigger interactions and `NEW.rowid` in BEFORE INSERT are explicitly "undefined". |
| 21 | `INSERT OR REPLACE` / `ON CONFLICT ... REPLACE` | **exclude** | Silently deletes *other* rows to make room; those deletions never appear in the op. Materialize them. |
| 22 | SQLite version skew between clients | **pin** | `SQLite.jl` 1.7.1+ allows `SQLite_jll = "3.51.0 - 3"`; the registry currently offers **both** 3.51.2 and 3.53.2, which differ on hazard 8. |
| 23 | `STRICT` tables as the affinity fix | **pin** (version floor ≥ 3.37.0) | Turns silent coercion into `SQLITE_CONSTRAINT_DATATYPE`; pre-3.37 libraries cannot read such a file normally. |
| 24 | Double-quoted string literals (DQS) | **exclude** (by construction) | Whether `"foo"` is an identifier or a string literal is a *build/dbconfig* setting. Always single-quote literals and always quote identifiers. |
| 25 | Connection pragmas: `legacy_alter_table`, `recursive_triggers`, `case_sensitive_like` | **pin** | All per-connection, none stored in the file, all able to change what a statement does. |
| 26 | `sqlite_schema.sql` text as fingerprint input | **pin** (exclude it) | `ALTER TABLE RENAME` rewrites schema text, and the exact rendering varies by version. Fingerprint normalized structure or the op chain, not raw DDL text. |
| 27 | Integer overflow → REAL promotion, integer division | **ignore** | Deterministic and long-stable; and v1 records carry no expressions to evaluate. |
| 28 | Bare columns in aggregate queries | **ignore** | Undefined, but a *read*-side concern; no v1 op evaluates a query server-side. |

---

## Detail

### 1–2. `rowid` and `AUTOINCREMENT`

Default assignment is deterministic *in the common case*:

> "The usual algorithm is to give the newly created row a ROWID that is one larger
> than the largest ROWID in the table prior to the insert. If the table is
> initially empty, then a ROWID of 1 is used."
> — <https://www.sqlite.org/autoinc.html>

Two things break it. First, the ceiling:

> "If the largest ROWID is equal to the largest possible integer
> (9223372036854775807) then the database engine starts picking positive candidate
> ROWIDs at random until it finds one that is not previously used."
> — <https://www.sqlite.org/autoinc.html>

**[empirical]** Confirmed: inserting a second row after a row with rowid
`9223372036854775807` produced rowid `3103591829205053183` — a value that will
differ on the next client. That single insert forks the chain permanently.

Second, reuse:

> "If you ever delete rows or if you ever create a row with the maximum possible
> ROWID, then ROWIDs from previously deleted rows might be reused when creating
> new rows and newly created ROWIDs might not be in strictly ascending order."
> — <https://www.sqlite.org/autoinc.html>

**[empirical]** Confirmed: inserting 1,2,3, deleting rowid 3, then inserting again
yields rowid 3 again.

Reuse is *reproducible* under identical replay, so it is not by itself a divergence
— but it means a rowid is not a durable identity, so a record that refers to a row
"by rowid" from an earlier point in the chain can silently address a different row.
Combined with the ceiling case, the conclusion is the same: **ops must carry the
row key explicitly**; the design must never let SQLite choose one.

`AUTOINCREMENT` does not fix this. It introduces `sqlite_sequence`:

> "SQLite keeps track of the largest ROWID using an internal table named
> 'sqlite_sequence'." — <https://www.sqlite.org/autoinc.html>

That is a real table in the file whose contents are part of what replay must
reproduce and what the fingerprint must decide about, and it fails hard at the
ceiling — **[empirical]** `INSERT` after rowid `2^63-1` in an `AUTOINCREMENT`
table returns `database or disk is full (SQLITE_FULL)`, matching the documented
behaviour. With explicit keys there is no reason to carry it.

Note the alias rule when validating DDL:

> "A PRIMARY KEY column only becomes an integer primary key if the declared type
> name is exactly 'INTEGER'. Other integer type names like 'INT' or 'BIGINT' ...
> causes the primary key column to behave as an ordinary table column with integer
> affinity and a unique index, not as an alias for the rowid."
> — <https://www.sqlite.org/lang_createtable.html>

`INT PRIMARY KEY` and `INTEGER PRIMARY KEY` are different tables. The DDL op must
preserve the declared type verbatim.

### 3. `WITHOUT ROWID`

> "Anything that can be done using a WITHOUT ROWID table can also be done in
> exactly the same way, and exactly the same syntax, using an ordinary rowid table
> ... They both generate the same answers given the same SQL statements."
> — <https://www.sqlite.org/withoutrowid.html>

> "NOT NULL is enforced on every column of the PRIMARY KEY in a WITHOUT ROWID
> table." — <https://www.sqlite.org/withoutrowid.html>

No hazard; it removes one. Worth considering as the *recommended* table shape for
v1, since it makes the "no implicit rowid" rule structural rather than
conventional.

### 4–5. Collations

> "SQLite has three built-in collating functions: BINARY, NOCASE, and RTRIM.
> BINARY - Compares string data using memcmp(), regardless of text encoding.
> NOCASE - Similar to binary, except that it uses sqlite3_strnicmp() ... Hence the
> 26 upper case characters of ASCII are folded to their lower case equivalents ...
> Note that only ASCII characters are case folded. SQLite does not attempt to do
> full UTF case folding due to the size of the tables required. Also note that any
> U+0000 characters in the string are considered string terminators for comparison
> purposes. RTRIM - The same as binary, except that trailing space characters are
> ignored." — <https://www.sqlite.org/datatype3.html#collating_sequences>

**Is `NOCASE` stable across versions and builds?** Yes, on the evidence available:
it is *defined* as folding exactly the 26 ASCII uppercase letters, no version in
the changelog changes it, and the ICU extension — the obvious thing that might —
overrides `upper()`, `lower()`, `LIKE` and `REGEXP` and registers *new* collations
via `icu_load_collation()`; it does not redefine `NOCASE`
(<https://sqlite.org/src/doc/trunk/ext/icu/README.txt>).

**[empirical]** `'A' = 'a' COLLATE NOCASE` → 1; `'Æ' = 'æ' COLLATE NOCASE` → 0.
ASCII-only confirmed.

Collation still *matters* for content, because it decides `UNIQUE` and `PRIMARY
KEY` equality and therefore which row survives a conflict. That is deterministic
given the same built-in collation on both sides, so: ignore.

User-defined collations are a different story. **[empirical]** `CREATE TABLE
c1(a TEXT COLLATE MYCOLL)` fails at prepare with `no such collation sequence:
MYCOLL` when the collation is not registered on the connection. A schema that
names a collation defined in application code makes the file unreadable to a
client that lacks it, and the comparison semantics would live outside the chain
entirely. Exclude from v1 DDL.

### 6. Type affinity and implicit conversion

Affinity is derived from the *spelling* of the declared type
(<https://www.sqlite.org/datatype3.html#determination_of_column_affinity>), with
traps: `"FLOATING POINT"` gets INTEGER affinity because it contains `INT`, and
`"STRING"` gets NUMERIC, not TEXT.

The stored value is then routinely not the supplied value. From the documented
example:

```sql
CREATE TABLE t1(t TEXT, nu NUMERIC, i INTEGER, r REAL, no BLOB);
INSERT INTO t1 VALUES('500.0','500.0','500.0','500.0','500.0');
-- typeof: text|integer|integer|real|text
INSERT INTO t1 VALUES(500.0, 500.0, 500.0, 500.0, 500.0);
-- typeof: text|integer|integer|real|real
```
— <https://www.sqlite.org/datatype3.html#affinity_and_type_example>

**[empirical]** Same shape confirmed on 3.43.2, including `'1e3'` into a `NUMERIC`
column being stored as integer `1000`, and `'12x'` into an `INTEGER` column
staying `text`.

This is deterministic given the same declared type and the same library, so it is
not *by itself* a fork. It is a hazard for two reasons:

1. The fingerprint hashes the *stored* value, so the builder cannot hash what the
   caller handed it — it must either apply the affinity rules itself or hash after
   read-back.
2. Affinity behaviour is where version drift is most likely to bite (see 22).

The clean fix is **STRICT tables** (hazard 23): the coercion either succeeds
losslessly or raises, so the builder can reject at write time instead of
discovering divergence at fingerprint time.

> "If the value cannot be losslessly converted in the specified datatype, then an
> SQLITE_CONSTRAINT_DATATYPE error is raised."
> — <https://www.sqlite.org/stricttables.html>

One documented *genuine* indeterminacy, out of reach for v1 but worth recording
for the future expression grammar:

> "However, it is indeterminate which of the SELECT statements will be used to
> determine affinity ... The choice might vary across different versions of
> SQLite. The choice might change between one query and the next in the same
> version of SQLite."
> — <https://www.sqlite.org/datatype3.html#affinity_of_compound_views>

### 7–9. `REAL`

Storage is exact and portable:

> "REAL. The value is a floating point value, stored as an 8-byte IEEE floating
> point number." — <https://www.sqlite.org/datatype3.html>

> "7 | 8 | Value is a big-endian IEEE 754-2008 64-bit floating point number."
> — <https://www.sqlite.org/fileformat2.html> (serial type codes)

So a `Float64` written by one client is bit-identical on another **as long as it
never passes through text**, and as long as nobody builds with
`SQLITE_MIXED_ENDIAN_64BIT_FLOAT` — a real compile-time option added in 3.4.0
"to support ARM7 processors with goofy endianness"
(<https://www.sqlite.org/changes.html>). Not a concern for `SQLite_jll` builds,
but it is the reason "bit-identical" is a property of the *build*, not of SQLite.

The integer-packing optimisation is invisible and safe:

> "As an internal optimization, small floating point values with no fractional
> component and stored in columns with REAL affinity are written to disk as
> integers in order to take up less space and are automatically converted back
> into floating point as the value is read out. This optimization is completely
> invisible at the SQL level."
> — <https://www.sqlite.org/datatype3.html>

The text path is *not* safe, and this is the single clearest version-to-version
behaviour change relevant to this design:

> "Improvements to floating-point ↔ text conversions. Reimplemented to improve
> performance. **Rounding is now done by default to 17 significant digits,
> instead of 15, as was the case for all prior versions.** The
> sqlite3_db_config(SQLITE_DBCONFIG_FP_DIGITS) API can change this, if desired."
> — SQLite 3.53.0 (2026-04-09), <https://www.sqlite.org/changes.html>

> "Rounding to 17 significant digits or more results in text that, when converted
> back into binary-64, gives the exact same value that we started with."
> — <https://www.sqlite.org/floatingpoint.html>

**[empirical]** On 3.43.2 (15-digit era): `SELECT 9007199254740993.0` renders as
`9.00719925474099e+15`. A 3.53.x client renders the same stored bits differently.
Anything that hashes or compares that rendering forks the chain **between clients
that are both running "the current SQLite.jl"**.

Consequences the design must adopt: the record's canonical encoding of a float is
the 8 IEEE bytes (or a documented exact decimal form the *library* produces, not
SQLite); the fingerprint reads floats as `Float64` and hashes bits; the builder
never emits a float into SQL as a text literal.

Also (relevant to the *domain* of allowed values):

**[empirical]** `INSERT INTO f(x REAL) VALUES(1e400)` stores `Inf`, `typeof` =
`real`, `CAST(x AS TEXT)` = `'Inf'` — but `CAST('Inf' AS REAL)` = `0.0`. So `±Inf`
does not survive any text round-trip. And `typeof(0.0/0.0)` is `null` — NaN is
coerced away, consistent with the 3.5.x changelog entry "Always convert IEEE
floating point NaN values into NULL during processing"
(<https://www.sqlite.org/changes.html>). The op design should reject non-finite
floats rather than define semantics for them.

### 10–12. `TEXT` encoding and normalization

> "It is not possible to change the text encoding of a database after it has been
> created and any attempt to do so will be silently ignored."
> — <https://www.sqlite.org/pragma.html#pragma_encoding>

> "If no encoding is first set with this pragma, then the encoding with which the
> main database will be created defaults to one determined by the API used to open
> the connection." — same

The default therefore depends on how the client opened the file. Since `BINARY`
"compares string data using memcmp(), **regardless of text encoding**"
(<https://www.sqlite.org/datatype3.html#collating_sequences>), a UTF-16 database
and a UTF-8 database sort the same set of strings into different orders wherever
UTF-8 byte order and UTF-16 code-unit order disagree (astral-plane characters
versus U+E000..U+FFFF). Equality is unaffected, so row *content* survives, but
`ORDER BY`, index order, and anything the fingerprint derives from ordering do
not. **Pin `PRAGMA encoding = 'UTF-8'` at file creation** and verify it on open.

There is no normalization anywhere: SQLite stores TEXT "using the database
encoding" and no documentation claims any normalization step.
**[empirical]** `CAST(x'C3A9' AS TEXT) = CAST(x'65CC81' AS TEXT)` → 0, with
`length()` 1 and 2 respectively. So "é" typed two ways is two different values.
This is fine for determinism (byte-preserving in, byte-preserving out) but must be
stated: the canonical record encoding must be byte-preserving and must **not**
normalize, or a client whose JSON/text layer normalizes on the way in will write a
different value than the one it hashed.

Embedded NULs are a documented quirk:

> "NUL characters (ASCII code 0x00 and Unicode U+0000) may appear in the middle
> of strings in SQLite. This can lead to unexpected behavior."
> — <https://www.sqlite.org/quirks.html> (see also
> <https://www.sqlite.org/nulinstr.html>)

combined with the `NOCASE` note that "any U+0000 characters in the string are
considered string terminators for comparison purposes". Two strings that differ
only after an embedded NUL are distinct values but compare equal under `NOCASE`.
Reject embedded NUL in TEXT at the op boundary; use BLOB for arbitrary bytes.

### 13–14. Row order and NULL ordering (fingerprint, not ops)

> "If a SELECT statement that returns more than one row does not have an ORDER BY
> clause, the order in which the rows are returned is undefined."
> — <https://www.sqlite.org/lang_select.html#the_order_by_clause>

> "The order in which two rows for which all ORDER BY expressions evaluate to
> equal values are returned is undefined." — same

> "SQLite considers NULL values to be smaller than any other values for sorting
> purposes." — same

> "When query results are sorted by an ORDER BY clause, values with storage class
> NULL come first, followed by INTEGER and REAL values interspersed in numeric
> order, followed by TEXT values in collating sequence order, and finally BLOB
> values in memcmp() order." — <https://www.sqlite.org/datatype3.html#sort_order>

**[empirical]** `SELECT k FROM u` returned `c,a,b` before `CREATE INDEX ui ON
u(k)` and `a,b,c` after — same rows, same statement, different order, purely
because an index appeared. Physical order is not content.

The fingerprint definition (issue #7) therefore cannot be "read the rows and
hash them in the order they arrive". It needs a **total** order defined by the
library — over tables (name), columns (declared order), and rows (full-row
lexicographic over a canonical value encoding, with a defined storage-class rank
and a defined tie-break) — computed in Julia, not delegated to SQLite's
`ORDER BY`. Delegating would import both the collation choice and the
storage-class interleaving rules as version-coupled dependencies.

### 15–17. Non-deterministic functions, `DEFAULT`, `CHECK`

> "A deterministic function always gives the same answer when it has the same
> inputs. ... Non-deterministic functions might give different answers on each
> invocation, even if the arguments are always the same."
> — <https://www.sqlite.org/deterministic.html>

Named non-deterministic built-ins: `random()`, `changes()`, `last_insert_rowid()`,
`sqlite3_version()` (ibid.). `randomblob(N)` is the same family
(<https://www.sqlite.org/lang_corefunc.html>). Date/time functions add a second
axis — host clock *and* host timezone:

> "The 'now' argument to date and time functions always returns exactly the same
> value for multiple invocations within the same sqlite3_step() call. Universal
> Coordinated Time (UTC) is used."
> — <https://www.sqlite.org/lang_datefunc.html>

> "The computation of local time depends heavily on the whim of politicians and is
> thus difficult to get correct for all locales. In this implementation, the
> standard C library function localtime_r() is used to assist in the calculation
> of local time." — ibid.

Because v1 ops are fully materialized, none of this should ever reach SQL. The
design action is to make it *structurally impossible*: the op format carries
values, never expressions, so there is no slot in which `random()` could be
written. That is already the premise; this ticket only confirms it is the right
one.

**DDL is the leak.** The `DEFAULT` clause explicitly admits non-deterministic
expressions:

> "An explicit DEFAULT clause may specify that the default value is NULL, a string
> constant, a blob constant, a signed-number, or any constant expression enclosed
> in parentheses. ... A default value may also be one of the special
> case-independent keywords CURRENT_TIME, CURRENT_DATE or CURRENT_TIMESTAMP."
> — <https://www.sqlite.org/lang_createtable.html>

> "If the default value of a column is an expression in parentheses, then the
> expression is evaluated **once for each row inserted** and the results used in
> the new row." — ibid.

And "constant" here means only "no sub-queries, column or table references, bound
parameters, or double-quoted string literals" — it does **not** mean
deterministic.

**[empirical]** `CREATE TABLE d1(a INTEGER DEFAULT (random()), b TEXT DEFAULT
CURRENT_TIMESTAMP, c TEXT DEFAULT (datetime('now')), e BLOB DEFAULT
(randomblob(4)))` is accepted, and two `INSERT ... DEFAULT VALUES` produced two
distinct `a` values and two distinct `e` blobs. This is the sharpest hazard found:
one accepted DDL record and every subsequent insert forks the chain.

Two layers of defence, both needed:

1. **Every INSERT op names every column.** Then no `DEFAULT` is ever evaluated,
   whatever the schema says. (This also makes the op self-describing for
   point-in-time rebuild.)
2. **The DDL op validates `DEFAULT` down to a literal.** NULL, a signed number, a
   string constant, a blob constant. No parenthesised expression, no
   `CURRENT_TIMESTAMP`. Layer 1 alone is not enough because `ON UPDATE SET
   DEFAULT` and future ops could still reach it.

`CHECK` is worse than documented. The docs say:

> "In the expression of a CHECK constraint ... only deterministic functions can be
> used" — <https://www.sqlite.org/deterministic.html>

**[empirical]** but 3.43.2 *accepts* `CREATE TABLE d2(x, CHECK (x < random()))`
and evaluates it at INSERT time — the insert then succeeds or fails at random
(the probe insert failed with `CHECK constraint failed: x < random()`). By
contrast, generated columns *are* enforced: `CREATE TABLE g(x, y AS (x+random()))`
is rejected at prepare with `non-deterministic functions prohibited in generated
columns`. So the enforcement the docs describe is real for generated columns and
(at least in 3.43.2) absent for plain `CHECK`.

Conclusion: **do not rely on SQLite to reject non-determinism in DDL.** The v1
DDL op must validate `CHECK` expressions against an explicit whitelist of
operators and deterministic functions, or ban `CHECK` outright in v1 and enforce
invariants in the builder.

### 18–19. Foreign keys

> "Foreign key constraints are disabled by default (for backwards compatibility),
> so must be enabled separately for each database connection."
> — <https://www.sqlite.org/foreignkeys.html>

> "This pragma is a no-op within a transaction ... As of SQLite version 3.6.19,
> the default setting for foreign key enforcement is OFF."
> — <https://www.sqlite.org/pragma.html#pragma_foreign_keys>

It is a **per-connection runtime setting that is not stored in the database file**,
and the default can also be flipped at compile time (`SQLITE_DEFAULT_FOREIGN_KEYS`).
Two clients with the same file, same schema, same ops and different pragma values
produce different content.

**And SQLite.jl does not set it.** Grepping
<https://github.com/JuliaDatabases/SQLite.jl/blob/master/src/SQLite.jl> finds
`PRAGMA temp_store=MEMORY` and `PRAGMA synchronous` inside the transaction helper
and nothing else; no `foreign_keys` anywhere. So the default (OFF) applies unless
the *application* sets it — meaning a user who calls `PRAGMA foreign_keys=ON` on
the read connection they were handed can change replay behaviour if that same
connection is used for apply.

**[empirical]** With the default settings, `DELETE FROM fk_parent WHERE id=1`
left the `ON DELETE CASCADE` child row in place (1 row remaining).

The interaction ordering is documented:

> "Whenever a row in the parent table of a foreign key constraint is deleted, or
> when the values stored in the parent key column or columns are modified, the
> logical sequence of events is: 1. Execute applicable BEFORE trigger programs,
> 2. Check local (non foreign key) constraints, 3. Update or delete the row in the
> parent table, 4. Perform any required foreign key actions, 5. Execute applicable
> AFTER trigger programs." — <https://www.sqlite.org/foreignkeys.html>

> "The PRAGMA recursive_triggers setting does not affect the operation of foreign
> key actions. It is not possible to disable recursive foreign key actions."
> — ibid.

Recommended design shape: **the replay connection owns its pragmas** (the library
opens it, sets them explicitly, and never inherits user settings), and cascade
effects are **materialized into the record** rather than delegated. Then FK
declarations remain in the schema as documentation/validation, replay does not
depend on whether they fire, and the record still says exactly which rows changed
— which the fingerprint and the point-in-time rebuild both need anyway.

### 20. Triggers

Nothing in <https://www.sqlite.org/lang_createtrigger.html> specifies the order in
which multiple triggers on the same table and event fire. **[empirical]** On
3.43.2 a trigger named `aaa` created *second* fired *before* a trigger named `zzz`
created first — consistent with name order, not creation order, but undocumented
either way.

What *is* documented is worse:

> "If a BEFORE UPDATE or BEFORE DELETE trigger modifies or deletes a row that was
> to have been updated or deleted, then the result of the subsequent update or
> delete operation is undefined. Furthermore, if a BEFORE trigger modifies or
> deletes a row, then it is undefined whether or not AFTER triggers that would
> have otherwise run on those rows will in fact run. The value of NEW.rowid is
> undefined in a BEFORE INSERT trigger in which the rowid is not explicitly set to
> an integer." — <https://www.sqlite.org/lang_createtrigger.html>

"Undefined" here is the SQLite authors' own word, and it is licence to differ
between versions. Combined with the fact that trigger bodies can contain
`random()` and date/time functions (nothing prohibits it), triggers are a
general-purpose non-determinism injector inside DDL. **Exclude from v1.**

### 21. `REPLACE` conflict resolution

**[empirical]** With `CREATE TABLE p(a UNIQUE, b UNIQUE, c)` holding `(1,1,'x')`
and `(2,2,'y')`, `INSERT OR REPLACE INTO p VALUES(1,2,'z')` leaves a *single* row
`(1,2,'z')` — it deleted two existing rows to satisfy two unique constraints. The
op record would say "insert one row"; the actual effect is "delete two, insert
one". Deterministic, but it hides row deletions from the record, which breaks any
record-level accounting (and would break a future differential/compaction format).
Materialize the deletes.

### 22–23. SQLite version skew, and what SQLite.jl actually bundles

The Julia package `SQLite.jl` is at **1.8.2**, and its native library comes from
`SQLite_jll`:

- `SQLite.jl` `Project.toml` (master): `SQLite_jll = "3.51"`
  — <https://github.com/JuliaDatabases/SQLite.jl/blob/master/Project.toml>
- General registry `S/SQLite/Compat.toml`, entry `["1.7.1 - 1"]`:
  `SQLite_jll = "3.51.0 - 3"`
  — <https://github.com/JuliaRegistries/General/blob/master/S/SQLite/Compat.toml>
- General registry `jll/S/SQLite_jll/Versions.toml` currently offers, among
  others, **`3.51.2+0`** and **`3.53.2+0`**
  — <https://github.com/JuliaRegistries/General/blob/master/jll/S/SQLite_jll/Versions.toml>

So the compat bound is a **range, not a pin**. Two clients that both did
`add SQLite@1.8.2` at different times, or that resolve against different Julia
versions or platform artifacts, can legitimately be running **3.51.2 and 3.53.2**
— which are exactly the two sides of the 15-vs-17-significant-digit float↔text
change (hazard 8). This is not hypothetical version skew; it is available today
from the same manifest constraint.

`S3SQLite/Project.toml` currently declares `SQLite = "1.8.2"`, which does nothing
to constrain the underlying library.

Design actions:

1. **Check at open.** Read `sqlite_version()` on every connection, compare against
   a declared supported range, and fail fast outside it (matches the project's
   fail-fast stance and the fingerprint's hard-error rule).
2. **Record the version in the record envelope** as advisory metadata, so a
   fingerprint mismatch can be attributed rather than merely detected.
3. **Set a floor of ≥ 3.37.0** if `STRICT` tables are adopted
   (<https://www.sqlite.org/stricttables.html>: introduced 3.37.0, 2021-11-27;
   older libraries need `PRAGMA writable_schema=ON` to touch such a file at all).
   Every `SQLite_jll` in the registry range already exceeds this.
4. **Keep the fingerprint free of anything version-varying**: no float→text, no
   `sqlite_schema.sql` text, no SQLite-side `ORDER BY`.

Other version-to-version entries checked and found *not* to matter for this design
(<https://www.sqlite.org/changes.html>): 3.41.1 preserved historical `CAST(... AS
INT)` column-type behaviour; 3.45.0 tightened `integrity_check`'s opinion about
TEXT-affinity columns holding numbers; 3.46.0 and 3.44.0 added strftime
conversions and month/year-shift `ceiling`/`floor` modifiers (date/time is
excluded anyway); 3.37.0 lets the planner drop `ORDER BY` on subqueries/views;
3.41.0 disabled the double-quoted-string misfeature *for CLI builds*; 3.47.2 fixed
a text→float conversion bug affecting values whose first 16 significant digits are
`1844674407370955` **on x64 and i386 only** (introduced in 3.47.0) — a concrete
instance of "float text conversion has had platform-dependent bugs within living
memory".

### 24–26. Connection- and build-level settings

Double-quoted string literals:

> "SQLite will also interpret a double-quotes string as string literal if it does
> not match any valid identifier." — <https://www.sqlite.org/quirks.html>

Whether it does so is controlled by `SQLITE_DBCONFIG_DQS_DDL` /
`SQLITE_DBCONFIG_DQS_DML` and by compile-time defaults, and 3.41.0 changed the CLI
default. A builder that renders SQL must therefore **never** emit a double-quoted
string literal and must always quote identifiers explicitly, so the setting cannot
change the meaning of what it emits.

Other per-connection settings with content-visible effects, none stored in the
file: `PRAGMA legacy_alter_table` (default OFF, "all references to the table
anywhere in the schema are converted to the new name"), `PRAGMA
recursive_triggers`, and the deprecated `PRAGMA case_sensitive_like`
(<https://www.sqlite.org/pragma.html>). The library must set every pragma it
depends on, on its own connection, every time — never assume a default.

That `ALTER TABLE RENAME` rewrites the stored schema text is the reason hazard 26
exists: the exact bytes of `sqlite_schema.sql` are a function of the SQLite
version's DDL renderer, so the fingerprint must be computed over normalized
structure (table names, column names, declared types, constraints, in a canonical
form produced by the library) or over the op chain itself.

### 27–28. Deterministic-but-surprising, no action

`SELECT 7/2` → `3`; `9223372036854775807+1` → `9.22337203685478e+18` (real)
**[empirical]**, matching the documented promotion-on-overflow behaviour. Bare
columns in aggregates are documented as undefined
(<https://www.sqlite.org/lang_select.html>) but are a read-side concern; no v1 op
evaluates a query inside SQLite. If a future version adds a predicate grammar,
both come back into scope.

---

## What this implies for the design (summary of actions)

1. **Ops carry explicit keys.** No implicit rowid, no `AUTOINCREMENT`. Prefer
   `WITHOUT ROWID` tables with explicit primary keys.
2. **Every INSERT names every column.** `DEFAULT` is never evaluated.
3. **DDL is validated, not passed through.** Reject: non-literal `DEFAULT`,
   `CURRENT_*` defaults, `AUTOINCREMENT`, triggers, user-defined collations, and
   `CHECK` expressions outside a deterministic whitelist (or `CHECK` entirely in
   v1).
4. **FK actions and `REPLACE` conflicts are materialized** into the record; replay
   does not depend on whether they fire.
5. **The replay connection owns its pragmas**, set explicitly every time:
   `foreign_keys`, `encoding` (UTF-8, at creation), `legacy_alter_table`,
   `recursive_triggers`. Never inherit.
6. **Canonical value encoding**: floats as IEEE-754 bits, text as bytes with no
   normalization and no embedded NUL, non-finite floats rejected. No value ever
   round-trips through SQLite's text conversion.
7. **The fingerprint defines its own total order** over tables, columns and rows,
   and hashes normalized schema structure rather than `sqlite_schema.sql`.
8. **Version check at open**, declared supported range, version recorded in the
   record envelope, floor ≥ 3.37.0 if `STRICT` is adopted.

---

## Not settled

1. **Whether `CHECK` really does reject non-deterministic functions in current
   SQLite.** <https://www.sqlite.org/deterministic.html> says it does; 3.43.2
   demonstrably does not (generated columns *are* enforced). I could not test
   3.51/3.53 locally. This does not change the verdict — the design must validate
   `CHECK` itself either way — but if the enforcement was tightened in a later
   release, that release becomes a candidate version floor. Resolve by running the
   probe under `SQLite_jll` 3.51.2 and 3.53.2.

2. **Whether `SQLite_jll`'s builds are configured identically across platforms.**
   Everything above assumes the same compile-time options on every client's
   artifact (`SQLITE_ENABLE_ICU`, `SQLITE_DEFAULT_FOREIGN_KEYS`, DQS defaults,
   `SQLITE_MIXED_ENDIAN_64BIT_FLOAT`, `SQLITE_ENABLE_UPDATE_DELETE_LIMIT`). I did
   not inspect the Yggdrasil build recipe. Resolve by reading
   `Yggdrasil/S/SQLite/build_tarballs.jl` and by having the client log
   `PRAGMA compile_options` and compare it to a recorded baseline — that comparison
   is cheap and probably belongs in the version check of action 8 regardless.

3. **Exactly which UTF-8 vs UTF-16 orderings diverge.** The divergence follows from
   "`memcmp` regardless of text encoding", but I did not enumerate the ranges or
   test it (it needs two files with different `PRAGMA encoding`). Immaterial once
   UTF-8 is pinned; it matters only if the design ever has to *open a file it did
   not create*.

4. **The cost of the fingerprint.** Every action above assumes the fingerprint
   reads full logical content in a library-defined order. Whether that is
   affordable at the target data sizes is issue #7's problem, not this one, but
   the ordering requirement (hazard 13/14) constrains how it can be made cheap:
   incremental fingerprints would need a per-row hash that is order-independent to
   combine, which is a different construction from "sort and hash".

5. **`sqlite_sequence` and other internal tables in the fingerprint scope.** With
   `AUTOINCREMENT` excluded, `sqlite_sequence` should never exist — but the
   fingerprint definition still has to say explicitly which `sqlite_*` tables are
   in scope, and what happens if an unexpected one appears. Feeds the
   reserved-tables design.
