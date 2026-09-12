# #34 step 1 — ADR-0006, ADR-0022: frozen RFC 8949 §4.2.1 encoder and rejecting decoder, streaming.

"""
    CBOR

The frozen encoder and the rejecting decoder for the format (ADR-0006, ADR-0022,
ADR-0025). Every stored byte the package hashes — a transaction record, a table
file — passes through `encode`, and every byte it reads passes through `decode`.
The encoder is **frozen for the life of the format**: a change to its output is
a chain break. Nothing here is exported (ADR-0019); call `CBOR.encode` and
`CBOR.decode`.

# The profile

RFC 8949 §4.2.1 core deterministic encoding — shortest-form integer heads,
preferred (shortest exact) float representation, definite lengths, map keys
sorted bytewise on their encoded form — pinned further by ADR-0006 and
ADR-0025:

- Integers are the `int64` domain: major types 0 and 1, never wider than
  `Int64`. `Int32` and friends widen; `Bool` is a CBOR bool, never an integer.
- Floats are IEEE binary64, shortened to the smallest of float16/32/64 that
  round-trips **bitwise** (`===`, so `-0.0` never shortens to `+0.0`). Every
  NaN is canonicalised to `f97e00`, sign and payload dropped; ±Inf are
  `f97c00`/`f9fc00`. A `float64 2.0` stays a float — no dCBOR reduction.
- Text is well-formed UTF-8 without U+0000 and **no Unicode normalization**:
  NFC and NFD spellings are different values.
- Null is `missing` (ADR-0025); `nothing` is refused.
- No tags, no indefinite lengths, no simple values but false/true/null.
- Map keys are text; duplicate keys and unsorted keys are rejected.

# Julia mapping

| CBOR | encoder accepts | decoder yields |
|---|---|---|
| int | `Integer` (not `Bool`) in the `Int64` range | `Int64` |
| float | `AbstractFloat` exactly representable as `Float64` | `Float64` |
| tstr | `AbstractString` | `String` |
| bstr | `AbstractVector{UInt8}` | `Vector{UInt8}` |
| bool | `Bool` | `Bool` |
| null | `missing` | `missing` |
| array | `AbstractVector`, `Tuple` | `Vector{Any}` |
| map | `AbstractDict`, `NamedTuple` with text or `Symbol` keys | `Dict{String,Any}` |

# Streaming

`encode(io, x)` writes one item to `io` and returns the byte count;
`decode(io)` reads exactly one item and leaves `io` positioned after it. A
table file (ADR-0023) is `[shape, rows]` with rows too many to hold, so
[`write_array_header`](@ref) and [`read_array_header`](@ref) expose the array
head and the caller streams the elements one `encode`/`decode` at a time.

# Errors

The encoder refuses a value it cannot carry with an `ArgumentError` (a
programming error on the writing side: an unsupported type, an out-of-range
integer, invalid UTF-8, U+0000). The decoder raises [`DecodeError`](@ref) with
the byte offset for anything outside the profile; the caller — apply, load —
decides which `ChainTablesError` that is (`MalformedRecordError`,
`LocalCopyInconsistentError`; ADR-0020).
"""
module CBOR

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

const MT_UINT = 0x00
const MT_NEG = 0x20
const MT_BYTES = 0x40
const MT_TEXT = 0x60
const MT_ARRAY = 0x80
const MT_MAP = 0xa0
const MT_TAG = 0xc0
const MT_SIMPLE = 0xe0

const SIMPLE_FALSE = 0xf4
const SIMPLE_TRUE = 0xf5
const SIMPLE_NULL = 0xf6
const HEAD_FLOAT16 = 0xf9
const HEAD_FLOAT32 = 0xfa
const HEAD_FLOAT64 = 0xfb

"""
    CANONICAL_NAN_BITS

The one NaN the format admits, as float16 bits: `0x7e00`, encoded `f97e00`
(ADR-0025). Every NaN the encoder sees is written as this; the decoder rejects
every other NaN encoding, so the model only ever holds `NaN` proper.
"""
const CANONICAL_NAN_BITS = 0x7e00

"""
    MAX_STRING_BYTES

The longest text or byte string the decoder will read: 64 MiB, the record cap
of ADR-0006. Nothing in the format can hold a longer one, and the bound keeps a
corrupt length byte from becoming an allocation the size of the address space.
"""
const MAX_STRING_BYTES = 64 * 1024 * 1024

