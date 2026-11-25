using ChainTables: ChainTables, CBOR, Model, Ops
using ChainTables.Model: Column, Shape
using ChainTables.Ops: Client, CreateTable, DropTable, Insert, Record

# A chain that `open` can read nothing from: it has no field.
struct NoChain end

# A chain that knows its chain id, so that `open` holds a head against it.
struct BoundChain
    chain_id::String
end

ChainTables.expected_chain_id(chain::BoundChain) = chain.chain_id

const COPY_CHAIN_ID = UInt8.(0:15)
const COPY_CHAIN_ID_TEXT = "AAAQEAYEAUDAOCAJBIFQYDIOB4"
const OTHER_CHAIN_ID_TEXT = "CEIRCEIRCEIRCEIRCEIRCEIRCE"
const COPY_SHAPE = Shape([Column("id", "int64", false), Column("v", "text", true)], ["id"])
const COPY_ROWS = [Any[1, "a"], Any[2, missing]]
const COPY_CLIENT = Client(nothing, nothing, "ChainTables 9.9.9", "1.99.0", 1)
const HEAD_MAGIC = "chaintables/v1/head"

# The transaction hash that the tests give slot `n`.
hash_of(n) = fill(UInt8(n), 32)

function with_local_copy(f, chain = NoChain())
    mktempdir() do dir
        local_copy = ChainTables.open(chain, dir)
        try
            f(local_copy)
        finally
            close(local_copy)
        end
    end
    return nothing
end

# A record that names `fingerprint`, for a checkpoint: only its envelope is read.
function record_with(slot, fingerprint)
    parent = slot == 0 ? nothing : hash_of(slot - 1)
    ops = slot == 0 ? Ops.Op[] : [DropTable("unread")]
    return Record(COPY_CHAIN_ID, slot, parent, fingerprint, COPY_CLIENT, nothing, ops)
end

# The state fingerprint of the copy's content as it stands. A table that is not loaded
# has the hash that the head holds for it.
function content_fingerprint(local_copy)
    unread = filter(entry -> first(entry) ∉ local_copy.loaded, collect(local_copy.tables))
    loaded = Pair{String, Vector{UInt8}}[
        name => Model.table_hash(t) for (name, t) in local_copy.content
    ]
    return Model.state_fingerprint(vcat(unread, loaded))
end

# A checkpoint at `slot` of the content as it stands.
function checkpoint_at!(local_copy, slot)
    record = record_with(slot, content_fingerprint(local_copy))
    return ChainTables.checkpoint!(local_copy, record, hash_of(slot))
end

function apply_all!(local_copy, slot, ops)
    foreach(op -> Ops.apply!(local_copy.content, op, slot), ops)
    return nothing
end

# Slot 0 with no table, then slot 1 with the tables t and u, which are equal, and w.
function two_checkpoints!(local_copy)
    checkpoint_at!(local_copy, 0)
    ops = [
        CreateTable("t", COPY_SHAPE), Insert("t", COPY_ROWS),
        CreateTable("u", COPY_SHAPE), Insert("u", COPY_ROWS),
        CreateTable("w", COPY_SHAPE), Insert("w", [Any[7, "z"]]),
    ]
    apply_all!(local_copy, 1, ops)
    checkpoint_at!(local_copy, 1)
    return local_copy
end

head_names(dir) = sort(readdir(joinpath(dir, "heads")))
table_names(dir) = sort(readdir(joinpath(dir, "tables")))
head_file_path(dir, slot) = joinpath(dir, "heads", lpad(slot, 12, '0'))
head_wire(bytes) = CBOR.decode(bytes[(ncodeunits(HEAD_MAGIC) + 1):end])

# The bytes of a head file with fields replaced, or left out when given as `nothing`.
function rewritten_head(bytes; fields...)
    wire = head_wire(bytes)
    kept = filter(field -> last(field) !== nothing, collect(pairs(fields)))
    dropped = filter(field -> last(field) === nothing, collect(pairs(fields)))
    foreach(field -> delete!(wire, string(first(field))), dropped)
    foreach(field -> setindex!(wire, last(field), string(first(field))), kept)
    return vcat(codeunits(HEAD_MAGIC), CBOR.encode(wire))
end
