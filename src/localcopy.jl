# #34 step 5 — ADR-0023, ADR-0009, ADR-0013, ADR-0019, ADR-0020: table files, the
# head file, open and its checks, sweep, lazy load with hash-before-use,
# checkpoints. Steps 7 and 8 add sync!/commit! and verify/repair!/as_of/views here.
#
# `ChainTables.open` is defined in this file, so inside the module a bare `open`
# is ChainTables.open: every file below is opened with `Base.open`.

import SHA
using .Model: Content, ModelError
using .Ops: Record

"""
    LAYOUT_VERSION

Which arrangement of head file and table files this client writes and reads, `1`
(ADR-0023). Purely local, never a property of the chain; a head carrying any
other value is refused with `LayoutVersionError` — rebuild, never migrate.
"""
const LAYOUT_VERSION = 1

"""
    HEAD_SEPARATOR

The head file's magic, `"chaintables/v1/head"` (ADR-0023, ADR-0026): the bytes
before the head's CBOR map, naming the layout before anything is decoded.
"""
const HEAD_SEPARATOR = "chaintables/v1/head"

const HEAD_FIELDS = ("layout_version", "chain_id", "format_version", "slot", "transaction_hash",
                     "state_fingerprint", "tables", "written_at_ms", "written_by")
const WRITTEN_BY_FIELDS = ("lib", "julia")

# ---------------------------------------------------------------------------
# The chain id as text (ADR-0011, ADR-0019): 128 bits rendered base32, 26
# characters, no padding, no case to lose. Records carry the 16 bytes; the head
# file and every message carry this.
# ---------------------------------------------------------------------------

const BASE32_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"

"""
    chain_id_string(bytes) -> String

The 16-byte chain id a record carries, as the 26-character base32 name humans
read in messages and the head file stores (ADR-0011, ADR-0023).
[`chain_id_bytes`](@ref) is its inverse.
"""
function chain_id_string(bytes::AbstractVector{UInt8})
    length(bytes) == 16 || throw(ArgumentError("a chain id is 16 bytes, got $(length(bytes))"))
    out = IOBuffer()
    acc = UInt64(0)
    nbits = 0
    for b in bytes
        acc = (acc << 8) | b
        nbits += 8
        while nbits >= 5
            nbits -= 5
            write(out, BASE32_ALPHABET[Int((acc >> nbits) & 0x1f)+1])
            acc &= (UInt64(1) << nbits) - 1
        end
    end
    # 128 = 25 × 5 + 3: the last three bits are left-aligned in a 26th character
    write(out, BASE32_ALPHABET[Int((acc << (5 - nbits)) & 0x1f)+1])
    return String(take!(out))
end

"""
    chain_id_bytes(s) -> Vector{UInt8}

The 16 bytes of a chain id spelt as [`chain_id_string`](@ref) spells it. Case is
ignored; anything but 26 base32 characters with zero trailing bits is refused.
"""
function chain_id_bytes(s::AbstractString)
    length(s) == 26 || throw(ArgumentError("a chain id is 26 base32 characters, got $(repr(s))"))
    out = UInt8[]
    acc = UInt64(0)
    nbits = 0
    for c in uppercase(s)
        v = findfirst(==(c), BASE32_ALPHABET)
        v === nothing && throw(ArgumentError("$(repr(c)) in $(repr(s)) is not a base32 character (A–Z, 2–7)"))
        acc = (acc << 5) | UInt64(v - 1)
        nbits += 5
        if nbits >= 8
            nbits -= 8
            push!(out, UInt8((acc >> nbits) & 0xff))
            acc &= (UInt64(1) << nbits) - 1
        end
    end
    acc == 0 || throw(ArgumentError("$(repr(s)) is not a chain id: its trailing bits are not zero"))
    return out
end

# ---------------------------------------------------------------------------
# The head file (ADR-0023)
# ---------------------------------------------------------------------------