"""
    MAX_DEPTH

The deepest nesting the decoder will follow. The format's deepest item is a row
inside `rows` inside an op inside `ops` inside a record — five levels — so 64
is far outside anything legitimate and inside any stack.
"""
const MAX_DEPTH = 64

# ---------------------------------------------------------------------------
# Errors
# ---------------------------------------------------------------------------

"""
    DecodeError(msg, offset)

The bytes are not the format: malformed, truncated, or well-formed CBOR that
the profile rejects (a tag, an indefinite length, a non-shortest head, an
unsorted or duplicate map key, a non-canonical NaN, …). `offset` is the
zero-based byte offset at which the decoder detected it. Internal: the caller
translates it into the `ChainTablesError` its branch needs (ADR-0020).
"""
struct DecodeError <: Exception
    msg::String
    offset::Int
end

Base.showerror(io::IO, e::DecodeError) = print(io, "CBOR decode error at byte ", e.offset, ": ", e.msg)

# ---------------------------------------------------------------------------
# Encoder
# ---------------------------------------------------------------------------

"""
    encode(x) -> Vector{UInt8}
    encode(io::IO, x) -> Int

Encode one value under the profile. The `io` form writes the bytes and returns
how many; the other returns them. Refuses with an `ArgumentError` anything the
format cannot carry.
"""
function encode(x)
    io = IOBuffer()
    encode(io, x)
    return take!(io)
end

# The head: major type plus the shortest argument encoding (§4.2.1 rule 1).
function write_head(io::IO, mt::UInt8, n::Integer)
    n < 0 && throw(ArgumentError("a CBOR head argument cannot be negative"))
    if n < 24
        return write(io, mt | UInt8(n))
    elseif n <= typemax(UInt8)
        return write(io, mt | 0x18) + write(io, UInt8(n))
    elseif n <= typemax(UInt16)
        return write(io, mt | 0x19) + write(io, hton(UInt16(n)))
    elseif n <= typemax(UInt32)
        return write(io, mt | 0x1a) + write(io, hton(UInt32(n)))
    else
        return write(io, mt | 0x1b) + write(io, hton(UInt64(n)))
    end
end

"""
    write_array_header(io, n) -> Int

Write the head of a definite-length array of `n` items, so a caller can stream
the items with `n` following `encode(io, item)` calls. The streaming half of a
table file (ADR-0023).
"""
write_array_header(io::IO, n::Integer) = write_head(io, MT_ARRAY, n)

function encode(io::IO, x::Integer)
    typemin(Int64) <= x <= typemax(Int64) ||
        throw(ArgumentError("integer $x is outside the int64 domain of the format"))
    v = Int64(x)
    return v >= 0 ? write_head(io, MT_UINT, UInt64(v)) : write_head(io, MT_NEG, UInt64(-(v + 1)))
end

encode(io::IO, x::Bool) = write(io, x ? SIMPLE_TRUE : SIMPLE_FALSE)
encode(io::IO, ::Missing) = write(io, SIMPLE_NULL)

function encode(io::IO, x::AbstractFloat)
    v = Float64(x)
    (isnan(x) || v == x) ||
        throw(ArgumentError("float $x is not exactly representable as Float64; the float64 domain is IEEE binary64"))
    return encode_float64(io, v)
end

# Preferred float representation (§4.2.1 rule 2): the shortest of float16,
# float32, float64 that carries the value exactly. The round-trip check is
# `===`, not `==`: `-0.0 == 0.0`, so a value comparison would let -0.0 leak
# out as +0.0 — the two-line sign-bit check ADR-0006 names.
function encode_float64(io::IO, v::Float64)
    if isnan(v)
        return write(io, HEAD_FLOAT16) + write(io, hton(CANONICAL_NAN_BITS))
    end
    h = Float16(v)
    if Float64(h) === v
        return write(io, HEAD_FLOAT16) + write(io, hton(reinterpret(UInt16, h)))
    end
    s = Float32(v)
    if Float64(s) === v
        return write(io, HEAD_FLOAT32) + write(io, hton(reinterpret(UInt32, s)))
    end
    return write(io, HEAD_FLOAT64) + write(io, hton(reinterpret(UInt64, v)))
end

function encode(io::IO, x::AbstractString)
    s = String(x)
    isvalid(s) || throw(ArgumentError("text is not well-formed UTF-8; the format carries only valid UTF-8"))
    b = codeunits(s)
    0x00 in b && throw(ArgumentError("text contains U+0000, which the format excludes"))
    return write_head(io, MT_TEXT, length(b)) + write(io, b)
end

