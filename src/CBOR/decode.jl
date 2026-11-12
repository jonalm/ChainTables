const UNEXPECTED_BREAK = "unexpected break (0xff); indefinite lengths are not in the format"
const INDEFINITE_LENGTH = "indefinite length is not in the format"
const UNSORTED_KEY = "is not in RFC 8949 §4.2.1 order (bytewise on the encoded key)"
const NAN_NOT_CANONICAL = "NaN must be encoded as f97e00"
const NOT_SHORTEST = "is not in its shortest form"
const ABOVE_CAP = "exceeds the $(MAX_STRING_BYTES ÷ 2^20) MiB record cap"
const ABOVE_INT64 = "exceeds the int64 domain of the format"
const BELOW_INT64 = "is below the int64 domain of the format"
const TRAILING_BYTES = "trailing bytes after the top-level item"
const NOT_ARRAY_HEAD = "expected an array head, got major type"
const TOO_DEEP = "nesting deeper than $MAX_DEPTH levels"
const TEXT_NOT_UTF8 = "text is not well-formed UTF-8"
const TEXT_HAS_NUL = "text contains U+0000, which the format excludes"
const KEY_NOT_TEXT = "map key must be text, got"
const UNDEFINED_SIMPLE = "simple value undefined (0xf7) is not in the format"
const DECODE_NEXT_MOVE = "Check that the bytes were written by `CBOR.encode`; " *
    "stored bytes that fail here are damaged."

# The smallest argument each additional-information value 24…27 may carry: anything
# below fits a shorter head, which §4.2.1 rule 1 requires.
const SHORTEST_ARGUMENT = (UInt64(24), UInt64(2)^8, UInt64(2)^16, UInt64(2)^32)

"""
    DecodeError

The bytes are not the format's CBOR: malformed, truncated, or well-formed CBOR that the
profile rejects (a tag, an indefinite length, a non-shortest head, an unsorted or
duplicate map key, a non-canonical NaN). `offset` is the zero-based byte at which the
decoder found it. Check that the bytes were written by `encode`.

Examples: test/test_cbor_decode_examples.jl
"""
struct DecodeError <: ChainTablesError
    offset::Union{Nothing, Int}
    detail::String
end

DecodeError(; offset = nothing, detail = "") = DecodeError(offset, detail)

function Base.showerror(io::IO, e::DecodeError)
    print_summary(io, e, "the bytes are not the CBOR profile of the format")
    print_evidence(io, e)
    print(io, "\n", DECODE_NEXT_MOVE)
    return nothing
end

# style: inferred the item's type is whatever the bytes hold
"""
    decode(bytes::AbstractVector{UInt8})
    decode(io::IO)

Decode one item under the format's deterministic CBOR profile, the inverse of `encode`.

An integer comes back as `Int64`, a float as `Float64`, text as `String`, bytes as
`Vector{UInt8}`, null as `missing`, an array as `Vector{Any}` and a map as
`Dict{String,Any}`. The `bytes` form rejects trailing bytes; the `io` form reads one item
and leaves the stream after it. Throws `DecodeError` for anything outside the profile.

Examples: test/test_cbor_decode_examples.jl
"""
function decode(bytes::AbstractVector{UInt8})
    r = Reader(IOBuffer(bytes), 0)
    x = decode_item(r, 0)
    eof(r.io) ||
        throw(DecodeError(; offset = r.pos, detail = TRAILING_BYTES))
    return x
end

# style: inferred the item's type is whatever the bytes hold
decode(io::IO) = decode_item(Reader(io, 0), 0)

"""
    Reader(io, pos)

A stream being decoded, with the count of bytes read so far, so every rejection can name
its offset.
"""
mutable struct Reader{T <: IO}
    io::T
    pos::Int
end

"""
    read_array_header(io) -> Int

Read the head of a definite-length array and return its item count. The caller streams
the items with that many following `decode(io)` calls. Throws `DecodeError`.
"""
function read_array_header(io::IO)
    r = Reader(io, 0)
    major, n = read_head(r)
    major == MT_ARRAY || throw(
        DecodeError(; offset = r.pos, detail = "$NOT_ARRAY_HEAD $(major >> 5)")
    )
    return Int(n)
end

function decode_item(r::Reader, depth::Int)
    depth > MAX_DEPTH &&
        throw(DecodeError(; offset = r.pos, detail = TOO_DEEP))
    at = r.pos
    major, n = read_head(r)
    major == MT_UINT && return decode_uint(n, at)
    major == MT_NEG && return decode_negative(n, at)
    major == MT_BYTES && return read_bytes(r, checked_length(n, at))
    major == MT_TEXT && return decode_text(r, checked_length(n, at), at)
    major == MT_ARRAY && return decode_array(r, n, depth)
    major == MT_MAP && return decode_map(r, n, depth)
    major == MT_TAG &&
        throw(DecodeError(; offset = at, detail = "tag $n; tags are not in the format"))
    return decode_simple(r, n, at)
end

# Returns (major type, argument). Rejects indefinite lengths, the reserved
# additional-information values and a non-shortest argument (§4.2.1 rule 1).
function read_head(r::Reader)
    at = r.pos
    initial = read_byte(r)
    major = initial & 0xe0
    info = initial & 0x1f
    info < 24 && return major, UInt64(info)
    detail = major == MT_SIMPLE ? UNEXPECTED_BREAK : INDEFINITE_LENGTH
    info == 31 && throw(DecodeError(; offset = at, detail))
    info > 27 &&
        throw(DecodeError(; offset = at, detail = "reserved additional information $info"))
    # Major type 7 carries floats and simple values, read by decode_simple, not lengths.
    major == MT_SIMPLE && return major, UInt64(info)
    n = read_argument(r, info)
    n >= SHORTEST_ARGUMENT[info - 23] || throw(
        DecodeError(; offset = at, detail = "integer argument $n $NOT_SHORTEST")
    )
    return major, n
