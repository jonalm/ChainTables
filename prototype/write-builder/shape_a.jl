"""
PROTOTYPE — shape A: plain functions over NamedTuples.

No macros, no scoping tricks. You build a `Transaction`, push ops into it, push
it into a `Record`. Everything is a value you can hold, inspect, pass around and
build in a loop.
"""
module ShapeA

using ..Ops
using SQLite

create_table!(tx, table, columns; primary_key) =
    (push!(tx.ops, CreateTable(table, columns; primary_key)); tx)
add_column!(tx, table, column) = (push!(tx.ops, AddColumn(table, column)); tx)
insert!(tx, table, rows) = (push!(tx.ops, Insert(table, rows)); tx)
delete!(tx, table, keys) = (push!(tx.ops, Delete(table, keys)); tx)
update!(tx, table, rows; by) = (push!(tx.ops, Update(table, rows; by)); tx)

"Record 1: bring the schema into existence and load the January batch."
function record_one()
    rec = Record()

    tx = Transaction("create the sample schema")
    create_table!(tx, :sample, [
            (name = :id, type = :INTEGER, notnull = true),
            (name = :label, type = :TEXT, notnull = true),
            (name = :collected_on, type = :TEXT),
            (name = :note, type = :TEXT),
        ]; primary_key = :id)
    create_table!(tx, :measurement, [
            (name = :sample_id, type = :INTEGER, notnull = true),
            (name = :metric, type = :TEXT, notnull = true),
            (name = :value, type = :REAL),
            (name = :raw, type = :BLOB),
        ]; primary_key = [:sample_id, :metric])
    push!(rec.transactions, tx)

    tx = Transaction("load the january batch")
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
    push!(rec.transactions, tx)

    return rec
end

"""
Record 2: the caller queries local state first, then writes the row set it found
into the record. The predicate `value > 100` never reaches the record — only the
rows it selected here, on this client, at this head.
"""
function record_two(db)
    rec = Record()

    tx = Transaction("add the provenance column")
    add_column!(tx, :sample, (name = :instrument, type = :TEXT))
    push!(rec.transactions, tx)

    doomed = [(sample_id = r.sample_id, metric = r.metric) for r in DBInterface.execute(db,
        "SELECT sample_id, metric FROM measurement WHERE value > 100 ORDER BY sample_id, metric")]
    touched = unique(r.sample_id for r in doomed)

    tx = Transaction("retire the out-of-range readings")
    delete!(tx, :measurement, doomed)
    update!(tx, :sample, [(id = i, note = "reading retired 2026-01-20") for i in touched]; by = :id)
    push!(rec.transactions, tx)

    return rec
end

end # module ShapeA
