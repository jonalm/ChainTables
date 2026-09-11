"""
PROTOTYPE — throwaway. Issue #7: what should the write-builder API feel like?

This file is the op model and the determinism guard: the part that would be
lifted into the real package if the prototype survives contact. The three
`shape_*.jl` front-ends are the disposable part — they are three different
spellings of the same scenario, and all three must produce identical op data.

No S3, no hashing, no persistence. The "local state" is an in-memory SQLite
database, because the one thing a builder must do that cannot be faked is
fail against real local state.
"""
module Ops

using SQLite

export Column, Op, CreateTable, AddColumn, Insert, Delete, Update,
       Transaction, Record, DeterminismError,
       canonical_value, canonical_ident, to_data, format_data, apply!, sql, opname

# --------------------------------------------------------------------- errors

struct DeterminismError <: Exception
    msg::String
end
Base.showerror(io::IO, e::DeterminismError) = print(io, "DeterminismError: ", e.msg)

struct RecordRejected <: Exception
    msg::String
end
Base.showerror(io::IO, e::RecordRejected) = print(io, "RecordRejected: ", e.msg)

# --------------------------------------------------------------------- values

const SQLITE_TYPES = (:INTEGER, :REAL, :TEXT, :BLOB)

"""
    canonical_value(x)

The determinism guard at value level: map a Julia value onto one of SQLite's
four storage classes, or NULL, or refuse. Whatever survives this is a literal
in the record, so replay is trivially deterministic — every client writes back
exactly these bytes.

Note what this *cannot* catch: `rand()` returns a perfectly canonical Float64.
See `shape_c.jl`.
"""
canonical_value(::Nothing) = nothing
canonical_value(::Missing) = nothing

canonical_value(x::Bool) = throw(DeterminismError(
    "Bool has no SQLite storage class; write 0 or 1 so the record says which (got $x)"))

function canonical_value(x::Integer)
    typemin(Int64) <= x <= typemax(Int64) ||
        throw(DeterminismError("$x does not fit in INTEGER (64-bit signed)"))
    return Int64(x)
end

function canonical_value(x::AbstractFloat)
    isfinite(x) || throw(DeterminismError(
        "REAL must be finite — NaN and Inf have no canonical encoding and no stable text form (got $x)"))
    return Float64(x)
end

function canonical_value(x::AbstractString)
    s = String(x)
    isvalid(s) || throw(DeterminismError("TEXT must be valid UTF-8"))
    occursin('\0', s) && throw(DeterminismError(
        "TEXT may not contain U+0000 — SQLite truncates the value there and the record would no longer describe the row"))
    return s
end

canonical_value(x::Vector{UInt8}) = x
canonical_value(x::Base.CodeUnits) = Vector{UInt8}(x)

canonical_value(x) = throw(DeterminismError(
    "$(typeof(x)) has no canonical SQLite encoding. Convert it yourself, so the " *
    "record records the decision (a DateTime → an Int64 epoch or an ISO-8601 String, " *
    "a Symbol → a String, a Rational → whichever of the two you meant)"))

# ---------------------------------------------------------------- identifiers

const IDENT = r"^[A-Za-z_][A-Za-z0-9_]*$"

# Not exhaustive — enough to show the shape of the rule.
const RESERVED = Set(Symbol.([
    "select", "from", "where", "order", "group", "table", "index", "default",
    "primary", "key", "null", "not", "and", "or", "insert", "update", "delete",
    "values", "into", "set", "join", "on", "as", "by", "limit", "union",
]))

"""
    canonical_ident(name)

Identifiers are never quoted on the way out, so they must be safe bare. This is
not fussiness: `SQLITE_DQS=3` is compiled in and invisible (#18), so a
double-quoted identifier that fails to resolve silently degrades to a string
literal. The builder's answer is to make the situation unreachable.
"""
function canonical_ident(name)
    s = String(name)
    occursin(IDENT, s) || throw(DeterminismError(
        "identifier $(repr(s)) must match [A-Za-z_][A-Za-z0-9_]* — the builder never " *
        "quotes identifiers, because with SQLITE_DQS=3 compiled in (#18) a quoted " *
        "identifier that does not resolve becomes a string literal instead of an error"))
    Symbol(lowercase(s)) in RESERVED && throw(DeterminismError(
        "identifier $(repr(s)) is an SQL keyword; quoting it is exactly what this " *
        "builder refuses to do"))
    return Symbol(s)
