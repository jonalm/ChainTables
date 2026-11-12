"""
    load_table!(copy, name) -> Table

The table `name`, read whole from its file on first touch and resident until close.

The file is hashed and compared with its name before any byte reaches the model. A
mismatch, a file that is not a canonical table file, or a row slot above the head's
slot throws `LocalCopyInconsistentError`. An unknown name throws `ModelError`.
"""
function load_table!(copy::LocalCopy, name::AbstractString)
    check_open(copy)
    haskey(copy.content, name) && return copy.content[name]
    is_unread(copy, name) || fail("unknown table $(repr(name))")
    t = read_table_file(copy, name, copy.tables[name])
    copy.content[name] = t
    push!(copy.loaded, name)
    return t
end

"""
    load_tables!(copy, names)
    load_tables!(copy, record)

`load_table!` every name the head has among `names`, or among the tables a record's ops
name; other names are skipped. Apply sees only what is loaded, so a `create_table` of a
name the head already has is refused.
"""
function load_tables!(copy::LocalCopy, names)
    check_open(copy)
    unread = filter(n -> is_unread(copy, n), collect(names))
    foreach(name -> load_table!(copy, name), unread)
    return nothing
end

function load_tables!(copy::LocalCopy, r::Ops.Record)
    return load_tables!(copy, unique(op.table for op in r.ops))
end

is_unread(copy::LocalCopy, name) = haskey(copy.tables, name) && !(name in copy.loaded)
is_untouched(copy::LocalCopy, name) = !(name in copy.loaded || haskey(copy.content, name))

"""
    stage!(copy) -> (; tables, state_fingerprint)

Write a table file for every table in `copy.content`, skipping a name that exists, and
return the `name => table hash` list the next head would carry, with its fingerprint.
An untouched table keeps the head's hash, unread. Until `write_head!` names them the new
files are orphans, and `discard!` sweeps them.
"""
function stage!(copy::LocalCopy)
    check_open(copy)
    untouched = filter(p -> is_untouched(copy, first(p)), collect(copy.tables))
    written = [name => write_table_file!(copy, t) for (name, t) in copy.content]
    entries = sort!(vcat(untouched, written); by = first)
    return (; tables = entries, state_fingerprint = state_fingerprint(entries))
end

"""
    write_head!(copy, chain_id, slot, transaction_hash, staged)

The local commit point: write the head file for `slot` naming `staged.tables`, after
every file it names, then sweep. `chain_id` is the record's 16 bytes; `staged` is
`stage!`'s result. The slot must advance and the chain id must not change. The cached
views of the old head are dropped.
"""
function write_head!(
        copy::LocalCopy, chain_id::AbstractVector{UInt8}, slot::Integer,
        transaction_hash::AbstractVector{UInt8}, staged
    )
    check_open(copy)
    id_text = chain_id_string(chain_id)
    check_advance(copy, id_text, slot)
    h = Head(
        id_text, Ops.FORMAT_VERSION, slot, Vector{UInt8}(transaction_hash),
        staged.state_fingerprint, staged.tables, round(Int64, time() * 1000),
        written_by_here()
    )
    check_head(h)
    write_file_atomically(head_path(copy, slot), encode_head(h))
    copy.head = h
    copy.tables = Dict(h.tables)
    copy.loaded = Set(keys(copy.content))
    empty!(copy.views)
    sweep!(copy)
    return nothing
end

"""
    discard!(copy)

Drop the model and sweep, leaving `copy` at its head: after a `412`, a lost race or a
failed apply, the touched tables reload from the head's files, and staged files are gone.
"""
function discard!(copy::LocalCopy)
    check_open(copy)
    empty!(copy.content)
    empty!(copy.loaded)
    sweep!(copy)
    return nothing
end

"""
    checkpoint!(copy, chain_id, slot, transaction_hash, state_fingerprint; client = nothing)

One checkpoint of a replay: `stage!`, compare the fingerprint with the record's
`state_fingerprint`, and `write_head!`.

A mismatch is divergence or an apply bug, never damage: the model is dropped, the copy
stays at its last checkpoint, and `FingerprintMismatchError` names both fingerprints and,
with `client`, the record's `client.lib` and `client.julia`.
"""
function checkpoint!(
        copy::LocalCopy, chain_id::AbstractVector{UInt8}, slot::Integer,
        transaction_hash::AbstractVector{UInt8}, state_fingerprint::AbstractVector{UInt8};
        client = nothing
    )
    check_open(copy)
    check_advance(copy, chain_id_string(chain_id), slot)
    staged = stage!(copy)
    staged.state_fingerprint == state_fingerprint ||
        refuse_mismatch(copy, chain_id, slot, state_fingerprint, staged, client)
    write_head!(copy, chain_id, slot, transaction_hash, staged)
    return nothing
