using ChainTables: Model

# Read access to a model table, for assertions: `src/` reads a table through a
# `TableView` and has no reader of one row.
row_at(t::Model.Table, i) = Any[column[i] for column in t.columns]
row_of(t::Model.Table, key) = row_at(t, t.index[key])
rows_in_key_order(t::Model.Table) = [row_at(t, i) for i in sortperm(Model.key_vector(t))]

function table_bytes(t::Model.Table)
    io = IOBuffer()
    Model.write_table(io, t)
    return take!(io)
end
