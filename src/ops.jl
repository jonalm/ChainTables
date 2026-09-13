# #34 step 3 — ADR-0025, ADR-0006, ADR-0026, ADR-0022: ops, record envelope, transaction_hash, apply with re-validation.

"""
    Ops

The seven ops, the transaction record envelope, `transaction_hash`, and apply
(ADR-0025, ADR-0006, ADR-0022). Nothing here is exported (ADR-0019); every
name is internal to the write builder and the local copy.

# Ops (ADR-0025)

An op is a map with an `"op"` discriminator and a `"table"`:

    create_table  {"op", "table", "shape"}
    add_column    {"op", "table", "column": [name, type, nullable], "fill": value}
    drop_column   {"op", "table", "column": name}
    drop_table    {"op", "table"}
    insert        {"op", "table", "rows": [[every column, declaration order], …]}
    update        {"op", "table", "columns": [non-key names, declaration order], "rows": [[key…, values…], …]}
    delete        {"op", "table", "keys": [[key…], …]}

Each is a Julia struct here ([`CreateTable`](@ref) … [`Delete`](@ref));
[`wire`](@ref) gives the map for `CBOR.encode` and [`op_from_wire`](@ref) reads
it back, refusing an unknown op, an unknown or missing field, or a field of the
wrong shape. `rows` and `keys` are in typed key order (ADR-0025); apply checks
that, it never sorts.

# The record envelope (ADR-0006, amended by ADR-0022)

    {"format_version": 1, "chain_id": h'<16>', "slot": n, "prev_hash": h'<32>' (absent at slot 0),
     "state_fingerprint": h'<32>', "client": {"host"?, "user"?, "lib", "julia", "time_ms"},
     "comment"?: tstr, "ops": [op, …]}

[`Record`](@ref) holds it; [`encode_record`](@ref) writes the bytes and enforces
the 64 MiB cap; [`decode_record`](@ref) reads them under the rejecting decoder
and refuses an unknown field, a `format_version` above [`FORMAT_VERSION`](@ref),
a missing or mis-shaped field. `transaction_hash = SHA-256("chaintables/v1/txn" ‖ bytes)`
over the stored bytes ([`transaction_hash`](@ref)); a record never carries its own.

# Apply (ADR-0025, ADR-0022)

[`apply!`](@ref) runs a record's ops on a `Model.Content` in order. Every
structural check the write builder runs is re-run here through the model's own
primitives — value type and nullability, every column named by an insert, known
table and column, a non-key column for `drop_column`, no duplicate key in an op,
rows in key order, and the state gate — so the builder's checks and apply's are
one code path. A record that fails any of them is a **malformed record**:
`MalformedRecordError` names the slot, the op index and the rule (ADR-0020).
Apply never computes: a typed value passes from the decoder to the model
untouched.
"""
module Ops

import SHA
using ..CBOR
using ..Model
using ..Model: Shape, Column, Content, ModelError, fail
using ..ChainTables: ChainTables, MalformedRecordError, WriteBuilderError

# ---------------------------------------------------------------------------
# The seven ops (ADR-0025)
# ---------------------------------------------------------------------------

"""
    Op

One of the seven ops of ADR-0025. Every op names its `table`.
"""
abstract type Op end

"""
    CreateTable(table, shape::Shape)
"""
struct CreateTable <: Op
    table::String
    shape::Shape
end

"""
    AddColumn(table, column::Column, fill)

`fill` is the typed value every existing row receives; null (`missing`) only if
the column is nullable.
"""
struct AddColumn <: Op
    table::String
    column::Column
    fill::Any
end

"""
    DropColumn(table, column)
"""
struct DropColumn <: Op
    table::String
    column::String
end

"""
    DropTable(table)
"""
struct DropTable <: Op
    table::String
end

"""
    Insert(table, rows)

`rows` are vectors of every column in declaration order, in typed key order.
"""
struct Insert <: Op
    table::String
    rows::Vector{Vector{Any}}
end

"""
    Update(table, columns, rows)

`columns` are the non-key columns changed, in declaration order; each row is
`[key…, values…]`, the full key in key declaration order then one value per
column, in typed key order.
"""
struct Update <: Op
    table::String
    columns::Vector{String}
    rows::Vector{Vector{Any}}
end