encode(io::IO, x::AbstractVector{UInt8}) = write_head(io, MT_BYTES, length(x)) + write(io, x)

function encode(io::IO, x::Union{AbstractVector,Tuple})
    n = write_array_header(io, length(x))
    for item in x
        n += encode(io, item)
    end
    return n
end

encode_key(k::Union{AbstractString,Symbol}) = encode(string(k))
encode_key(k) = throw(ArgumentError("map keys are text; got a key of type $(typeof(k))"))

# Map keys sorted bytewise on their encoded form (§4.2.1 rule 3), which for
# text keys is by length first and then by UTF-8 bytes, since the head byte
# carries the length. The encoded key is the sort key, literally.
function encode(io::IO, x::Union{AbstractDict,NamedTuple})
    entries = [(encode_key(k), v) for (k, v) in pairs(x)]
    sort!(entries; by = first)
    for i in 2:length(entries)
        entries[i-1][1] == entries[i][1] &&
            throw(ArgumentError("duplicate map key $(repr(String(entries[i][1][2:end])))"))
    end
    n = write_head(io, MT_MAP, length(entries))
    for (kb, v) in entries
        n += write(io, kb) + encode(io, v)
    end
    return n
end

encode(io::IO, ::Nothing) =
    throw(ArgumentError("nothing is not a value of the format; null is spelled missing (ADR-0025)"))
encode(io::IO, x) = throw(ArgumentError(
    "cannot encode a value of type $(typeof(x)); the format carries int64, float64, text, bytes, bool, null, arrays and text-keyed maps"))

# ---------------------------------------------------------------------------
# Decoder
# ---------------------------------------------------------------------------

# Byte-counting reader so every rejection can name its offset.
mutable struct Reader{T<:IO}
    io::T
    pos::Int
end

reject(r::Reader, msg) = throw(DecodeError(msg, r.pos))

function readbyte(r::Reader)
    eof(r.io) && reject(r, "truncated input")
    b = read(r.io, UInt8)
    r.pos += 1
    return b
end

function readbytes(r::Reader, n::Integer)
    b = read(r.io, n)
    length(b) == n || reject(r, "truncated input")
    r.pos += n
    return b
end

read_be(r::Reader, ::Type{T}) where {T<:Unsigned} = ntoh(reinterpret(T, readbytes(r, sizeof(T)))[1])

"""
    decode(bytes::AbstractVector{UInt8})
    decode(io::IO)

Decode one item under the profile, raising [`DecodeError`](@ref) for anything
outside it. The `bytes` form rejects trailing bytes; the `io` form reads exactly
one item and leaves the stream after it.
"""
function decode(bytes::AbstractVector{UInt8})
    r = Reader(IOBuffer(bytes), 0)
    x = decode_item(r, 0)
    eof(r.io) || reject(r, "trailing bytes after the top-level item")
    return x
end

decode(io::IO) = decode_item(Reader(io, 0), 0)

"""
    read_array_header(io) -> Int

Read the head of a definite-length array and return its item count, so a
caller can stream the items with that many following `decode(io)` calls. The
streaming half of a table file (ADR-0023).
"""
function read_array_header(io::IO)
    r = Reader(io, 0)
    mt, n = read_head(r)
    mt == MT_ARRAY || reject(r, "expected an array head, got major type $(mt >> 5)")
    return Int(n)
end

# The head: returns (major type, argument); rejects indefinite lengths, the
# reserved additional-information values and a non-shortest argument
# (§4.2.1 rule 1). Major type 7 is handled by the caller since its arguments
# are simple values and floats, not lengths.
function read_head(r::Reader)
    at = r.pos
    ib = readbyte(r)
    mt = ib & 0xe0
    ai = ib & 0x1f
    if ai < 24
        return mt, UInt64(ai)
    elseif ai == 31
        mt == MT_SIMPLE ? throw(DecodeError("unexpected break (0xff); indefinite lengths are not in the format", at)) :
                           throw(DecodeError("indefinite length is not in the format", at))
    elseif ai > 27
        throw(DecodeError("reserved additional information $ai", at))
    end
    mt == MT_SIMPLE && return mt, UInt64(ai)   # floats and simple(24): the caller reads the argument
    n = ai == 24 ? UInt64(readbyte(r)) :
        ai == 25 ? UInt64(read_be(r, UInt16)) :
        ai == 26 ? UInt64(read_be(r, UInt32)) : read_be(r, UInt64)
    floor = ai == 24 ? 24 : ai == 25 ? UInt64(typemax(UInt8)) + 1 :
            ai == 26 ? UInt64(typemax(UInt16)) + 1 : UInt64(typemax(UInt32)) + 1
    n >= floor || throw(DecodeError("integer argument $n is not in its shortest form", at))
    return mt, n