"""
    Head

One head file as values (ADR-0023): which transaction record the local copy's
content is the result of, and which table file holds each table.

- `chain_id`, base32 text — binds the copy to its chain;
- `format_version`, the record format the head's record was read under;
- `slot`, `transaction_hash` (hash of that slot's stored bytes) and
  `state_fingerprint`, which equals the record's field and is ADR-0007's outer
  hash over `tables`, stored so `open` can check the head against itself;
- `tables`, `name => table_hash` pairs sorted by name — the only place that says
  which file is which table;
- `written_at_ms` and `written_by = (; lib, julia)`, advisory, never checked.

Not in the head: the pin, bucket and prefix (ADR-0023). [`encode_head`](@ref)
and [`decode_head`](@ref) are the file form; [`check_head`](@ref) is
self-consistency.
"""
struct Head
    chain_id::String
    format_version::Int64
    slot::Int64
    transaction_hash::Vector{UInt8}
    state_fingerprint::Vector{UInt8}
    tables::Vector{Pair{String,Vector{UInt8}}}
    written_at_ms::Int64
    written_by::NamedTuple{(:lib, :julia),Tuple{String,String}}
end

Base.:(==)(a::Head, b::Head) = all(getfield(a, f) == getfield(b, f) for f in fieldnames(Head))
Base.isequal(a::Head, b::Head) = a == b

"""
    head_filename(slot) -> String

The head file's name: the slot, twelve digits, zero-padded (ADR-0023).
"""
head_filename(slot::Integer) = lpad(string(slot), 12, '0')

const HEAD_NAME = r"^[0-9]{12}$"
const TABLE_NAME = r"^[0-9a-f]{64}$"

written_by_here() = (; lib = "ChainTables $(pkgversion(@__MODULE__))", julia = string(VERSION))

"""
    check_head(head) -> nothing

The head is self-consistent (ADR-0023): every hash 32 bytes, `tables` sorted by
name without a duplicate, and `state_fingerprint` equal to the fingerprint of
`tables`. Raises `ArgumentError` with the reason; the callers turn that into
`LocalCopyInconsistentError` naming the file.
"""
function check_head(h::Head)
    h.slot >= 0 || throw(ArgumentError("slot $(h.slot) is negative"))
    length(h.transaction_hash) == 32 || throw(ArgumentError("transaction_hash is $(length(h.transaction_hash)) bytes; a SHA-256 is 32"))
    length(h.state_fingerprint) == 32 || throw(ArgumentError("state_fingerprint is $(length(h.state_fingerprint)) bytes; a SHA-256 is 32"))
    names = first.(h.tables)
    issorted(names; lt = isless) || throw(ArgumentError("tables are not sorted by name: $(repr(names))"))
    fp = try
        Model.state_fingerprint(h.tables)    # 32-byte hashes, no duplicate name
    catch e
        e isa ModelError || rethrow()
        throw(ArgumentError(e.msg))
    end
    fp == h.state_fingerprint || throw(ArgumentError(
        "its state_fingerprint is $(bytes2hex(h.state_fingerprint)), the fingerprint of its tables list is $(bytes2hex(fp))"))
    return nothing
end

"""
    encode_head(head) -> Vector{UInt8}

The head file's bytes: [`HEAD_SEPARATOR`](@ref), then one CBOR map through the
frozen encoder, keys in the encoder's bytewise order (ADR-0023).
"""
function encode_head(h::Head)
    w = Dict{String,Any}(
        "layout_version" => LAYOUT_VERSION, "chain_id" => h.chain_id, "format_version" => h.format_version,
        "slot" => h.slot, "transaction_hash" => h.transaction_hash, "state_fingerprint" => h.state_fingerprint,
        "tables" => Any[Any[name, hash] for (name, hash) in h.tables],
        "written_at_ms" => h.written_at_ms,
        "written_by" => Dict{String,Any}("lib" => h.written_by.lib, "julia" => h.written_by.julia),
    )
    return vcat(codeunits(HEAD_SEPARATOR), CBOR.encode(w))
end

