# Upstream: SQLite.jl returns some BLOBs as decoded Julia objects

**Status**: not filed. Written to be filed against
[JuliaDatabases/SQLite.jl](https://github.com/JuliaDatabases/SQLite.jl) if and
when we choose to; S3SQLite depends on no fix (see the last section).

**Measured on**: SQLite.jl 1.8.2, SQLite\_jll 3.53.2, Julia 1.12.7, macOS
aarch64. Line numbers are SQLite.jl 1.8.2.

## Summary

A BLOB written as bytes does not always come back as those bytes. SQLite.jl
sniffs the first 18 bytes of every BLOB it reads and, on a match, returns
`Serialization.deserialize` of the value instead — so the caller gets a decoded
Julia object, different bytes, or a raised `SQLite.SerializeError`, from data it
stored itself. There is no opt-out.

## Mechanism

SQLite.jl serializes Julia values it has no `bind!` method for:

```julia
# SQLite.jl:429
function sqlserialize(x)
    buffer = IOBuffer()
    s = Serialized(x)                       # internal wrapper struct
    Serialization.serialize(buffer, s)
    return take!(buffer)
end
# SQLite.jl:439
bind!(stmt::Stmt, i::Integer, val::Any) = bind!(stmt, i, sqlserialize(val))
```

To undo that on read it compares against a marker derived from one such
serialization:

```julia
# SQLite.jl:447
const SERIALIZATION = sqlserialize(0)[1:18]
# SQLite.jl:449
function sqldeserialize(r)
    sizeof(r) < sizeof(SERIALIZATION) && return r
    ret = ccall(:memcmp, Int32, (Ptr{UInt8}, Ptr{UInt8}, UInt), SERIALIZATION, r, ...)
    if ret == 0
        try
            v = Serialization.deserialize(IOBuffer(r))
            return v.object
        catch e
            throw(SerializeError("Error deserializing non-primitive value out of database; ..."))
        end
    end
    ...
end
```

Every BLOB read goes through it. `juliatype(SQLITE_BLOB)` is `Any`
(`SQLite.jl:523`), so the generic `sqlitevalue` fallback (`SQLite.jl:586`)
runs, and that fallback ends in `sqldeserialize(buf)`. The content sniff is
applied to data, not to a flag: nothing records that a particular BLOB was
written by `sqlserialize`.

On this Julia the marker is

```
37 4a 4c 1e 04 00 00 00 34 10 01 0a 53 65 72 69 61 6c
```

— `7JL`, `Serialization.ser_version` (30), Julia version bytes, then the head of
the wrapper type's name.

## Reproduction

```julia
using SQLite
const DBI = SQLite.DBInterface

db = SQLite.DB()
DBI.execute(db, "CREATE TABLE t(k INTEGER PRIMARY KEY NOT NULL, b BLOB NOT NULL) STRICT, WITHOUT ROWID")

a = SQLite.sqlserialize([1, 2, 3])                    # 77 bytes
b = SQLite.sqlserialize(UInt8[9, 9])                  # 53 bytes
c = vcat(SQLite.SERIALIZATION, fill(0xAB, 16))        # 34 bytes

for (k, v) in enumerate((a, b, c))
    DBI.execute(db, "INSERT INTO t VALUES(?,?)", (k, v))   # bound as Vector{UInt8}: stored verbatim
end

[r[:b] for r in DBI.execute(db, "SELECT b FROM t WHERE k = 1")]   # Vector{Int64}[[1, 2, 3]]
[r[:b] for r in DBI.execute(db, "SELECT b FROM t WHERE k = 2")]   # Vector{UInt8}[[0x09, 0x09]]  ← 53 bytes in, 2 out
[r[:b] for r in DBI.execute(db, "SELECT b FROM t WHERE k = 3")]   # ERROR: SQLite.SerializeError
```

The three outcomes:

1. **Wrong type.** Bytes return as a `Vector{Int64}`.
2. **Wrong bytes, right type.** `b` returns as a two-element `Vector{UInt8}`.
   The column is still declared `BLOB` and the value is still a
   `Vector{UInt8}`, so no type check anywhere can tell that 53 bytes became 2.
3. **Unreadable.** `c` is a BLOB the database holds and this API cannot return
   at all — and the error text attributes it to a Julia version mismatch, which
   is not what happened.

Neither knob avoids it: `strict = true` and `Tables.columntable` take the same
path, since the declared type `BLOB` maps to `Any` either way.

## Scope

- An ordinary `Serialization.serialize(io, x)` payload does **not** match, because
  the marker covers SQLite.jl's own `Serialized` wrapper. The trigger set is
  bytes SQLite.jl itself produced, plus anything crafted.
- Narrow is not empty. Copying rows between databases, storing a payload that
  was serialized on purpose, or round-tripping a BLOB column through SQLite.jl
  all reproduce it deterministically, with no adversary and no coincidence.
- A blind collision needs 18 specific leading bytes, so it is not the concern.
- **The marker embeds `ser_version` and Julia version bytes**, so *which* BLOBs
  are affected depends on the Julia version doing the read. The same file, read
  by the same SQLite.jl under a different Julia, can return bytes where it
  previously returned an object. For deliberately serialized objects that is a
  documented failure; here it silently changes how plain data reads.

## What a fix would look like

The serializing fallback is a feature; the ask is an opt-out, not its removal.

- A keyword on `DBInterface.execute` / `Query` — `deserialize = false` — that
  returns BLOBs as `Vector{UInt8}` unconditionally; or
- `strict = true` mapping a declared `BLOB` column to `Vector{UInt8}` rather
  than `Any`, which is what a caller asking for strict declared types is
  already asking for; or
- a documented, public raw-value read path, so reaching for
  `sqlite3_column_blob` is not reaching into internals.

## A second, smaller report

`bind!` has methods for `Int32`, `Int64` and `Bool`, and none for `Integer`
(`SQLite.jl:351-401`). So an integer of any other width falls into the
serializing fallback and is silently stored as a BLOB:

```julia
DBI.execute(db2, "INSERT INTO w VALUES(?,?)", (1, Int16(7)))
# typeof(v) == "blob"
```

Measured for `Int16`, `UInt8`, `Int128` and `Symbol`. An `Integer` method
converting to `Int64` with a range check would be a better default than storing
an integer as an object; raising would be better still.

## Why S3SQLite does not wait on any of this

[ADR-0021](../adr/0021-values-cross-the-sqlite-boundary-through-the-c-api.md)
puts every internal read and bind through `sqlite3_column_*` /
`sqlite3_bind_*`, and it would do so even if all of the above were fixed:

- [ADR-0017](../adr/0017-no-number-is-ever-rendered-to-text.md) forbids
  rendering a number to text in the replay path and the fingerprint pass. Only
  dispatching on `sqlite3_column_type` ourselves guarantees that; SQLite.jl
  materializes a `String` with `sqlite3_column_text`, which is the forbidden
  path.
- The bind hazards are ours to close regardless, and `STRICT` does not close
  them: a bound `Float64` into a `TEXT` column is accepted and rendered by
  SQLite itself.
- A fix would ship in a version our compat range does not require. Benefiting
  from it means raising the floor, which is the dependency we are declining.
- The C API is also ~10× faster per row, so there is no configuration in which
  we would prefer the row API.

`test/sqlite_jl_marshalling.jl` pins every measurement above. If upstream fixes
this, those tests fail, and that is the intended signal — the tests describe the
dependency's behaviour, not a requirement on it.