end

function read_argument(r::Reader, info::UInt8)
    info == 24 && return UInt64(read_byte(r))
    info == 25 && return UInt64(read_big_endian(r, UInt16))
    info == 26 && return UInt64(read_big_endian(r, UInt32))
    return read_big_endian(r, UInt64)
end

function read_byte(r::Reader)
    eof(r.io) && throw(DecodeError(; offset = r.pos, detail = "truncated input"))
    b = read(r.io, UInt8)
    r.pos += 1
    return b
end

function read_bytes(r::Reader, n::Integer)
    b = read(r.io, n)
    length(b) == n || throw(DecodeError(; offset = r.pos, detail = "truncated input"))
    r.pos += n
    return b
end

function read_big_endian(r::Reader, ::Type{T}) where {T <: Unsigned}
    return ntoh(reinterpret(T, read_bytes(r, sizeof(T)))[1])
end

function decode_uint(n::UInt64, at::Int)
    n <= typemax(Int64) || throw(
        DecodeError(; offset = at, detail = "integer $n $ABOVE_INT64")
    )
    return Int64(n)
end

function decode_negative(n::UInt64, at::Int)
    n <= typemax(Int64) || throw(
        DecodeError(; offset = at, detail = "integer -1-$n $BELOW_INT64")
    )
    return -Int64(n) - 1
end

function checked_length(n::UInt64, at::Int)
    n <= MAX_STRING_BYTES || throw(
        DecodeError(; offset = at, detail = "string of $n bytes $ABOVE_CAP")
    )
    return Int(n)
end

function decode_text(r::Reader, n::Int, at::Int)
    s = String(read_bytes(r, n))
    isvalid(s) || throw(DecodeError(; offset = at, detail = TEXT_NOT_UTF8))
    0x00 in codeunits(s) && throw(
        DecodeError(; offset = at, detail = TEXT_HAS_NUL)
    )
    return s
end

# Items are pushed one by one, never preallocated: a corrupt count must end in
# "truncated input", not in an allocation of that many slots.
function decode_array(r::Reader, n::UInt64, depth::Int)
    items = Any[]
    for _ in 1:n
        push!(items, decode_item(r, depth + 1))
    end
    return items
end

# Keys are text, strictly increasing bytewise on their encoded form (§4.2.1 rule 3). A
# valid key is in shortest form, so re-encoding it reproduces its stored bytes.
function decode_map(r::Reader, n::UInt64, depth::Int)
    m = Dict{String, Any}()
    previous_key = UInt8[]
    for _ in 1:n
        at = r.pos
        k = decode_item(r, depth + 1)
        k isa String ||
            throw(DecodeError(; offset = at, detail = "$KEY_NOT_TEXT $(typeof(k))"))
        key_bytes = encode(k)
        check_key_follows(previous_key, key_bytes, k, at)
        m[k] = decode_item(r, depth + 1)
        previous_key = key_bytes
    end
    return m
end

# An equal key is a duplicate (§5.6, rejected per ADR-0006); a smaller one is unsorted.
function check_key_follows(previous_key, key_bytes, k, at::Int)
    key_bytes == previous_key &&
        throw(DecodeError(; offset = at, detail = "duplicate map key $(repr(k))"))
    isless(previous_key, key_bytes) ||
        throw(DecodeError(; offset = at, detail = "map key $(repr(k)) $UNSORTED_KEY"))
    return nothing
end

function decode_simple(r::Reader, info::UInt64, at::Int)
    info == 20 && return false
    info == 21 && return true
    info == 22 && return missing
    info == 25 && return decode_float16(read_big_endian(r, UInt16), at)
    info == 26 && return decode_float32(read_float(r, Float32), at)
    info == 27 && return decode_float64(read_float(r, Float64), at)
    info == 23 && throw(
        DecodeError(; offset = at, detail = UNDEFINED_SIMPLE)
    )
    value = info == 24 ? read_byte(r) : info
    throw(DecodeError(; offset = at, detail = "simple value $value is not in the format"))
end

function decode_float16(bits::UInt16, at::Int)
    half = reinterpret(Float16, bits)
    isnan(half) && bits != CANONICAL_NAN_BITS && throw(
        DecodeError(; offset = at, detail = "$NAN_NOT_CANONICAL, got f9$(hex4(bits))")
    )
    return Float64(half)
end

function decode_float32(single::Float32, at::Int)
    isnan(single) &&
        throw(DecodeError(; offset = at, detail = "$NAN_NOT_CANONICAL, got a float32 NaN"))
    Float32(Float16(single)) === single && throw(
        DecodeError(; offset = at, detail = "float $single $NOT_SHORTEST (fits float16)")
    )
    return Float64(single)
end

function decode_float64(v::Float64, at::Int)
    isnan(v) &&
        throw(DecodeError(; offset = at, detail = "$NAN_NOT_CANONICAL, got a float64 NaN"))
    Float64(Float32(v)) === v && throw(
        DecodeError(; offset = at, detail = "float $v $NOT_SHORTEST (fits float32)")
    )
    return v
end

hex4(bits::UInt16) = string(bits; base = 16, pad = 4)

read_float(r::Reader, ::Type{Float32}) = reinterpret(Float32, read_big_endian(r, UInt32))
read_float(r::Reader, ::Type{Float64}) = reinterpret(Float64, read_big_endian(r, UInt64))