"""
    Delete(table, keys)

`keys` are vectors of the key columns in key declaration order, in typed key order.
"""
struct Delete <: Op
    table::String
    keys::Vector{Vector{Any}}
end

Base.:(==)(a::T, b::T) where {T<:Op} = all(isequal(getfield(a, f), getfield(b, f)) for f in fieldnames(T))
Base.isequal(a::T, b::T) where {T<:Op} = a == b

const OP_NAMES = (
    CreateTable => "create_table", AddColumn => "add_column", DropColumn => "drop_column",
    DropTable => "drop_table", Insert => "insert", Update => "update", Delete => "delete",
)

"""
    op_name(op) -> String

The op's wire discriminator: one of `create_table`, `add_column`, `drop_column`,
`drop_table`, `insert`, `update`, `delete`.
"""
op_name(op::Op) = op_name(typeof(op))
op_name(::Type{T}) where {T<:Op} = last(OP_NAMES[findfirst(p -> first(p) === T, OP_NAMES)])

rows_wire(rows) = Any[Any[r...] for r in rows]

"""
    wire(op) -> Dict{String,Any}

The op's wire form, ready for `CBOR.encode` (ADR-0025).
"""
wire(op::CreateTable) = Dict{String,Any}("op" => op_name(op), "table" => op.table, "shape" => Model.wire(op.shape))
wire(op::AddColumn) = Dict{String,Any}("op" => op_name(op), "table" => op.table,
    "column" => Any[op.column.name, op.column.type, op.column.nullable], "fill" => op.fill)
wire(op::DropColumn) = Dict{String,Any}("op" => op_name(op), "table" => op.table, "column" => op.column)
wire(op::DropTable) = Dict{String,Any}("op" => op_name(op), "table" => op.table)
wire(op::Insert) = Dict{String,Any}("op" => op_name(op), "table" => op.table, "rows" => rows_wire(op.rows))
wire(op::Update) = Dict{String,Any}("op" => op_name(op), "table" => op.table,
    "columns" => Any[op.columns...], "rows" => rows_wire(op.rows))
wire(op::Delete) = Dict{String,Any}("op" => op_name(op), "table" => op.table, "keys" => rows_wire(op.keys))

# The fields each op carries besides "op" and "table"; a wire op has exactly these.
op_fields(::Type{CreateTable}) = ("shape",)
op_fields(::Type{AddColumn}) = ("column", "fill")
op_fields(::Type{DropColumn}) = ("column",)
op_fields(::Type{DropTable}) = ()
op_fields(::Type{Insert}) = ("rows",)
op_fields(::Type{Update}) = ("columns", "rows")
op_fields(::Type{Delete}) = ("keys",)

# `a drop_table op` / `an insert op` / `an update op`
article(name) = (name[1] in ('a', 'e', 'i', 'o', 'u') ? "an " : "a ") * name

function field(w, T, name)
    haskey(w, name) || fail("$(op_name(T)) op has no $(repr(name)) field")
    return w[name]
end

function text_field(w, T, name)
    x = field(w, T, name)
    x isa String || fail("$(repr(name)) of $(article(op_name(T))) op is not text")
    return x
end

function rows_field(w, T, name)
    x = field(w, T, name)
    x isa AbstractVector && all(r -> r isa AbstractVector, x) ||
        fail("$(repr(name)) of $(article(op_name(T))) op is not an array of arrays")
    return Vector{Any}[Any[r...] for r in x]
end

function column_field(w, T)
    e = field(w, T, "column")
    e isa AbstractVector && length(e) == 3 && e[1] isa String && e[2] isa String && e[3] isa Bool ||
        fail("column entry $(repr(e)) is not [name, type, nullable]")
    return Column(e[1], e[2], e[3])
end

"""
    op_from_wire(w) -> Op

Read one op from its wire form as `CBOR.decode` yields it. Refuses with a
`Model.ModelError` an unknown op name, a missing or unknown field, or a field
of the wrong shape; the cells themselves are checked against the shape at
apply, where the shape is known.
"""
function op_from_wire(w)
    w isa AbstractDict || fail("op is not a map, got a value of type $(typeof(w))")
    haskey(w, "op") || fail("op has no \"op\" field")
    haskey(w, "table") || fail("op has no \"table\" field")
    name = w["op"]
    i = name isa String ? findfirst(p -> last(p) == name, OP_NAMES) : nothing
    i === nothing && fail("unknown op $(repr(name)); the ops are $(join(last.(OP_NAMES), ", "))")
    T = first(OP_NAMES[i])
    for k in keys(w)
        k in ("op", "table") || k in op_fields(T) || fail("unknown field $(repr(k)) on $(article(name)) op")
    end
    table = text_field(w, T, "table")
    return op_from_wire(T, w, table)