end

# -------------------------------------------------------------------- columns

struct Column
    name::Symbol
    type::Symbol
    notnull::Bool
    default::Union{Int64,Float64,String,Vector{UInt8},Nothing}
end

function Column(name, type; notnull = false, default = nothing)
    t = Symbol(uppercase(String(type)))
    t in SQLITE_TYPES || throw(DeterminismError(
        "column type must be one of $(join(SQLITE_TYPES, ", ")) — ANY is excluded " *
        "because it puts the storage class back in the caller's hands (got $t)"))
    return Column(canonical_ident(name), t, notnull, canonical_value(default))
end

_column(c::Column) = c
_column(c::NamedTuple) = Column(
    c.name, c.type;
    notnull = get(c, :notnull, false), default = get(c, :default, nothing),
)

# ------------------------------------------------------------------------ ops

abstract type Op end

struct CreateTable <: Op
    table::Symbol
    columns::Vector{Column}
    primary_key::Vector{Symbol}
end

function CreateTable(table, columns; primary_key)
    tbl = canonical_ident(table)
    cols = Column[_column(c) for c in columns]
    names = [c.name for c in cols]
    allunique(names) || throw(DeterminismError("duplicate column names in table $tbl"))
    pk = Symbol[canonical_ident(k) for k in (primary_key isa Symbol ? (primary_key,) : primary_key)]
    isempty(pk) && throw(DeterminismError(
        "table $tbl needs an explicit PRIMARY KEY. The implicit rowid is not replayable " *
        "(#3: max+1 goes random at 2^63-1 and is reused after DELETE), and a materialized " *
        "UPDATE or DELETE has nothing to name a row by without one"))
    for k in pk
        k in names || throw(DeterminismError("primary key column $k is not declared in table $tbl"))
    end
    for k in pk
        cols[findfirst(==(k), names)].notnull ||
            throw(DeterminismError("primary key column $k must be NOT NULL — WITHOUT ROWID tables reject NULL keys"))
    end
    return CreateTable(tbl, cols, pk)
end

struct AddColumn <: Op
    table::Symbol
    column::Column
end

function AddColumn(table, column)
    c = _column(column)
    c.notnull && c.default === nothing && throw(DeterminismError(
        "ADD COLUMN $(c.name) NOT NULL needs a literal DEFAULT — existing rows have to " *
        "get a value, and it has to be in the record rather than computed at replay time"))
    return AddColumn(canonical_ident(table), c)
end

struct Insert <: Op
    table::Symbol
    columns::Vector{Symbol}
    rows::Vector{Vector{Any}}
end

function Insert(table, rows)
    rs = rows isa NamedTuple ? [rows] : collect(rows)
    isempty(rs) && throw(DeterminismError(
        "INSERT with no rows — an empty op is not a change; say nothing instead"))
    cols = Symbol[canonical_ident(k) for k in keys(first(rs))]
    data = Vector{Any}[]
    for r in rs
        Symbol[canonical_ident(k) for k in keys(r)] == cols || throw(DeterminismError(
            "every row of one INSERT must name the same columns in the same order — " *
            "column order is part of the canonical bytes (got $(keys(r)) after $(Tuple(cols)))"))
        push!(data, Any[canonical_value(v) for v in values(r)])
    end
    return Insert(canonical_ident(table), cols, data)
end

struct Delete <: Op
    table::Symbol
    key_columns::Vector{Symbol}
    keys::Vector{Vector{Any}}
end

function Delete(table, keys)
    ks = keys isa NamedTuple ? [keys] : collect(keys)
    isempty(ks) && throw(DeterminismError("DELETE with no rows — say nothing instead"))
    kcols = Symbol[canonical_ident(k) for k in Base.keys(first(ks))]
    data = Vector{Any}[]
    for r in ks
        Symbol[canonical_ident(k) for k in Base.keys(r)] == kcols || throw(DeterminismError(
            "every row of one DELETE must name the same key columns in the same order"))
        push!(data, Any[canonical_value(v) for v in values(r)])
    end
    return Delete(canonical_ident(table), kcols, data)
end

struct Update <: Op
    table::Symbol
    key_columns::Vector{Symbol}
    set_columns::Vector{Symbol}
    rows::Vector{Vector{Any}}   # key values, then set values
end