end

function decode_item(r::Reader, depth::Int)
    depth > MAX_DEPTH && reject(r, "nesting deeper than $MAX_DEPTH levels")
    at = r.pos
    mt, n = read_head(r)
    if mt == MT_UINT
        n <= typemax(Int64) || throw(DecodeError("integer $n exceeds the int64 domain of the format", at))
        return Int64(n)
    elseif mt == MT_NEG
        n <= typemax(Int64) || throw(DecodeError("integer -1-$n is below the int64 domain of the format", at))
        return -Int64(n) - 1
    elseif mt == MT_BYTES
        return readbytes(r, checked_length(r, n, at))
    elseif mt == MT_TEXT
        return decode_text(r, checked_length(r, n, at), at)
    elseif mt == MT_ARRAY
        items = Vector{Any}(undef, 0)
        for _ in 1:n
            push!(items, decode_item(r, depth + 1))
        end
        return items
    elseif mt == MT_MAP
        return decode_map(r, n, depth)
    elseif mt == MT_TAG
        throw(DecodeError("tag $n; tags are not in the format", at))
    else
        return decode_simple(r, n, at)
    end
end

function checked_length(r::Reader, n::UInt64, at::Int)
    n <= MAX_STRING_BYTES ||
        throw(DecodeError("string of $n bytes exceeds the $(MAX_STRING_BYTES ÷ 2^20) MiB record cap", at))
    return Int(n)
end

function decode_text(r::Reader, n::Int, at::Int)
    b = readbytes(r, n)
    s = String(b)
    isvalid(s) || throw(DecodeError("text is not well-formed UTF-8", at))
    0x00 in codeunits(s) && throw(DecodeError("text contains U+0000, which the format excludes", at))
    return s
end

# Keys must be text, strictly increasing bytewise on their encoded form
# (§4.2.1 rule 3). Equal is a duplicate (§5.6, rejected per ADR-0006);
# decreasing is unsorted. Because a valid key is in shortest form, re-encoding
# the decoded key reproduces its stored bytes, which is the sort key.
function decode_map(r::Reader, n::UInt64, depth::Int)
    m = Dict{String,Any}()
    prev = UInt8[]
    for i in 1:n
        at = r.pos
        k = decode_item(r, depth + 1)
        k isa String || throw(DecodeError("map key must be text, got $(typeof(k))", at))
        kb = encode(k)
        if i > 1
            kb == prev && throw(DecodeError("duplicate map key $(repr(k))", at))
            isless(prev, kb) ||
                throw(DecodeError("map key $(repr(k)) is not in RFC 8949 §4.2.1 order (bytewise on the encoded key)", at))
        end
        m[k] = decode_item(r, depth + 1)
        prev = kb
    end
    return m
end

function decode_simple(r::Reader, ai::UInt64, at::Int)
    if ai == 20
        return false
    elseif ai == 21
        return true
    elseif ai == 22
        return missing
    elseif ai == 25
        bits = read_be(r, UInt16)
        h = reinterpret(Float16, bits)
        isnan(h) && bits != CANONICAL_NAN_BITS &&
            throw(DecodeError("NaN must be encoded as f97e00, got f9$(string(bits; base = 16, pad = 4))", at))
        return Float64(h)
    elseif ai == 26
        s = reinterpret(Float32, read_be(r, UInt32))
        isnan(s) && throw(DecodeError("NaN must be encoded as f97e00, got a float32 NaN", at))
        Float32(Float16(s)) === s &&
            throw(DecodeError("float $s is not in its shortest form (fits float16)", at))
        return Float64(s)
    elseif ai == 27
        v = reinterpret(Float64, read_be(r, UInt64))
        isnan(v) && throw(DecodeError("NaN must be encoded as f97e00, got a float64 NaN", at))
        Float64(Float32(v)) === v &&
            throw(DecodeError("float $v is not in its shortest form (fits float32)", at))
        return v
    elseif ai == 23
        throw(DecodeError("simple value undefined (0xf7) is not in the format", at))
    elseif ai == 24
        v = readbyte(r)
        throw(DecodeError("simple value $v is not in the format", at))
    else
        throw(DecodeError("simple value $ai is not in the format", at))
    end
end

end # module CBOR
