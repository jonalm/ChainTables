# Returns the table `name`, read whole from its table file at first use and loaded until
# `close` (ADR-0023). The file is hashed, and the hash held against the file's name,
# before any byte reaches the model. Throws the internal `ModelError` for an unknown
# name.
function load_table!(local_copy::LocalCopy, name::AbstractString)
    check_open(local_copy)
    haskey(local_copy.content, name) && return local_copy.content[name]
    is_unread(local_copy, name) || throw(Model.ModelError("unknown table $(repr(name))"))
    t = read_checked_table(local_copy, name, local_copy.tables[name])
    local_copy.content[name] = t
    push!(local_copy.loaded, name)
    return t
end

# Loads every table that the head has among `names`, or among the tables that the ops
# of a record name. Apply sees only what is loaded, so a `create_table` on a name that
# the head has is refused as it should be.
function load_tables!(local_copy::LocalCopy, names)
    check_open(local_copy)
    unread = filter(name -> is_unread(local_copy, name), collect(names))
    foreach(name -> load_table!(local_copy, name), unread)
    return nothing
end

function load_tables!(local_copy::LocalCopy, record::Ops.Record)
    return load_tables!(local_copy, unique(op.table for op in record.ops))
end

# Writes the table file of every table in `content`, skipping one that exists, and
# returns the `name => table_hash` list that the next head would hold, with its state
# fingerprint (ADR-0009). An untouched table keeps the head's hash and is not read.
# Until `write_head!` names them, the new files are orphans, and `discard!` sweeps them.
function write_staged_tables(local_copy::LocalCopy)
    check_open(local_copy)
    entries = collect(local_copy.tables)
    untouched = filter(entry -> is_untouched(local_copy, first(entry)), entries)
    written = Pair{String, Vector{UInt8}}[
        name => write_table_file(local_copy, t) for (name, t) in local_copy.content
    ]
    staged = sort!(vcat(untouched, written); by = first)
    return (; tables = staged, state_fingerprint = Model.state_fingerprint(staged))
end

# The local commit point (ADR-0009, ADR-0023): the head file is written after every
# table file it names, to a `.tmp` that is then renamed. The slot moves up and the chain
# id stays. Afterwards every table in `content` is a loaded table of the new head.
function write_head!(local_copy::LocalCopy, head_file::Head)
    check_open(local_copy)
    check_advance(local_copy, head_file.chain_id, head_file.slot)
    target = head_path(local_copy, head_file.slot)
    write(target * ".tmp", encode_head(head_file))
    mv(target * ".tmp", target; force = true)
    local_copy.head = head_file
    local_copy.tables = table_hashes(head_file)
    local_copy.loaded = Set(keys(local_copy.content))
    empty!(local_copy.views)
    sweep_orphans(local_copy)
    return nothing
end

# Drops the loaded tables and sweeps, which leaves the copy at its head (ADR-0009): the
# tables load again from the head's files, and the staged files are gone.
function discard!(local_copy::LocalCopy)
    check_open(local_copy)
    empty!(local_copy.content)
    empty!(local_copy.loaded)
    sweep_orphans(local_copy)
    return nothing
end

# One checkpoint of a replay, at `record` (ADR-0013): the staged tables' state
# fingerprint is held against the record's before the head is written. A mismatch is
# divergence or a bug in apply, never a damaged copy: the loaded tables are dropped and
# the copy stays at its last checkpoint.
function checkpoint!(local_copy::LocalCopy, record::Ops.Record, transaction_hash)
    check_open(local_copy)
    chain_id = chain_id_string(record.chain_id)
    check_advance(local_copy, chain_id, record.slot)
    staged = write_staged_tables(local_copy)
    if staged.state_fingerprint != record.state_fingerprint
        stays = stays_at(local_copy.head)
        discard!(local_copy)
        throw(
            FingerprintMismatchError(;
                local_copy.path, chain_id, record.slot,
                expected = StateFingerprint(record.state_fingerprint),
                computed = StateFingerprint(staged.state_fingerprint),
                record_client = (; record.client.lib, record.client.julia),
                this_client = written_by_here(), detail = "the local copy stays $stays",
            )
        )
    end
    write_head!(local_copy, next_head(chain_id, record.slot, transaction_hash, staged))
    return nothing
end

function is_unread(local_copy::LocalCopy, name)
    return haskey(local_copy.tables, name) && name ∉ local_copy.loaded
end