# The reasons a head file cannot be read, kept apart because they are different
# actions (ADR-0020): a foreign file, a newer client's layout, a damaged head.
struct HeadRejected <: Exception
    kind::Symbol       # :not_ours, :layout, :damaged
    msg::String
end
reject_head(kind, msg) = throw(HeadRejected(kind, msg))

head_field(w, name) = haskey(w, name) ? w[name] : reject_head(:damaged, "has no $(repr(name))")
function head_int(w, name)
    v = head_field(w, name)
    v isa Int64 || reject_head(:damaged, "$name is not an integer")
    return v
end
function head_bytes(w, name)
    v = head_field(w, name)
    v isa Vector{UInt8} || reject_head(:damaged, "$name is not bytes")
    return v
end
function head_text(w, name)
    v = head_field(w, name)
    v isa String || reject_head(:damaged, "$name is not text")
    return v
end

# "chaintables/v<digits>/head" at the start of the bytes, or nothing: another
# layout version's magic is told apart from a file that is not ours at all.
function other_layout_magic(bytes)
    lead = codeunits("chaintables/v")
    tail = codeunits("/head")
    n = length(bytes)
    (n >= length(lead) && bytes[1:length(lead)] == lead) || return nothing
    i = length(lead) + 1
    while i <= n && 0x30 <= bytes[i] <= 0x39
        i += 1
    end
    i > length(lead) + 1 || return nothing
    stop = i - 1 + length(tail)
    (stop <= n && bytes[i:stop] == tail) || return nothing
    return String(bytes[1:stop])
end

"""
    decode_head(bytes) -> Head

Read one head file as [`encode_head`](@ref) wrote it, then [`check_head`](@ref).
Refuses a file that does not begin with [`HEAD_SEPARATOR`](@ref) (another
layout version's magic, or not ours at all), a `layout_version` other than
[`LAYOUT_VERSION`](@ref), a record `format_version` above this client's, an
unknown or mis-typed field, malformed CBOR, and a head that is not
self-consistent. The reason is raised as an internal `HeadRejected`; `open`
turns it into the `LayoutVersionError`, `NotALocalCopyError` or
`LocalCopyInconsistentError` it is, naming the file.
"""
function decode_head(bytes::AbstractVector{UInt8})
    sep = codeunits(HEAD_SEPARATOR)
    if length(bytes) < length(sep) || bytes[1:length(sep)] != sep
        magic = other_layout_magic(bytes)
        magic === nothing && reject_head(:not_ours, "is not a ChainTables head file")
        reject_head(:layout, "begins $(repr(magic)), not $(repr(HEAD_SEPARATOR))")
    end
    w = try
        CBOR.decode(bytes[length(sep)+1:end])
    catch e
        e isa CBOR.DecodeError || rethrow()
        reject_head(:damaged, "cannot be decoded: $(e.msg) at byte $(length(sep) + e.offset)")
    end
    w isa AbstractDict || reject_head(:damaged, "is not a map")
    for k in keys(w)
        k in HEAD_FIELDS || reject_head(:damaged, "unknown head field $(repr(k))")
    end
    lv = head_int(w, "layout_version")
    lv == LAYOUT_VERSION || reject_head(:layout, "layout version $lv of")
    fv = head_int(w, "format_version")
    fv > Ops.FORMAT_VERSION && reject_head(:layout, "format_version $fv of")
    fv >= 1 || reject_head(:damaged, "format_version $fv is not a version this client reads")
    chain_id = head_text(w, "chain_id")
    try
        chain_id_bytes(chain_id)
    catch e
        e isa ArgumentError || rethrow()
        reject_head(:damaged, "chain_id $(repr(chain_id)) is not a chain id")
    end
    slot = head_int(w, "slot")
    th = head_bytes(w, "transaction_hash")
    fp = head_bytes(w, "state_fingerprint")
    tl = head_field(w, "tables")
    tl isa AbstractVector || reject_head(:damaged, "tables is not an array")
    tables = Pair{String,Vector{UInt8}}[]
    for e in tl
        e isa AbstractVector && length(e) == 2 && e[1] isa String && e[2] isa Vector{UInt8} ||
            reject_head(:damaged, "tables entry $(repr(e)) is not [name, hash]")
        push!(tables, e[1] => e[2])
    end
    at = head_int(w, "written_at_ms")
    by = head_field(w, "written_by")
    by isa AbstractDict || reject_head(:damaged, "written_by is not a map")
    for k in keys(by)
        k in WRITTEN_BY_FIELDS || reject_head(:damaged, "unknown written_by field $(repr(k))")
    end
    h = Head(chain_id, fv, slot, th, fp, tables, at, (; lib = head_text(by, "lib"), julia = head_text(by, "julia")))
    try
        check_head(h)
    catch e
        e isa ArgumentError || rethrow()
        reject_head(:damaged, "is not self-consistent: $(e.msg)")
    end
    return h