function Update(table, rows; by)
    rs = rows isa NamedTuple ? [rows] : collect(rows)
    isempty(rs) && throw(DeterminismError("UPDATE with no rows — say nothing instead"))
    kcols = Symbol[canonical_ident(k) for k in (by isa Symbol ? (by,) : by)]
    allcols = Symbol[canonical_ident(k) for k in keys(first(rs))]
    for k in kcols
        k in allcols || throw(DeterminismError("key column $k is not present in the update rows"))
    end
    scols = Symbol[c for c in allcols if !(c in kcols)]
    isempty(scols) && throw(DeterminismError(
        "UPDATE names only key columns — there is nothing to set"))
    data = Vector{Any}[]
    for r in rs
        Symbol[canonical_ident(k) for k in keys(r)] == allcols || throw(DeterminismError(
            "every row of one UPDATE must name the same columns in the same order"))
        d = Dict(canonical_ident(k) => v for (k, v) in pairs(r))
        push!(data, Any[canonical_value(d[c]) for c in vcat(kcols, scols)])
    end
    return Update(canonical_ident(table), kcols, scols, data)
end

opname(::CreateTable) = "create_table"
opname(::AddColumn) = "add_column"
opname(::Insert) = "insert"
opname(::Delete) = "delete"
opname(::Update) = "update"

# -------------------------------------------------------- transactions/record

struct Transaction
    label::String
    ops::Vector{Op}
end
Transaction(label = "") = Transaction(String(label), Op[])

struct Record
    transactions::Vector{Transaction}
end
Record() = Record(Transaction[])

# --------------------------------------------------------------- ops as data

"""
    to_data(x)

The record as it would go to the canonical encoder (#4: deterministic CBOR) —
plain maps, arrays and the five value kinds, nothing Julia-specific. Key order
is fixed here, not left to a Dict.
"""
to_data(v::Nothing) = nothing
to_data(v::Int64) = v
to_data(v::Float64) = v
to_data(v::String) = v
to_data(v::Vector{UInt8}) = v

to_data(c::Column) = [
    "name" => String(c.name),
    "type" => String(c.type),
    "notnull" => c.notnull,
    "default" => to_data(c.default),
]

to_data(op::CreateTable) = [
    "op" => "create_table",
    "table" => String(op.table),
    "columns" => [to_data(c) for c in op.columns],
    "primary_key" => String.(op.primary_key),
]

to_data(op::AddColumn) = [
    "op" => "add_column",
    "table" => String(op.table),
    "column" => to_data(op.column),
]

to_data(op::Insert) = [
    "op" => "insert",
    "table" => String(op.table),
    "columns" => String.(op.columns),
    "rows" => [[to_data(v) for v in r] for r in op.rows],
]

to_data(op::Delete) = [
    "op" => "delete",
    "table" => String(op.table),
    "key_columns" => String.(op.key_columns),
    "keys" => [[to_data(v) for v in r] for r in op.keys],
]

to_data(op::Update) = [
    "op" => "update",
    "table" => String(op.table),
    "key_columns" => String.(op.key_columns),
    "set_columns" => String.(op.set_columns),
    "rows" => [[to_data(v) for v in r] for r in op.rows],
]

to_data(tx::Transaction) = ["label" => tx.label, "ops" => [to_data(o) for o in tx.ops]]

to_data(rec::Record) = ["transactions" => [to_data(t) for t in rec.transactions]]

_short(v::Nothing) = "null"
_short(v::Int64) = "$v"
_short(v::Float64) = "$v"
_short(v::Bool) = "$v"
_short(v::String) = repr(v)
_short(v::Vector{UInt8}) = "blob[$(length(v))] " * bytes2hex(v[1:min(end, 8)]) * (length(v) > 8 ? "…" : "")
_short(v::Vector) = "[" * join(_short.(v), ", ") * "]"

function format_data(io::IO, x, indent = 0)
    pad = " "^indent
    if x isa Vector{<:Pair}
        for (k, v) in x
            if v isa Vector{<:Pair} || (v isa Vector && any(e -> e isa Vector{<:Pair}, v))
                println(io, pad, k, ":")
                format_data(io, v, indent + 2)
            elseif v isa Vector && !isempty(v) && all(e -> e isa Vector, v) && !(v isa Vector{UInt8})
                println(io, pad, k, ":")
                for e in v
                    println(io, pad, "  - ", _short(e))
                end
            else
                println(io, pad, k, ": ", _short(v))
            end
        end
    elseif x isa Vector
        for (i, e) in enumerate(x)
            println(io, pad, "- #", i)
            format_data(io, e, indent + 2)
        end
    else
        println(io, pad, _short(x))
    end
    return io
