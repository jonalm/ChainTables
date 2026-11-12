const NOT_BINARY64 = "is not exactly representable as Float64; " *
    "the float64 domain is IEEE binary64"
const TEXT_NOT_VALID = "text is not well-formed UTF-8; the format carries only valid UTF-8"
const NULL_IS_MISSING = "nothing is not a value of the format; " *
    "null is spelled missing (ADR-0025)"
const ENCODABLE = "the format carries int64, float64, text, bytes, bool, null, " *
    "arrays and text-keyed maps"

"""
    encode(x) -> Vector{UInt8}
    encode(io::IO, x) -> Int

Encode one value under the format's deterministic CBOR profile. The `io` form writes the
bytes and returns how many.

It carries an `Integer` in the int64 range (`Bool` is a CBOR bool), an `AbstractFloat`
exact in `Float64` (every NaN as `f97e00`), an `AbstractString` of valid UTF-8 without
U+0000, an `AbstractVector{UInt8}` as bytes, `missing` as null, an `AbstractVector` or
`Tuple` as an array, and an `AbstractDict` or `NamedTuple` with text or `Symbol` keys as a
map. Throws `ArgumentError` for any other value, `nothing` included.

Examples: test/test_cbor_encode_examples.jl
"""
function encode(x)
    io = IOBuffer()
    encode(io, x)
    return take!(io)
end

function encode(io::IO, x::Integer)
    typemin(Int64) <= x <= typemax(Int64) ||
        throw(ArgumentError("integer $x is outside the int64 domain of the format"))
    v = Int64(x)
    v >= 0 && return write_head(io, MT_UINT, UInt64(v))
    return write_head(io, MT_NEG, UInt64(-(v + 1)))
end

encode(io::IO, x::Bool) = write(io, x ? SIMPLE_TRUE : SIMPLE_FALSE)
encode(io::IO, ::Missing) = write(io, SIMPLE_NULL)

function encode(io::IO, x::AbstractFloat)
    v = Float64(x)
    (isnan(x) || v == x) || throw(ArgumentError("float $x $NOT_BINARY64"))
    return encode_float64(io, v)
end

function encode(io::IO, x::AbstractString)
    s = String(x)
    isvalid(s) || throw(ArgumentError(TEXT_NOT_VALID))
    b = codeunits(s)
    0x00 in b && throw(ArgumentError("text contains U+0000, which the format excludes"))
    return write_head(io, MT_TEXT, length(b)) + write(io, b)
end

function encode(io::IO, x::AbstractVector{UInt8})
    return write_head(io, MT_BYTES, length(x)) + write(io, x)
end

function encode(io::IO, x::Union{AbstractVector, Tuple})
    n = write_array_header(io, length(x))
    for item in x
        n += encode(io, item)
    end
    return n
end

# Map keys sorted bytewise on their encoded form (§4.2.1 rule 3): for text keys that is
# by length first, then by UTF-8 bytes, since the head byte carries the length.
function encode(io::IO, x::Union{AbstractDict, NamedTuple})
    entries = sort!([(encode_key(k), v) for (k, v) in pairs(x)]; by = first)
    check_distinct_keys(entries)
    n = write_head(io, MT_MAP, length(entries))
    for (key_bytes, v) in entries
        n += write(io, key_bytes) + encode(io, v)
    end
    return n
end

encode(io::IO, ::Nothing) = throw(ArgumentError(NULL_IS_MISSING))
# The refusal names what the format carries, so a caller sees what to convert to.
function encode(io::IO, x)
    throw(ArgumentError("cannot encode a value of type $(typeof(x)); $ENCODABLE"))
end

"""
    write_array_header(io, n) -> Int

Write the head of a definite-length array of `n` items and return its byte count. The
caller streams the items with `n` following `encode(io, item)` calls.
"""
write_array_header(io::IO, n::Integer) = write_head(io, MT_ARRAY, n)

# The head: major type plus the shortest argument encoding (§4.2.1 rule 1).
function write_head(io::IO, major::UInt8, n::Integer)
    n < 0 && throw(ArgumentError("a CBOR head argument cannot be negative"))
    n < 24 && return write(io, major | UInt8(n))
    n <= typemax(UInt8) && return write(io, major | 0x18) + write(io, UInt8(n))
    n <= typemax(UInt16) && return write(io, major | 0x19) + write(io, hton(UInt16(n)))
    n <= typemax(UInt32) && return write(io, major | 0x1a) + write(io, hton(UInt32(n)))
    return write(io, major | 0x1b) + write(io, hton(UInt64(n)))
end

# Preferred float representation (§4.2.1 rule 2): the shortest of float16, float32 and
# float64 that carries the value exactly. The round trip is checked with `===`, since
# `-0.0 == 0.0` would let -0.0 shorten to +0.0.
function encode_float64(io::IO, v::Float64)
    isnan(v) && return write_float(io, HEAD_FLOAT16, CANONICAL_NAN_BITS)
    half = Float16(v)
    Float64(half) === v && return write_float(io, HEAD_FLOAT16, reinterpret(UInt16, half))
    single = Float32(v)
    bits = reinterpret(UInt32, single)
    Float64(single) === v && return write_float(io, HEAD_FLOAT32, bits)
    return write_float(io, HEAD_FLOAT64, reinterpret(UInt64, v))
end

write_float(io::IO, head::UInt8, bits::Unsigned) = write(io, head) + write(io, hton(bits))

encode_key(k::Union{AbstractString, Symbol}) = encode(string(k))
encode_key(k) = throw(ArgumentError("map keys are text; got a key of type $(typeof(k))"))

# `entries` are sorted, so a duplicate sits next to its twin.
function check_distinct_keys(entries)
    for i in 2:length(entries)
        key_bytes = first(entries[i])
        first(entries[i - 1]) == key_bytes &&
            throw(ArgumentError("duplicate map key $(repr(String(key_bytes[2:end])))"))
    end
    return nothing
end
