"""
PROTOTYPE — shape B: do-blocks.

Nothing is pushed by hand: each block owns what it built and hands it up when it
closes. The block also carries the read handle, so "query local state, then write
down what you found" is one continuous piece of code rather than two.
"""
module ShapeB

using ..Ops
using SQLite

"A transaction under construction, plus the local state it is being built against."
struct Ctx
    tx::Transaction
    db::Union{SQLite.DB,Nothing}
end

function record(f, db = nothing)
    rec = Record()
    f((rec, db))
    return rec
end

function transaction!(f, (rec, db), label)
    ctx = Ctx(Transaction(label), db)
    f(ctx)
    isempty(ctx.tx.ops) && error("transaction $(repr(label)) built no ops")
    push!(rec.transactions, ctx.tx)
    return ctx.tx
end

mutable struct TableDraft
    table::Any
    columns::Vector{Column}
    primary_key::Vector{Symbol}
end

function create_table!(f, ctx::Ctx, table)
    t = TableDraft(table, Column[], Symbol[])
    f(t)
    push!(ctx.tx.ops, CreateTable(t.table, t.columns; primary_key = t.primary_key))
    return nothing
end

column!(t::TableDraft, name, type; kw...) = push!(t.columns, Column(name, type; kw...))
primary_key!(t::TableDraft, names...) = append!(t.primary_key, [canonical_ident(n) for n in names])

add_column!(ctx::Ctx, table, name, type; kw...) =
    (push!(ctx.tx.ops, AddColumn(table, Column(name, type; kw...))); nothing)
insert!(ctx::Ctx, table, rows) = (push!(ctx.tx.ops, Insert(table, rows)); nothing)
delete!(ctx::Ctx, table, keys) = (push!(ctx.tx.ops, Delete(table, keys)); nothing)
update!(ctx::Ctx, table, rows; by) = (push!(ctx.tx.ops, Update(table, rows; by)); nothing)

"Read local state from inside the block. Reads are ordinary SQL; only writes are interposed."
select(ctx::Ctx, sql, params = []) = [NamedTuple(r) for r in DBInterface.execute(ctx.db, sql, params)]

record_one() = record() do r
    transaction!(r, "create the sample schema") do tx
        create_table!(tx, :sample) do t
            column!(t, :id, :INTEGER; notnull = true)
            column!(t, :label, :TEXT; notnull = true)
            column!(t, :collected_on, :TEXT)
            column!(t, :note, :TEXT)
            primary_key!(t, :id)
        end
        create_table!(tx, :measurement) do t
            column!(t, :sample_id, :INTEGER; notnull = true)
            column!(t, :metric, :TEXT; notnull = true)
            column!(t, :value, :REAL)
            column!(t, :raw, :BLOB)
            primary_key!(t, :sample_id, :metric)
        end
    end

    transaction!(r, "load the january batch") do tx
        insert!(tx, :sample, [
            (id = 1, label = "AX-1", collected_on = "2026-01-04", note = "duplicate run"),
            (id = 2, label = "AX-2", collected_on = "2026-01-04", note = nothing),
            (id = 3, label = "BX-7", collected_on = "2026-01-11", note = nothing),
        ])
        insert!(tx, :measurement, [
            (sample_id = 1, metric = "ph", value = 7.21, raw = nothing),
            (sample_id = 1, metric = "od600", value = 145.0, raw = UInt8[0xde, 0xad, 0xbe, 0xef]),
            (sample_id = 2, metric = "od600", value = 220.5, raw = nothing),
            (sample_id = 2, metric = "ph", value = 6.98, raw = nothing),
            (sample_id = 3, metric = "ph", value = nothing, raw = nothing),
        ])
    end
end

record_two(db) = record(db) do r
    transaction!(r, "add the provenance column") do tx
        add_column!(tx, :sample, :instrument, :TEXT)
    end

    transaction!(r, "retire the out-of-range readings") do tx
        doomed = select(tx, "SELECT sample_id, metric FROM measurement WHERE value > 100 ORDER BY sample_id, metric")
        delete!(tx, :measurement, doomed)
        update!(tx, :sample,
            [(id = i, note = "reading retired 2026-01-20") for i in unique(d.sample_id for d in doomed)];
            by = :id)
    end
end

end # module ShapeB
