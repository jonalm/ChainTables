using ChainTables: ChainTables, Model, Ops
using ChainTables.Ops: Client, Record

# No API name says which table file holds a table, or writes a head: the fixtures below
# read and set the fields `head` and `chain` of a `LocalCopy`, and build a
# `ChainTables.Head`.

const DIVERGED_CLIENT = Client(nothing, nothing, "L", "J", 1)

# The table file that holds `name` at the head of the local copy.
function table_file(local_copy, name)
    hash = Dict(local_copy.head.tables)[String(name)]
    return joinpath(local_copy.path, "tables", bytes2hex(hash))
end

# The head file of the local copy.
function head_file_path(local_copy)
    return joinpath(local_copy.path, "heads", lpad(local_copy.head.slot, 12, '0'))
end

# Flips the last byte of the table file that holds `name`. Returns the file and its
# bytes before.
function damage_table_file!(local_copy, name)
    file = table_file(local_copy, name)
    good = read(file)
    bad = copy(good)
    bad[end] ⊻= 0x01
    write(file, bad)
    return (; file, good)
end

# Two tables with one content, so that they share one table file.
function seed_twin_tables!(w)
    foreach(name -> seed_keys!(w, name), (:tags, :twin))
    return nothing
end

function seed_keys!(w, name)
    ChainTables.create_table!(w, name) do t
        ChainTables.column!(t, :k, Int64)
        ChainTables.primary_key!(t, :k)
    end
    ChainTables.insert_rows!(w, name, [(k = 1,), (k = 2,)])
    return nothing
end

# The records of slots `liar` to the head written again, each with the state
# fingerprint `fill(slot, 32)`, which no client computes: as committers whose model
# diverged from this client's would write them. They replace the records in the store
# and in the record cache, and the head of the local copy names the last of them. Its
# table files stay as they are: a copy that applied the records cannot be built, since
# its checkpoint refuses them. Returns the state fingerprints the records had.
function diverge_from!(local_copy, liar)
    chain = local_copy.chain
    top = local_copy.head.slot
    fingerprints = [stored_record(chain, slot).state_fingerprint for slot in 0:top]
    parent = liar == 0 ? nothing : stored_hash(chain.store, liar - 1)
    for slot in liar:top
        parent = plant_diverged_record!(chain, slot, parent)
    end
    point_head_at!(local_copy, parent)
    return fingerprints
end

stored_record(chain, slot) = Ops.decode_record(chain.store.objects[slot_key(slot)]; slot)

# Returns the transaction hash of the planted record.
function plant_diverged_record!(chain, slot, parent)
    record = stored_record(chain, slot)
    diverged = Record(
        record.chain_id, slot, parent, fill(UInt8(slot), 32), DIVERGED_CLIENT,
        record.comment, record.ops,
    )
    bytes = Ops.encode_record(diverged)
    plant!(chain.store, slot_key(slot), bytes)
    write(record_file(chain, slot), bytes)
    return Ops.transaction_hash(bytes)
end

# The head of the local copy, in memory, with another transaction hash.
function point_head_at!(local_copy, transaction_hash)
    local_copy.head = with_head_fields(local_copy.head; transaction_hash)
    return nothing
end

# The head of the local copy, in memory, with only the tables in `kept`: a head that
# agrees with itself and that a replay of its records does not give.
function drop_tables_from_head!(local_copy, kept)
    tables = filter(entry -> first(entry) in kept, local_copy.head.tables)
    state_fingerprint = Model.state_fingerprint(tables)
    local_copy.head = with_head_fields(local_copy.head; tables, state_fingerprint)
    return nothing
end

# Writes the head file at `path` for `slot` again, naming `transaction_hash`.
function rewrite_head_file!(path, slot, transaction_hash)
    file = joinpath(path, "heads", lpad(slot, 12, '0'))
    head_file = with_head_fields(ChainTables.decode_head(read(file)); transaction_hash)
    rm(file)
    write(file, ChainTables.encode_head(head_file))
    return nothing
end

function with_head_fields(head_file; changed...)
    names = fieldnames(typeof(head_file))
    field_values = map(name -> getfield(head_file, name), names)
    fields = merge(NamedTuple{names}(field_values), changed)
    return ChainTables.Head(fields...)
end