end

op_from_wire(::Type{CreateTable}, w, table) = CreateTable(table, Shape(field(w, CreateTable, "shape")))
op_from_wire(::Type{AddColumn}, w, table) = AddColumn(table, column_field(w, AddColumn), field(w, AddColumn, "fill"))
op_from_wire(::Type{DropColumn}, w, table) = DropColumn(table, text_field(w, DropColumn, "column"))
op_from_wire(::Type{DropTable}, w, table) = DropTable(table)
op_from_wire(::Type{Insert}, w, table) = Insert(table, rows_field(w, Insert, "rows"))
function op_from_wire(::Type{Update}, w, table)
    cols = field(w, Update, "columns")
    cols isa AbstractVector && all(c -> c isa String, cols) ||
        fail("\"columns\" of an update op is not an array of names")
    return Update(table, String[cols...], rows_field(w, Update, "rows"))
end
op_from_wire(::Type{Delete}, w, table) = Delete(table, rows_field(w, Delete, "keys"))

# ---------------------------------------------------------------------------
# The record envelope (ADR-0006, ADR-0022, ADR-0026)
# ---------------------------------------------------------------------------

"""
    FORMAT_VERSION

The one `format_version` this client reads and writes: 1. A record above it is
a hard error — a newer client wrote it (ADR-0006, unknown is fatal).
"""
const FORMAT_VERSION = 1

"""
    TXN_SEPARATOR

The domain separator of the transaction hash, `"chaintables/v1/txn"` (ADR-0026).
Format bytes: frozen for the life of `format_version` 1.
"""
const TXN_SEPARATOR = "chaintables/v1/txn"

"""
    MAX_RECORD_BYTES

The record cap, 64 MiB (ADR-0006), enforced when a record is built and again
when one is read.
"""
const MAX_RECORD_BYTES = 64 * 1024 * 1024

const ENVELOPE_FIELDS = ("format_version", "chain_id", "slot", "prev_hash", "state_fingerprint", "client", "comment", "ops")
const CLIENT_FIELDS = ("host", "user", "lib", "julia", "time_ms")

function check_text(what, s)
    isvalid(s) || fail("$what is not well-formed UTF-8")
    '\0' in s && fail("$what contains U+0000")
    return s
end
check_text(what, ::Nothing) = nothing

"""
    Client(host, user, lib, julia, time_ms)

The envelope's `client` map (ADR-0006): `host` and `user` are `nothing` when
suppressed (ADR-0006, each individually); `lib` names the package and its
version and `julia` the Julia version, both advisory and forensic (ADR-0022);
`time_ms` is int64 milliseconds since the Unix epoch, UTC.
[`local_client`](@ref) fills it in for this machine.
"""
struct Client
    host::Union{Nothing,String}
    user::Union{Nothing,String}
    lib::String
    julia::String
    time_ms::Int64
    function Client(host, user, lib, julia, time_ms)
        check_text("client.host", host)
        check_text("client.user", user)
        check_text("client.lib", lib)
        check_text("client.julia", julia)
        return new(host, user, lib, julia, time_ms)
    end
end

Base.:(==)(a::Client, b::Client) = all(isequal(getfield(a, f), getfield(b, f)) for f in fieldnames(Client))

"""
    local_client(; record_host = true, record_user = true) -> Client

This machine's `client` map, at this moment: `lib` is `"ChainTables <version>"`,
`julia` is `string(VERSION)`, `time_ms` is now. `record_host = false` or
`record_user = false` leaves the field out (ADR-0006).
"""
function local_client(; record_host = true, record_user = true)
    host = record_host ? gethostname() : nothing
    user = record_user ? get(ENV, "USER", get(ENV, "USERNAME", "")) : nothing
    user == "" && (user = nothing)
    return Client(host, user, "ChainTables $(pkgversion(@__MODULE__))", string(VERSION),
                  round(Int64, time() * 1000))
end

