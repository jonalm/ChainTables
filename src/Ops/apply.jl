# Apply never computes and never sorts: each op delegates to the model primitive it
# reduces to, which re-runs every check the write builder ran (ADR-0025).

"""
    sort_rows(rows, key) -> Vector

Return `rows` sorted by the typed key order, `isless` on `key(row)`: the builder's
canonical form, which apply checks but never produces. A duplicate key is left for the
checks to refuse.
"""
sort_rows(rows, key) = sort(collect(rows); by = key)

"""
    apply!(content, op::Op, slot) -> nothing
    apply!(content, record::Record) -> nothing

Apply one op, or every op of a record in order, to `content`. An op that changes a row's
cells stamps the row with `slot`, or with the record's slot. The op form throws
`ModelError`; the record form throws `MalformedRecordError` naming the slot and the op,
and leaves `content` partly applied, for the caller to discard.
"""
function apply!(c::Content, op::CreateTable, slot)
    add_table!(c, op.table, op.shape)
    return nothing
end

function apply!(c::Content, op::AddColumn, slot)
    append_column!(content_table(c, op.table), op.column, op.fill, slot)
    return nothing
end

function apply!(c::Content, op::DropColumn, slot)
    remove_column!(content_table(c, op.table), op.column, slot)
    return nothing
end

function apply!(c::Content, op::DropTable, slot)
    remove_table!(c, op.table)
    return nothing
end

function apply!(c::Content, op::Insert, slot)
    insert_table_rows!(content_table(c, op.table), op.rows, slot)
    return nothing
end

function apply!(c::Content, op::Update, slot)
    update_table_rows!(content_table(c, op.table), op.columns, op.rows, slot)
    return nothing
end

function apply!(c::Content, op::Delete, slot)
    delete_table_rows!(content_table(c, op.table), op.keys)
    return nothing
end

function apply!(c::Content, r::Record)
    foreach(((i, op),) -> apply_record_op!(c, r, i, op), enumerate(r.ops))
    return nothing
end

# Translation outside a Boundary function: the model's rule becomes the malformed record
# that broke it, with the slot and op index as Evidence.
function apply_record_op!(c::Content, r::Record, i::Int, op::Op)
    try
        apply!(c, op, r.slot)
    catch e
        e isa ModelError || rethrow()
        chain_id = ChainTables.chain_id_string(r.chain_id)
        detail = "$(op_name(op)) on $(repr(op.table)): $(e.detail)"
        throw(MalformedRecordError(; chain_id, slot = r.slot, op = i, detail))
    end
    return nothing
end