function read_checked_table(local_copy::LocalCopy, name, hash)
    file = table_path(local_copy, hash)
    what = "table $(repr(name))"
    isfile(file) || throw(
        LocalCopyInconsistentError(
            local_copy, hash; reason = :table_file_missing,
            detail = "$what: the file is missing",
        )
    )
    found = hash_file(file)
    found == hash || throw(
        LocalCopyInconsistentError(
            local_copy, hash; reason = :table_file_hash,
            detail = "$what: the file hashes to $(bytes2hex(found))",
        )
    )
    t = try
        Base.open(Model.read_table, file)
    catch e
        e isa Union{Model.ModelError, CBOR.DecodeError} || rethrow()
        detail = "$what: $(unreadable_detail(e))"
        reason = :table_file_not_canonical
        throw(LocalCopyInconsistentError(local_copy, hash; reason, detail))
    end
    check_row_slots(local_copy, t, hash, what)
    return t
end

# The hash and the head's state fingerprint already held, so only a head written wrongly
# gets a row slot past its own slot here (ADR-0032).
function check_row_slots(local_copy::LocalCopy, t::Model.Table, hash, what)
    top = maximum(t.slots; init = 0)
    slot = local_copy.head.slot
    top <= slot || throw(
        LocalCopyInconsistentError(
            local_copy, hash; reason = :row_slot_above_head,
            detail = "$what: the file holds a row slot $top, above the head's slot $slot",
        )
    )
    return nothing
end

# The setup that the throw sites of a damaged table file share.
function LocalCopyInconsistentError(local_copy::LocalCopy, hash; reason, detail)
    head_file = local_copy.head
    file = "tables/$(bytes2hex(hash))"
    return LocalCopyInconsistentError(;
        local_copy.path, head_file.chain_id, head_file.slot, file, reason, detail,
    )
end

unreadable_detail(e::Model.ModelError) = e.detail
unreadable_detail(e::CBOR.DecodeError) = "$(e.detail) at byte $(e.offset)"

# The name has no I/O verb: attachments.jl calls it and passes it as a keyword default.
hash_file(file::AbstractString) = Base.open(hash_file, file)

function hash_file(io::IO)
    context = SHA.SHA256_CTX()
    buffer = Vector{UInt8}(undef, 1 << 20)
    while !eof(io)
        n = readbytes!(io, buffer)
        SHA.update!(context, view(buffer, 1:n))
    end
    return SHA.digest!(context)
end

# A file is written to a `.tmp` in its directory and renamed into place. A table file's
# name is known only once it is hashed, so its `.tmp` has a random name.
function write_table_file(local_copy::LocalCopy, t::Model.Table)
    tmp = temporary_table_path(local_copy)
    hash = Base.open(io -> Model.write_table(io, t), tmp, "w")
    target = table_path(local_copy, hash)
    # A file that exists is not written again (ADR-0009).
    if isfile(target)
        rm(tmp; force = true)
    else
        mv(tmp, target; force = true)
    end
    return hash
end

function temporary_table_path(local_copy::LocalCopy)
    return joinpath(tables_dir(local_copy), bytes2hex(rand(UInt8, 8)) * ".tmp")
end

# The table files that the head names, each with its tables in name order. Two tables
# with the same content share one file (ADR-0023).
function table_files_of(head_file::Head)
    hashes = unique(map(last, head_file.tables))
    return [hash => tables_in_file(head_file, hash) for hash in hashes]
end

function tables_in_file(head_file::Head, hash)
    return [name for (name, table_hash) in head_file.tables if table_hash == hash]
end

# Returns what the table file named `hash` hashes to, `nothing` when it is missing.
function hash_table_file(local_copy::LocalCopy, hash)
    file = table_path(local_copy, hash)
    return isfile(file) ? hash_file(file) : nothing
end

function check_advance(local_copy::LocalCopy, chain_id, slot)
    head_file = local_copy.head
    head_file === nothing && return nothing
    slot > head_file.slot || throw(
        ArgumentError(
            "slot $slot is not above the head's slot $(head_file.slot); a head is " *
                "write-once and the slot moves up"
        )
    )
    chain_id == head_file.chain_id || throw(
        ArgumentError(
            "the local copy at $(local_copy.path) is bound to chain " *
                "$(head_file.chain_id); a head for chain $chain_id cannot be written " *
                "into it"
        )
    )
    return nothing
end

function is_untouched(local_copy::LocalCopy, name)
    return name ∉ local_copy.loaded && !haskey(local_copy.content, name)
end

stays_at(::Nothing) = "with no head"
stays_at(head_file::Head) = "at slot $(head_file.slot), its last checkpoint"