"""
    Record(chain_id, slot, prev_hash, state_fingerprint, client, comment, ops)

One transaction record (ADR-0006): the envelope's fields as Julia values, with
`prev_hash === nothing` at slot 0 and nowhere else, `comment === nothing` when
absent, and `ops` a vector of [`Op`](@ref) — empty only at slot 0, the zero-op
genesis `create_chain` writes (ADR-0019). `format_version` is not a
field: a `Record` is always [`FORMAT_VERSION`](@ref). The constructor holds
every envelope rule — 16-byte chain id, 32-byte hashes, a non-negative slot,
`prev_hash` present exactly after genesis, at least one op after genesis, a comment of
well-formed UTF-8 without U+0000 — raising `Model.ModelError`, so the builder
and [`decode_record`](@ref) share one check. A record never holds its own
`transaction_hash`: that is a function of its stored bytes.
"""
struct Record
    chain_id::Vector{UInt8}
    slot::Int64
    prev_hash::Union{Nothing,Vector{UInt8}}
    state_fingerprint::Vector{UInt8}
    client::Client
    comment::Union{Nothing,String}
    ops::Vector{Op}
    function Record(chain_id, slot, prev_hash, state_fingerprint, client, comment, ops)
        length(chain_id) == 16 || fail("chain_id is $(length(chain_id)) bytes; a chain id is 16")
        length(state_fingerprint) == 32 || fail("state_fingerprint is $(length(state_fingerprint)) bytes; a SHA-256 is 32")
        slot < 0 && fail("slot $slot is negative")
        if slot == 0
            prev_hash === nothing || fail("slot 0 carries a prev_hash; genesis has no parent (ADR-0002)")
        else
            prev_hash === nothing && fail("slot $slot has no prev_hash; every slot after genesis names its parent")
            length(prev_hash) == 32 || fail("prev_hash is $(length(prev_hash)) bytes; a SHA-256 is 32")
        end
        slot == 0 || !isempty(ops) || fail("record has no ops; a record after genesis carries at least one (ADR-0019)")
        check_text("comment", comment)
        return new(Vector{UInt8}(chain_id), slot, prev_hash === nothing ? nothing : Vector{UInt8}(prev_hash),
                   Vector{UInt8}(state_fingerprint), client, comment, collect(Op, ops))
    end
end

Base.:(==)(a::Record, b::Record) = all(isequal(getfield(a, f), getfield(b, f)) for f in fieldnames(Record))
Base.isequal(a::Record, b::Record) = a == b

"""
    wire(record) -> Dict{String,Any}

The record's wire form, ready for `CBOR.encode`: `prev_hash`, `comment`,
`client.host` and `client.user` are left out when absent, never spelt as null.
"""
function wire(r::Record)
    c = Dict{String,Any}("lib" => r.client.lib, "julia" => r.client.julia, "time_ms" => r.client.time_ms)
    r.client.host === nothing || (c["host"] = r.client.host)
    r.client.user === nothing || (c["user"] = r.client.user)
    w = Dict{String,Any}(
        "format_version" => FORMAT_VERSION, "chain_id" => r.chain_id, "slot" => r.slot,
        "state_fingerprint" => r.state_fingerprint, "client" => c,
        "ops" => Any[wire(op) for op in r.ops],
    )
    r.prev_hash === nothing || (w["prev_hash"] = r.prev_hash)
    r.comment === nothing || (w["comment"] = r.comment)
    return w
end

"""
    encode_record(record) -> Vector{UInt8}

The record's stored bytes: one deterministic-CBOR map (ADR-0006). Raises
`WriteBuilderError` with the byte count when the record is over the 64 MiB
cap; the next move is to split the write.
"""
function encode_record(r::Record)
    bytes = CBOR.encode(wire(r))
    length(bytes) <= MAX_RECORD_BYTES || throw(WriteBuilderError(
        "record is $(length(bytes)) bytes; the cap is $MAX_RECORD_BYTES bytes (64 MiB): split the write into more than one commit"))
    return bytes
end

"""
    transaction_hash(bytes) -> Vector{UInt8}

`SHA-256("chaintables/v1/txn" ‖ bytes)` over a record's stored bytes, exactly as
fetched (ADR-0006): never over a re-encoding.
"""
function transaction_hash(bytes::AbstractVector{UInt8})
    ctx = SHA.SHA256_CTX()
    SHA.update!(ctx, codeunits(TXN_SEPARATOR))
    SHA.update!(ctx, bytes)
    return SHA.digest!(ctx)
