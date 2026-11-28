# Apply never computes and never sorts: each op is the model primitive it reduces to,
# and every check the write builder runs is run there again (ADR-0025).
"""
    apply!(content, op::Op, slot)
    apply!(content, record::Record)

Apply one op, or every op of a record in order, to a `Model.Content`.

Each op that changes a row's cells stamps the row with the slot: `Insert` and `Update`
the rows they name, `AddColumn` and `DropColumn` every row of the table. The record
form takes the slot from the record.

The op form throws the internal `ModelError` when the op breaks a rule of the model or
contradicts the content. The record form throws `MalformedRecordError` for the first
such op and applies nothing after it: the content is then partly applied, and the
caller discards it.

Examples: test/test_ops_apply_examples.jl
"""
function apply!(c::Content, op::CreateTable, slot)
    Model.create_table!(c, op.table, op.shape)
    return nothing
end

function apply!(c::Content, op::AddColumn, slot)
    return Model.add_column!(Model.table(c, op.table), op.column, op.fill, slot)
end

function apply!(c::Content, op::DropColumn, slot)
    return Model.drop_column!(Model.table(c, op.table), op.column, slot)
end

apply!(c::Content, op::DropTable, slot) = Model.drop_table!(c, op.table)

function apply!(c::Content, op::Insert, slot)
    return Model.insert_rows!(Model.table(c, op.table), op.rows, slot)
end

function apply!(c::Content, op::Update, slot)
    return Model.update_rows!(Model.table(c, op.table), op.columns, op.rows, slot)
end

apply!(c::Content, op::Delete, slot) = Model.delete_rows!(Model.table(c, op.table), op.keys)

function apply!(c::Content, r::Record)
    foreach(i -> apply_op_at!(c, r, i), eachindex(r.ops))
    return nothing
end

function apply_op_at!(c::Content, r::Record, i)
    op = r.ops[i]
    try
        apply!(c, op, r.slot)
    catch e
        e isa ModelError || rethrow()
        chain_id = ChainTables.chain_id_string(r.chain_id)
        detail = "op $i ($(op_name(op)) on $(repr(op.table))): $(e.detail)"
        throw(MalformedRecordError(; chain_id, r.slot, op = i, detail))
    end
    return nothing
end