end

# ---------------------------------------------------------------------------
# LocalCopy (ADR-0019, ADR-0023)
# ---------------------------------------------------------------------------

"""
    LocalCopy

One open local copy bound to a chain (ADR-0019, ADR-0023): the directory
`path` with `heads/`, `tables/` and, when pinned, `pin`; the `head` chosen at
open or written by the last checkpoint (`nothing` while the copy is fresh and
unbound); and the model, loaded lazily — `tables` is the head's `name =>
table_hash` list, `content` holds every table read from its file or created
since the last head, and `loaded` the names read from a file, so a name in
`loaded` and no longer in `content` was dropped. A handle: `Base.close`
drops the model and every later call raises.

Taken with [`open`](@ref); advanced by `sync!` and `commit!` (#34 step 7)
through [`load_tables!`](@ref), [`stage!`](@ref), [`write_head!`](@ref),
[`discard!`](@ref) and [`checkpoint!`](@ref). The chain is any value:
`open` reads nothing from it but [`expected_chain_id`](@ref).

Tables load one whole table on first touch and stay resident until close;
ADR-0023's ceiling is 1 GB per table file on disk, so that a resident table
stays within a few GB. v1 documents one process and one thread per local copy
and implements no locking (ADR-0019).
"""
mutable struct LocalCopy{C}
    chain::C
    path::String
    head::Union{Nothing,Head}
    tables::Dict{String,Vector{UInt8}}
    content::Content
    loaded::Set{String}
    closed::Bool
end

heads_dir(copy::LocalCopy) = joinpath(copy.path, "heads")
tables_dir(copy::LocalCopy) = joinpath(copy.path, "tables")
head_path(copy::LocalCopy, slot) = joinpath(heads_dir(copy), head_filename(slot))
table_path(copy::LocalCopy, hash::AbstractVector{UInt8}) = joinpath(tables_dir(copy), bytes2hex(hash))

function check_open(copy::LocalCopy)
    copy.closed && throw(ArgumentError("the local copy at $(copy.path) is closed; open(chain, path) again"))
    return nothing
end

"""
    expected_chain_id(chain) -> String or nothing

The chain id `open(chain, path)` checks a bound copy's head against, as base32
text, or `nothing` when the chain does not know its id yet — then nothing is
checked at open and the binding is checked by the first `sync!` against the
records it fetches (#34 step 7). The fallback for any chain is `nothing`; the
`Chain` method is step 7's.
"""
expected_chain_id(chain) = nothing