end

# The MalformedRecordError message (ADR-0020): what happened, the evidence in the
# text, and the one next move ADR-0025 allows.
function malformed(slot, chain_id, what; op = nothing)
    where = slot === nothing ? "at an unknown slot" : "at slot $slot"
    cid = chain_id === nothing ? nothing : ChainTables.chain_id_string(chain_id)
    evidence = cid === nothing ? "" : " (chain $cid)"
    return MalformedRecordError("malformed record $where: $what$evidence. " *
        "No client can apply it under format_version $FORMAT_VERSION: the committer had a bug, " *
        "the chain is dead beyond this slot; a new chain is the recovery (ADR-0025).";
        chain_id = cid, slot, op)
end

function envelope_field(w, name)
    haskey(w, name) || fail("record has no $(repr(name))")
    return w[name]
end

function envelope_bytes(w, name, n, what)
    x = envelope_field(w, name)
    x isa AbstractVector{UInt8} || fail("$name is not bytes")
    length(x) == n || fail("$name is $(length(x)) bytes; $what is $n")
    return x
end

function client_from_wire(c)
    c isa AbstractDict || fail("client is not a map")
    for k in keys(c)
        k in CLIENT_FIELDS || fail("unknown client field $(repr(k))")
    end
    text(name) = (haskey(c, name) || fail("client has no $(repr(name))"); x = c[name];
                  x isa String || fail("client.$name is not text"); x)
    opt(name) = haskey(c, name) ? text(name) : nothing
    haskey(c, "time_ms") || fail("client has no \"time_ms\"")
    c["time_ms"] isa Int64 || fail("client.time_ms is not an integer")
    return Client(opt("host"), opt("user"), text("lib"), text("julia"), c["time_ms"])
end

"""
    decode_record(bytes; slot = nothing) -> Record

Read a record's stored bytes under the rejecting decoder and the envelope rules
(ADR-0006): unknown envelope or client field, `format_version` above
[`FORMAT_VERSION`](@ref), a missing or mis-shaped field, trailing bytes, a
record over the cap, or an op that is not one of the seven. Pass `slot` — the
slot the bytes were fetched from — and the record must name it (ADR-0002).
Every violation is a `MalformedRecordError` naming the slot; the cells of an op
are checked at [`apply!`](@ref), where the shape is known.
"""
function decode_record(bytes::AbstractVector{UInt8}; slot = nothing)
    length(bytes) <= MAX_RECORD_BYTES ||
        throw(malformed(slot, nothing, "record is $(length(bytes)) bytes; the cap is $MAX_RECORD_BYTES bytes (64 MiB)"))
    w = try
        CBOR.decode(bytes)
    catch e
        e isa CBOR.DecodeError || rethrow()
        throw(malformed(slot, nothing, "not deterministic CBOR (byte $(e.offset): $(e.msg))"))
    end
    w isa AbstractDict || throw(malformed(slot, nothing, "record is not a map, got a value of type $(typeof(w))"))
    # the evidence for the message, if the envelope carries it in readable form
    chain_id = get(w, "chain_id", nothing)
    chain_id isa AbstractVector{UInt8} && length(chain_id) == 16 || (chain_id = nothing)
    slot === nothing && get(w, "slot", nothing) isa Int64 && (slot = w["slot"])
    try
        return record_from_wire(w, slot)
    catch e
        e isa ModelError || rethrow()
        throw(malformed(slot, chain_id, e.msg))
    end
end

function record_from_wire(w, slot)
    for k in keys(w)
        k in ENVELOPE_FIELDS || fail("unknown envelope field $(repr(k)); every format addition is a format_version bump")
    end
    v = envelope_field(w, "format_version")
    v isa Int64 || fail("format_version is not an integer")
    v > FORMAT_VERSION && fail("format_version $v is above this client's maximum, $FORMAT_VERSION; a newer client wrote it: upgrade ChainTables")
    v == FORMAT_VERSION || fail("format_version $v is not a version this client reads")
    s = envelope_field(w, "slot")
    s isa Int64 || fail("slot is not an integer")
    slot === nothing || s == slot || fail("the record names slot $s")
    chain_id = envelope_bytes(w, "chain_id", 16, "a chain id")
    prev = haskey(w, "prev_hash") ? envelope_bytes(w, "prev_hash", 32, "a SHA-256") : nothing
    fp = envelope_bytes(w, "state_fingerprint", 32, "a SHA-256")
    client = client_from_wire(envelope_field(w, "client"))
    comment = get(w, "comment", nothing)
    comment === nothing || comment isa String || fail("comment is not text")
    ops_w = envelope_field(w, "ops")
    ops_w isa AbstractVector || fail("ops is not an array")
    ops = Op[]
    for (i, ow) in enumerate(ops_w)
        try
            push!(ops, op_from_wire(ow))
        catch e
            e isa ModelError || rethrow()
            fail("op $i: $(e.msg)")
        end
    end
    return Record(chain_id, s, prev, fp, client, comment, ops)