end

"""
    hash_file(file) -> Vector{UInt8}
    hash_file(io) -> Vector{UInt8}

The SHA-256 of a file's bytes, read in 1 MiB chunks.
"""
hash_file(file::AbstractString) = Base.open(hash_file, file)

function hash_file(io::IO)
    ctx = SHA.SHA256_CTX()
    buf = Vector{UInt8}(undef, 1 << 20)
    while !eof(io)
        n = readbytes!(io, buf)
        SHA.update!(ctx, view(buf, 1:n))
    end
    return SHA.digest!(ctx)
end

function read_table_file(copy::LocalCopy, name, hash)
    file = table_path(copy, hash)
    isfile(file) || throw_damaged_table(copy, name, hash, "is missing")
    got = hash_file(file)
    got == hash || throw_damaged_table(copy, name, hash, "hashes to $(bytes2hex(got))")
    t = decode_table_file(copy, name, hash, file)
    # The hash and the head's fingerprint already held, so only a fabricated or wrongly
    # written head gets a row slot past it here (ADR-0032).
    top = isempty(t.slots) ? 0 : maximum(t.slots)
    top <= copy.head.slot || throw_damaged_table(
        copy, name, hash, "holds a row slot $top, above the head's slot $(copy.head.slot)"
    )
    return t
end

function decode_table_file(copy::LocalCopy, name, hash, file)
    try
        return Base.open(read_table, file)
    catch e
        e isa ModelError || e isa CBOR.DecodeError || rethrow()
        throw_damaged_table(
            copy, name, hash, "hashes to its name but is not a canonical table file"
        )
    end
end

function throw_damaged_table(copy::LocalCopy, name, hash, what)
    file = "tables/$(bytes2hex(hash))"
    detail = "table file $file (table $(repr(name))) $what"
    slot = copy.head.slot
    throw(LocalCopyInconsistentError(; path = copy.path, slot, file, detail))
end

# Every file is written to a .tmp in its directory and renamed into place; a table
# file's name is known only once it is hashed, so its .tmp name is random.
function write_table_file!(copy::LocalCopy, t::Table)
    dir = tables_dir(copy)
    tmp = joinpath(dir, bytes2hex(rand(UInt8, 8)) * ".tmp")
    hash = Base.open(io -> write_table(io, t), tmp, "w")
    target = joinpath(dir, bytes2hex(hash))
    # A name that exists already holds these bytes (ADR-0009).
    if isfile(target)
        rm(tmp; force = true)
    else
        mv(tmp, target; force = true)
    end
    return hash
end

function write_file_atomically(target::AbstractString, bytes)
    tmp = target * ".tmp"
    write(tmp, bytes)
    mv(tmp, target; force = true)
    return nothing
end

function check_advance(copy::LocalCopy, chain_id, slot)
    h = copy.head
    h === nothing && return nothing
    slot > h.slot || throw(
        ArgumentError("slot $slot is not above the head's slot $(h.slot)")
    )
    chain_id == h.chain_id || throw(
        ArgumentError(
            "the local copy at $(copy.path) is bound to chain $(h.chain_id); a head for " *
                "chain $chain_id cannot be written into it"
        )
    )
    return nothing
end

function refuse_mismatch(copy::LocalCopy, chain_id, slot, expected, staged, client)
    stays = copy.head === nothing ? "fresh and unbound" : "at slot $(copy.head.slot)"
    discard!(copy)
    evidence = (;
        chain_id = chain_id_string(chain_id), slot = Int64(slot),
        expected = Vector{UInt8}(expected), computed = staged.state_fingerprint,
        record_client = client_version(client), this_client = written_by_here(),
    )
    throw(FingerprintMismatchError(; evidence..., detail = "the local copy stays $stays"))
end

client_version(::Nothing) = nothing
client_version(client) = (; lib = client.lib, julia = client.julia)