"""
    open(chain, path) -> LocalCopy

Open the local copy at `path` for `chain` (ADR-0019, ADR-0023). No network I/O,
no replay, nothing hashed. An absent or empty directory is created fresh and
unbound (`heads/` and `tables/` inside it); a non-empty directory without both
is not a local copy — `NotALocalCopyError`. With heads present, the highest head
that is self-consistent and whose named files all exist is chosen, else the
next lower one (the crash window leaves at most two; the fall-back is warned),
else `LocalCopyInconsistentError`. Its `chain_id` is checked against
[`expected_chain_id`](@ref)`(chain)` when that is known — `WrongChainError` —
and its layout and format versions against this client's — `LayoutVersionError`.
Then the sweep: every other head, every table file the head does not name, and
every `.tmp` are deleted.

Qualified by design: `ChainTables.open` reads as documentation at every call
site, and `Base.open` is not extended.
"""
function open(chain, path::AbstractString)
    path = abspath(path)
    heads = joinpath(path, "heads")
    tables = joinpath(path, "tables")
    if ispath(path) && !isdir(path)
        throw(NotALocalCopyError("not a local copy: $path exists and is not a directory. Open a directory path."; path))
    elseif !isdir(path) || isempty(readdir(path))
        mkpath(heads)
        mkpath(tables)
    elseif !(isdir(heads) && isdir(tables))
        throw(NotALocalCopyError("not a local copy: $path is a non-empty directory without heads/ and tables/. " *
            "Open a different path, or empty this one if it is disposable."; path))
    end
    copy = LocalCopy{typeof(chain)}(chain, path, nothing, Dict{String,Vector{UInt8}}(), Content(), Set{String}(), false)
    copy.head = choose_head(copy, expected_chain_id(chain))
    copy.tables = copy.head === nothing ? Dict{String,Vector{UInt8}}() : Dict(copy.head.tables)
    sweep!(copy)
    return copy
end

# The head at open (ADR-0023): candidates in descending slot order; a foreign
# file, a newer layout and a foreign chain raise at once, damage and a missing
# file fall through to the next lower head, and no usable head is a hard error.
function choose_head(copy::LocalCopy, expected)
    names = sort!(filter(f -> occursin(HEAD_NAME, f), readdir(heads_dir(copy))); rev = true)
    reasons = String[]
    for (i, name) in enumerate(names)
        file = "heads/$name"
        h = try
            decode_head(read(joinpath(heads_dir(copy), name)))
        catch e
            e isa HeadRejected || rethrow()
            e.kind === :not_ours && throw(NotALocalCopyError("not a local copy: head $file of $(copy.path) $(e.msg). " *
                "Open a different path."; path = copy.path))
            e.kind === :layout && throw(LayoutVersionError(layout_message(copy, file, e.msg); path = copy.path, file))
            push!(reasons, "head $file $(e.msg)")
            continue
        end
        slot = parse(Int64, name)
        if h.slot != slot
            push!(reasons, "head $file is named for slot $slot but says slot $(h.slot)")
            continue
        end
        if expected !== nothing && h.chain_id != expected
            throw(WrongChainError("wrong chain: the local copy at $(copy.path) is bound to chain $(h.chain_id) (head slot $(h.slot)), " *
                "the chain being opened is $expected: open a different path for this chain.";
                path = copy.path, bound = h.chain_id, opened = String(expected)))
        end
        missing_file = findfirst(p -> !isfile(table_path(copy, last(p))), h.tables)
        if missing_file !== nothing
            tname, thash = h.tables[missing_file]
            push!(reasons, "head $file names table file tables/$(bytes2hex(thash)) (table $(repr(tname))), which is missing")
            continue
        end
        i == 1 || @warn "$(last(reasons)); opening the local copy at $(copy.path) at slot $(h.slot) and sweeping heads/$(names[1])"
        return h
    end
    isempty(names) && return nothing
    throw(LocalCopyInconsistentError("damaged copy: no head of the local copy at $(copy.path) can be opened — " *
        join(reasons, "; ") * ". No readable head cannot be repaired: delete the directory and sync!(copy) again.";
        path = copy.path, file = "heads/$(names[1])"))
end

function layout_message(copy::LocalCopy, file, what)
    if startswith(what, "layout version")
        return "$what head $file is not this client's, $LAYOUT_VERSION: a newer client wrote the local copy at $(copy.path). " *
               "Delete the directory and sync!(copy) again, or upgrade ChainTables."
    elseif startswith(what, "format_version")
        return "$what head $file is above this client's maximum, $(Ops.FORMAT_VERSION): a newer client wrote the local copy " *
               "at $(copy.path). Delete the directory and sync!(copy) again, or upgrade ChainTables."
    else
        return "head $file $what: another layout version wrote the local copy at $(copy.path). " *
               "Delete the directory and sync!(copy) again, or upgrade ChainTables."
    end