end

# ---------------------------------------------------------------------------
# Apply (ADR-0025, ADR-0022): the model's primitives, re-validating every op
# ---------------------------------------------------------------------------

"""
    sort_rows(rows, keyof) -> Vector

`rows` sorted by the typed key order — `isless` on the tuple `keyof(row)`
(ADR-0025). The builder's canonicalisation; apply never sorts, it checks. A
duplicate key is not an error here: apply and the builder refuse it.
"""
sort_rows(rows, keyof) = sort(collect(rows); by = keyof)

# Strictly increasing under the typed key order, or the rule broken: the
# canonical form of an op's rows (ADR-0025).
function check_key_order(keys)
    prev = nothing
    started = false
    for k in keys
        if started
            isequal(prev, k) && fail("duplicate key $(repr(k)) inside one op")
            isless(prev, k) || fail("rows are not in primary-key order: $(repr(k)) after $(repr(prev))")
        end
        prev = k
        started = true
    end
    return nothing
end

nkey(t::Model.Table) = length(t.shape.keyidx)
keyed(t::Model.Table, rows) = (Tuple(r[1:min(end, nkey(t))]) for r in rows)

"""
    apply!(content, op::Op) -> nothing
    apply!(content, record::Record) -> nothing

Apply one op, or every op of a record in order, to a `Model.Content`. Every
structural check the write builder runs is run here through the model's own
primitives (ADR-0025): value type and nullability against the shape, every
column named by an insert, known table and column, a non-key column for
`drop_column`, no duplicate key inside an op, rows in typed key order, update
columns in declaration order, and the state gate of ADR-0001. Apply never
computes and never sorts.

The op form raises `Model.ModelError` for the builder to fold into
`WriteBuilderError`; the record form folds it into `MalformedRecordError`
naming the slot, the op index and the rule (ADR-0020), and applies nothing
after the op that failed — the content is then partially applied and the
caller discards it; the local copy's files are untouched (ADR-0013).
"""
function apply!(c::Content, op::CreateTable)
    Model.create_table!(c, op.table, op.shape)
    return nothing
end
function apply!(c::Content, op::AddColumn)
    Model.add_column!(Model.table(c, op.table), op.column, op.fill)
    return nothing
end
function apply!(c::Content, op::DropColumn)
    Model.drop_column!(Model.table(c, op.table), op.column)
    return nothing
end
function apply!(c::Content, op::DropTable)
    Model.drop_table!(c, op.table)
    return nothing
end
function apply!(c::Content, op::Insert)
    t = Model.table(c, op.table)
    for row in op.rows
        Model.check_row(t.shape, row)
    end
    check_key_order(Model.key_of(t.shape, row) for row in op.rows)
    Model.insert_rows!(t, op.rows)
    return nothing
end
function apply!(c::Content, op::Update)
    t = Model.table(c, op.table)
    idx = [Model.column_index(t.shape, n) for n in op.columns]
    issorted(idx; lt = <) || fail("update columns are not in declaration order: $(repr(op.columns))")
    check_key_order(keyed(t, op.rows))
    Model.update_rows!(t, op.columns, op.rows)
    return nothing
end
function apply!(c::Content, op::Delete)
    t = Model.table(c, op.table)
    check_key_order(keyed(t, op.keys))
    Model.delete_rows!(t, op.keys)
    return nothing
end

function apply!(c::Content, r::Record)
    for (i, op) in enumerate(r.ops)
        try
            apply!(c, op)
        catch e
            e isa ModelError || rethrow()
            throw(malformed(r.slot, r.chain_id, "op $i ($(op_name(op)) on $(repr(op.table))): $(e.msg)"; op = i))
        end
    end
    return nothing
end

end # module Ops
