"""
    DecodeError(offset, detail)

Thrown when bytes are not the format's deterministic CBOR: malformed, truncated, or
well-formed CBOR that the profile rejects. `offset` is the zero-based byte where the
decoder found it.

Internal: it becomes `MalformedRecordError` when a record is decoded and
`LocalCopyInconsistentError` when a table file is read.
"""
struct DecodeError <: Exception
    offset::Int
    detail::String
end

"""
    Reader(io, pos)

A stream being decoded and the count of bytes read from it, so that every rejection
names its offset.
"""
mutable struct Reader{T <: IO}
    const io::T
    pos::Int
end

# style: inferred the item's type is whatever the bytes hold
# `decode` keeps the codec's name, not an I/O verb: the whole package and test/live
# call it.
"""
    decode(bytes::AbstractVector{UInt8})
    decode(io::IO)

Decode one item of deterministic CBOR, the inverse of `encode`.

An integer comes back as `Int64`, a float as `Float64`, text as `String`, bytes as
`Vector{UInt8}`, null as `missing`, an array as `Vector{Any}` and a map as
`Dict{String, Any}`. The `bytes` form refuses trailing bytes; the `io` form reads one
item and leaves the stream after it.

Throws the internal `DecodeError` for anything outside the profile of `encode`: a tag,
an indefinite length, a head or float not in its shortest form, an unsorted or
duplicate map key, a NaN other than `f97e00`.

Examples: test/test_cbor_decode_examples.jl
"""
function decode(bytes::AbstractVector{UInt8})
    r = Reader(IOBuffer(bytes), 0)
    x = decode_item(r, 0)
    eof(r.io) || throw(DecodeError(r.pos, "trailing bytes after the top-level item"))
    return x
end

decode(io::IO) = decode_item(Reader(io, 0), 0)

"""
    read_array_header(io::IO)

Read the head of a definite-length array from `io` and return its item count.

The caller streams the items with that many following `decode(io)` calls. Throws the
internal `DecodeError` when the next item is not an array.

Examples: test/test_cbor_decode_examples.jl
"""
function read_array_header(io::IO)
    r = Reader(io, 0)
    major, n = read_head(r)
    major == MT_ARRAY ||
        throw(DecodeError(r.pos, "expected an array head, got major type $(major >> 5)"))
    return Int(n)
end

function decode_item(r::Reader, depth::Int)
    depth > MAX_DEPTH &&
        throw(DecodeError(r.pos, "nesting deeper than $MAX_DEPTH levels"))
    at = r.pos
    major, n = read_head(r)
    major == MT_UINT && return decode_unsigned(n, at)
    major == MT_NEG && return decode_negative(n, at)
    major == MT_BYTES && return read_bytes(r, checked_length(n, at))
    major == MT_TEXT && return decode_text(r, checked_length(n, at), at)
    major == MT_ARRAY && return decode_array(r, n, depth)
    major == MT_MAP && return decode_map(r, n, depth)
    major == MT_TAG && throw(DecodeError(at, "tag $n; tags are not in the format"))
    return decode_simple(r, n, at)
end

# Returns (major type, argument). Major type 7 carries simple values and floats, not
# lengths, so decode_simple reads its argument.
function read_head(r::Reader)
    at = r.pos
    initial = read_byte(r)
    major = initial & 0xe0
    info = initial & 0x1f
    info < 24 && return major, UInt64(info)
    info == 31 && throw(DecodeError(at, indefinite_length_detail(major)))
    info > 27 && throw(DecodeError(at, "reserved additional information $info"))
    major == MT_SIMPLE && return major, UInt64(info)
    n = read_argument(r, info)
    n >= SHORTEST_ARGUMENT[info - 23] ||
        throw(DecodeError(at, "integer argument $n $NOT_SHORTEST"))
    return major, n
end

function indefinite_length_detail(major::UInt8)
    major == MT_SIMPLE && return UNEXPECTED_BREAK
    return "indefinite length is not in the format"
end

function read_argument(r::Reader, info::UInt8)
    info == 24 && return UInt64(read_byte(r))
    info == 25 && return UInt64(read_big_endian(r, UInt16))
    info == 26 && return UInt64(read_big_endian(r, UInt32))
    return read_big_endian(r, UInt64)