end

"""
    sweep!(copy) -> nothing

Delete every head but the copy's, every table file its head does not name, and
every `.tmp` in `heads/` and `tables/` (ADR-0023). Silent: everything deleted is
derived. Runs at open after the head is chosen and after every head write.
"""
function sweep!(copy::LocalCopy)
    keep = copy.head === nothing ? nothing : head_filename(copy.head.slot)
    for f in readdir(heads_dir(copy))
        (endswith(f, ".tmp") || (occursin(HEAD_NAME, f) && f != keep)) && rm(joinpath(heads_dir(copy), f); force = true)
    end
    named = Set(bytes2hex(h) for h in values(copy.tables))
    for f in readdir(tables_dir(copy))
        (endswith(f, ".tmp") || (occursin(TABLE_NAME, f) && f ∉ named)) && rm(joinpath(tables_dir(copy), f); force = true)
    end
    return nothing
end

"""
    close(copy) -> nothing

Drop the model; every later call on the copy raises (ADR-0019). Deleting a
temporary `as_of` copy's directory is #34 step 8's.
"""
function Base.close(copy::LocalCopy)
    copy.closed = true
    empty!(copy.content)
    empty!(copy.loaded)
    return nothing
end

"""
    ispinned(copy) -> Bool

Whether the `pin` file exists: `as_of` creates it, `unpin!` deletes it, `sync!`
and `commit!` refuse while it exists (ADR-0015, ADR-0023).
"""
ispinned(copy::LocalCopy) = isfile(joinpath(copy.path, "pin"))

"""
    head(copy) -> (; slot, transaction_hash, state_fingerprint)

The head the copy is at (ADR-0024). Raises while the copy is fresh and unbound.
"""
function head(copy::LocalCopy)
    check_open(copy)
    h = copy.head
    h === nothing && throw(ArgumentError("the local copy at $(copy.path) has no head yet; sync!(copy) binds it"))
    return (; slot = h.slot, transaction_hash = h.transaction_hash, state_fingerprint = h.state_fingerprint)
end

"""
    tables(copy) -> Vector{String}

The sorted names of every table in the model as it stands: the head's tables
less those dropped since, plus those created since (ADR-0024).
"""
function tables(copy::LocalCopy)
    check_open(copy)
    names = Set(keys(copy.content))
    for name in keys(copy.tables)
        name in copy.loaded || push!(names, name)
    end
    return sort!(collect(names))
end

# ---------------------------------------------------------------------------
# Lazy load with hash-before-use (ADR-0023, ADR-0013)
# ---------------------------------------------------------------------------

function hash_file(file::AbstractString)
    ctx = SHA.SHA256_CTX()
    buf = Vector{UInt8}(undef, 1 << 20)
    Base.open(file) do io
        while !eof(io)
            n = readbytes!(io, buf)
            SHA.update!(ctx, view(buf, 1:n))
        end
    end
    return SHA.digest!(ctx)
end

function damaged(copy::LocalCopy, name, hash, what)
    h = copy.head
    return LocalCopyInconsistentError("damaged copy: table file tables/$(bytes2hex(hash)) (table $(repr(name)) at slot $(h.slot), " *
        "chain $(h.chain_id)) $what. repair!(copy) rewrites it from the record cache.";
        path = copy.path, slot = h.slot, file = "tables/$(bytes2hex(hash))")
end