end

format_data(x) = String(take!(format_data(IOBuffer(), x)))

# ------------------------------------------------------------- render + apply

_literal(v::Int64) = string(v)
_literal(v::Float64) = repr(v)
_literal(v::String) = "'" * replace(v, "'" => "''") * "'"   # never double quotes: DQS=3
_literal(v::Vector{UInt8}) = "X'" * bytes2hex(v) * "'"

function sql(op::CreateTable)
    defs = String[]
    for c in op.columns
        s = "$(c.name) $(c.type)"
        c.notnull && (s *= " NOT NULL")
        c.default === nothing || (s *= " DEFAULT " * _literal(c.default))
        push!(defs, s)
    end
    push!(defs, "PRIMARY KEY (" * join(op.primary_key, ", ") * ")")
    return "CREATE TABLE $(op.table) (" * join(defs, ", ") * ") STRICT, WITHOUT ROWID"
end

function sql(op::AddColumn)
    c = op.column
    s = "ALTER TABLE $(op.table) ADD COLUMN $(c.name) $(c.type)"
    c.notnull && (s *= " NOT NULL")
    c.default === nothing || (s *= " DEFAULT " * _literal(c.default))
    return s
end

sql(op::Insert) = "INSERT INTO $(op.table) (" * join(op.columns, ", ") * ") VALUES (" *
                  join(fill("?", length(op.columns)), ", ") * ")"

sql(op::Delete) = "DELETE FROM $(op.table) WHERE " *
                  join(["$c = ?" for c in op.key_columns], " AND ")

sql(op::Update) = "UPDATE $(op.table) SET " *
                  join(["$c = ?" for c in op.set_columns], ", ") * " WHERE " *
                  join(["$c = ?" for c in op.key_columns], " AND ")

_changes(db) = first(DBInterface.execute(db, "SELECT changes() AS n"))[:n]

apply!(db::SQLite.DB, op::CreateTable) = (DBInterface.execute(db, sql(op)); nothing)
apply!(db::SQLite.DB, op::AddColumn) = (DBInterface.execute(db, sql(op)); nothing)

function apply!(db::SQLite.DB, op::Insert)
    stmt = DBInterface.prepare(db, sql(op))
    for r in op.rows
        DBInterface.execute(stmt, r)
    end
    return nothing
end

function apply!(db::SQLite.DB, op::Delete)
    stmt = DBInterface.prepare(db, sql(op))
    for (i, r) in enumerate(op.keys)
        DBInterface.execute(stmt, r)
        n = _changes(db)
        n == 1 || throw(RecordRejected(
            "DELETE row $i matched $n rows, expected exactly 1 — the caller's materialized " *
            "row set disagrees with local state, so the record would not replay the same way here"))
    end
    return nothing
end

function apply!(db::SQLite.DB, op::Update)
    stmt = DBInterface.prepare(db, sql(op))
    nk = length(op.key_columns)
    for (i, r) in enumerate(op.rows)
        DBInterface.execute(stmt, vcat(r[nk+1:end], r[1:nk]))
        n = _changes(db)
        n == 1 || throw(RecordRejected(
            "UPDATE row $i matched $n rows, expected exactly 1 — the caller's materialized " *
            "row set disagrees with local state"))
    end
    return nothing
end

"""
    apply!(db, rec)

Run the whole record against local state, atomically. This is step 2 of the
commit sketch: a record that cannot be applied locally is never uploaded.
"""
function apply!(db::SQLite.DB, rec::Record)
    DBInterface.execute(db, "BEGIN")
    try
        for (ti, tx) in enumerate(rec.transactions)
            for (oi, op) in enumerate(tx.ops)
                try
                    apply!(db, op)
                catch err
                    throw(RecordRejected(
                        "transaction $ti ($(repr(tx.label))), op $oi ($(opname(op))): " *
                        sprint(showerror, err)))
                end
            end
        end
    catch
        DBInterface.execute(db, "ROLLBACK")
        rethrow()
    end
    DBInterface.execute(db, "COMMIT")
    return rec
end

end # module Ops