end

function read_byte(r::Reader)
    eof(r.io) && throw(DecodeError(r.pos, "truncated input"))
    b = read(r.io, UInt8)
    r.pos += 1
    return b
end

function read_bytes(r::Reader, n::Integer)
    b = read(r.io, n)
    length(b) == n || throw(DecodeError(r.pos, "truncated input"))
    r.pos += n
    return b
end

function read_big_endian(r::Reader, ::Type{T}) where {T <: Unsigned}
    return ntoh(only(reinterpret(T, read_bytes(r, sizeof(T)))))
end

function decode_unsigned(n::UInt64, at::Int)
    n <= typemax(Int64) ||
        throw(DecodeError(at, "integer $n exceeds the int64 domain of the format"))
    return Int64(n)
end

function decode_negative(n::UInt64, at::Int)
    n <= typemax(Int64) ||
        throw(DecodeError(at, "integer -1-$n is below the int64 domain of the format"))
    return -Int64(n) - 1
end

function checked_length(n::UInt64, at::Int)
    mebibytes = MAX_STRING_BYTES ÷ 2^20
    n <= MAX_STRING_BYTES ||
        throw(DecodeError(at, "string of $n bytes exceeds the $mebibytes MiB record cap"))
    return Int(n)
end

function decode_text(r::Reader, n::Int, at::Int)
    s = String(read_bytes(r, n))
    isvalid(s) || throw(DecodeError(at, TEXT_NOT_UTF8))
    0x00 in codeunits(s) && throw(DecodeError(at, TEXT_HAS_NUL))
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

# Keys are text, strictly increasing bytewise on their encoded form (RFC 8949 §4.2.1
# rule 3). A valid key is in shortest form, so encoding it again gives its stored
# bytes. An equal key is a duplicate (rejected per ADR-0006); a smaller one is unsorted.
function decode_map(r::Reader, n::UInt64, depth::Int)
    map = Dict{String, Any}()
    previous = UInt8[]
    for _ in 1:n
        at = r.pos
        key = decode_item(r, depth + 1)
        key isa String || throw(DecodeError(at, "map key must be text, got $(typeof(key))"))
        bytes = encode(key)
        bytes == previous && throw(DecodeError(at, "duplicate map key $(repr(key))"))
        isless(previous, bytes) ||
            throw(DecodeError(at, "map key $(repr(key)) $UNSORTED_KEY"))
        map[key] = decode_item(r, depth + 1)
        previous = bytes
    end
    return map
end

function decode_simple(r::Reader, info::UInt64, at::Int)
    info == 20 && return false
    info == 21 && return true
    info == 22 && return missing
    info == 25 && return decode_float16(read_big_endian(r, UInt16), at)
    info == 26 && return decode_float32(read_big_endian(r, UInt32), at)
    info == 27 && return decode_float64(read_big_endian(r, UInt64), at)
    info == 23 &&
        throw(DecodeError(at, "simple value undefined (0xf7) is not in the format"))
    value = info == 24 ? UInt64(read_byte(r)) : info
    throw(DecodeError(at, "simple value $value is not in the format"))
end

function decode_float16(bits::UInt16, at::Int)
    half = reinterpret(Float16, bits)
    hex = string(bits; base = 16, pad = 4)
    isnan(half) && bits != CANONICAL_NAN_BITS &&
        throw(DecodeError(at, "$NAN_NOT_CANONICAL, got f9$hex"))
    return Float64(half)
end

function decode_float32(bits::UInt32, at::Int)
    single = reinterpret(Float32, bits)
    isnan(single) && throw(DecodeError(at, "$NAN_NOT_CANONICAL, got a float32 NaN"))
    Float32(Float16(single)) === single &&
        throw(DecodeError(at, "float $single $NOT_SHORTEST (fits float16)"))
    return Float64(single)
end

function decode_float64(bits::UInt64, at::Int)
    v = reinterpret(Float64, bits)
    isnan(v) && throw(DecodeError(at, "$NAN_NOT_CANONICAL, got a float64 NaN"))
    Float64(Float32(v)) === v &&
        throw(DecodeError(at, "float $v $NOT_SHORTEST (fits float32)"))
    return v
end