"""
    load_table!(copy, name) -> Model.Table

The table `name`, read whole from its file on first touch and resident until
close (ADR-0023). The file is hashed and the hash compared with its name before
any byte of it reaches the model; a mismatch, or a file that hashes to its name
but is not a canonical table file, is a damaged copy —
`LocalCopyInconsistentError` naming `repair!(copy)`. An unknown name raises
`Model.ModelError`.
"""
function load_table!(copy::LocalCopy, name::AbstractString)
    check_open(copy)
    haskey(copy.content, name) && return copy.content[name]
    (haskey(copy.tables, name) && name ∉ copy.loaded) || Model.fail("unknown table $(repr(name))")
    hash = copy.tables[name]
    file = table_path(copy, hash)
    isfile(file) || throw(damaged(copy, name, hash, "is missing"))
    got = hash_file(file)
    got == hash || throw(damaged(copy, name, hash, "hashes to $(bytes2hex(got)): its bytes are not the content the head names"))
    t = try
        Base.open(Model.read_table, file)
    catch e
        e isa ModelError || e isa CBOR.DecodeError || rethrow()
        throw(damaged(copy, name, hash, "hashes to its name but is not a canonical table file ($(sprint(showerror, e)))"))
    end
    copy.content[name] = t
    push!(copy.loaded, name)
    return t
end

"""
    load_tables!(copy, names) -> nothing
    load_tables!(copy, record) -> nothing

[`load_table!`](@ref) every name the head has among `names`, or among the
tables a record's ops name; names the head does not have are skipped. Apply
runs on `copy.content` and sees only what is loaded, so every table a record
names is loaded first — including for `create_table`, so that a name the head
already has is refused as it should be.
"""
function load_tables!(copy::LocalCopy, names)
    check_open(copy)
    for name in names
        haskey(copy.tables, name) && name ∉ copy.loaded && load_table!(copy, name)
    end
    return nothing
end
load_tables!(copy::LocalCopy, r::Record) = load_tables!(copy, unique(op.table for op in r.ops))

# ---------------------------------------------------------------------------
# Checkpoints and the commit sequence's halves (ADR-0013, ADR-0009, ADR-0023)
# ---------------------------------------------------------------------------

# Every file is written to a .tmp in its directory and renamed into place; a
# table file's name is only known once it is hashed, so its .tmp is random.
function write_table_file!(copy::LocalCopy, t::Model.Table)
    dir = tables_dir(copy)
    tmp = joinpath(dir, bytes2hex(rand(UInt8, 8)) * ".tmp")
    hash = Base.open(io -> Model.write_table(io, t), tmp, "w")
    target = joinpath(dir, bytes2hex(hash))
    if isfile(target)                       # an existing name is skipped (ADR-0009)
        rm(tmp; force = true)
    else
        mv(tmp, target; force = true)
    end
    return hash
end

"""
    stage!(copy) -> (; tables, state_fingerprint)

Write the touched tables' files — every table in `copy.content` — skipping a
name that already exists, and return the `name => table_hash` list the next
head would carry (untouched tables keep the head's hash, unread) with its
fingerprint, free (ADR-0009, ADR-0023). Nothing else changes: until
[`write_head!`](@ref) names them the new files are orphans, and
[`discard!`](@ref) sweeps them.
"""
function stage!(copy::LocalCopy)
    check_open(copy)
    entries = Pair{String,Vector{UInt8}}[]
    for (name, hash) in copy.tables
        name in copy.loaded || haskey(copy.content, name) || push!(entries, name => hash)
    end
    for (name, t) in copy.content
        push!(entries, name => write_table_file!(copy, t))
    end
    sort!(entries; by = first)
    return (; tables = entries, state_fingerprint = Model.state_fingerprint(entries))
end

function check_advance(copy::LocalCopy, chain_id, slot)
    h = copy.head
    if h !== nothing
        slot > h.slot || throw(ArgumentError("slot $slot is not above the head's slot $(h.slot); a head is write-once and the slot advances"))
        chain_id == h.chain_id || throw(ArgumentError("the local copy at $(copy.path) is bound to chain $(h.chain_id); a head for chain $chain_id cannot be written into it"))
    end
    return nothing
end

"""
    write_head!(copy, chain_id, slot, transaction_hash, staged) -> nothing

The local commit point (ADR-0009, ADR-0023): write the head file for `slot`
naming `staged.tables` — after every file it names, to `.tmp` then renamed —
then sweep. `chain_id` is the record's 16 bytes; `staged` is [`stage!`](@ref)'s
result. The slot must advance and the chain id must not change. Afterwards
every table in `copy.content` is a loaded table of the new head.
"""
function write_head!(copy::LocalCopy, chain_id::AbstractVector{UInt8}, slot::Integer, transaction_hash::AbstractVector{UInt8}, staged)
    check_open(copy)
    cid = chain_id_string(chain_id)
    check_advance(copy, cid, slot)
    h = Head(cid, Ops.FORMAT_VERSION, slot, Vector{UInt8}(transaction_hash), staged.state_fingerprint,
             staged.tables, round(Int64, time() * 1000), written_by_here())
    check_head(h)
    target = head_path(copy, slot)
    tmp = target * ".tmp"
    write(tmp, encode_head(h))
    mv(tmp, target; force = true)
    copy.head = h
    copy.tables = Dict(h.tables)
    copy.loaded = Set(keys(copy.content))
    sweep!(copy)
    return nothing
end

"""
    discard!(copy) -> nothing

Drop the model and sweep, leaving the copy at its head (ADR-0009): after a
`412`, a lost race or a failed apply, the touched tables reload from the head's
files on next touch and the staged files are gone.
"""
function discard!(copy::LocalCopy)
    check_open(copy)
    empty!(copy.content)
    empty!(copy.loaded)
    sweep!(copy)
    return nothing
end

"""
    checkpoint!(copy, chain_id, slot, transaction_hash, state_fingerprint; client = nothing) -> nothing

One checkpoint of a replay (ADR-0013, ADR-0023): [`stage!`](@ref), compare the
fingerprint with `state_fingerprint` — the record's — and [`write_head!`](@ref).
Every checkpoint is verified. A mismatch is divergence, or an apply bug, never
damage (a content-addressed head cannot be self-consistent and wrong): the
model is dropped ([`discard!`](@ref)), the copy stays at its last checkpoint,
and `FingerprintMismatchError` names the slot, both fingerprints, the record's
`client.lib` and `client.julia` when `client` is given against this machine's,
and `repair!(copy)` as the confirming step (ADR-0020, ADR-0023).
"""
function checkpoint!(copy::LocalCopy, chain_id::AbstractVector{UInt8}, slot::Integer, transaction_hash::AbstractVector{UInt8},
                     state_fingerprint::AbstractVector{UInt8}; client = nothing)
    check_open(copy)
    check_advance(copy, chain_id_string(chain_id), slot)
    staged = stage!(copy)
    if staged.state_fingerprint != state_fingerprint
        at = copy.head === nothing ? "with no head (fresh and unbound)" : "at slot $(copy.head.slot), its last checkpoint"
        here = written_by_here()
        by = client === nothing ? "" : "The record was written by $(client.lib) on Julia $(client.julia); "
        discard!(copy)
        throw(FingerprintMismatchError("state fingerprint mismatch at slot $slot (chain $(chain_id_string(chain_id))): " *
            "the record's state_fingerprint is $(bytes2hex(state_fingerprint)), this client computed " *
            "$(bytes2hex(staged.state_fingerprint)) after applying it. " *
            "$(by)this client is $(here.lib) on Julia $(here.julia). The local copy stays $at. " *
            "This machine's replay diverges from the chain, or apply has a bug: repair!(copy) confirms it — " *
            "a fresh replay that also mismatches proves this machine cannot reproduce the chain.";
            chain_id = chain_id_string(chain_id), slot = Int64(slot), expected = Vector{UInt8}(state_fingerprint),
            computed = staged.state_fingerprint,
            record_client = client === nothing ? nothing : (; lib = client.lib, julia = client.julia), this_client = here))
    end
    write_head!(copy, chain_id, slot, transaction_hash, staged)
    return nothing
end
