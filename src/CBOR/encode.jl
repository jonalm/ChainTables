# The profile is stated here once: this docstring is the format's reference.
# `encode` keeps the codec's name, not an I/O verb: the whole package and test/live
# call it.
"""
    encode(x)
    encode(io::IO, x)

Encode one value as deterministic CBOR and return the bytes, or write them to `io` and
return their count.

The profile is RFC 8949 §4.2.1 core deterministic encoding, pinned further:

- An `Integer` is an int64; one outside that range is refused. A `Bool` is a bool.
- An `AbstractFloat` is IEEE binary64, written as the shortest of float16, float32 and
  float64 that round-trips bitwise, so `-0.0` stays `-0.0`. Every NaN is `f97e00`.
- An `AbstractString` is text: well-formed UTF-8 without U+0000, never normalized.
- An `AbstractVector{UInt8}` is bytes. Any other `AbstractVector`, or a `Tuple`, is an
  array.
- An `AbstractDict` or a `NamedTuple` with text or `Symbol` keys is a map, its keys
  sorted bytewise on their encoded form.
- `missing` is null. `nothing` and every other type are refused.

The output is frozen for the life of the format: a change to it breaks every chain.
Throws `ArgumentError` for a value the format cannot carry.

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
    isnan(x) || v == x || throw(ArgumentError("float $x $NOT_FLOAT64"))
    return encode_float64(io, v)
end

function encode(io::IO, x::AbstractString)
    s = String(x)
    isvalid(s) ||
        throw(ArgumentError("$TEXT_NOT_UTF8; the format carries only valid UTF-8"))
    bytes = codeunits(s)
    0x00 in bytes && throw(ArgumentError(TEXT_HAS_NUL))
    return write_head(io, MT_TEXT, length(bytes)) + write(io, bytes)
end

function encode(io::IO, x::AbstractVector{UInt8})
    return write_head(io, MT_BYTES, length(x)) + write(io, x)
end

function encode(io::IO, x::Union{AbstractVector, Tuple})
    n = write_array_header(io, length(x))
    return n + sum(item -> encode(io, item)::Int, x; init = 0)
end

# Keys sort bytewise on their encoded form (RFC 8949 §4.2.1 rule 3): for text keys that
# is by length first, since the head byte carries the length.
function encode(io::IO, x::Union{AbstractDict, NamedTuple})
    entries = sort!(MapEntry[map_entry(k, v) for (k, v) in pairs(x)]; by = e -> e.bytes)
    twin = findfirst(i -> entries[i].bytes == entries[i + 1].bytes, 1:(length(entries) - 1))
    twin === nothing ||
        throw(ArgumentError("duplicate map key $(repr(entries[twin].key))"))
    n = write_head(io, MT_MAP, length(entries))
    return n + sum(e -> write(io, e.bytes) + encode(io, e.value)::Int, entries; init = 0)
end

encode(io::IO, ::Nothing) = throw(ArgumentError(NOTHING_IS_NOT_NULL))

function encode(io::IO, x)
    throw(ArgumentError("cannot encode a value of type $(typeof(x)); $CARRIED_TYPES"))
end

"""
    write_array_header(io::IO, n)

Write the head of a definite-length array of `n` items to `io` and return the byte count.

The caller streams the items with `n` following `encode(io, item)` calls, so an array
too large to hold is never built.

Examples: test/test_cbor_encode_examples.jl
"""
write_array_header(io::IO, n::Integer) = write_head(io, MT_ARRAY, n)

# The head is the major type plus the shortest encoding of its argument (RFC 8949
# §4.2.1 rule 1).
function write_head(io::IO, major::UInt8, n::Integer)
    n < 0 && throw(ArgumentError("a CBOR head argument cannot be negative, got $n"))
    n < 24 && return write(io, major | UInt8(n))
    n <= typemax(UInt8) && return write(io, major | 0x18) + write(io, UInt8(n))
    n <= typemax(UInt16) && return write(io, major | 0x19) + write(io, hton(UInt16(n)))
    n <= typemax(UInt32) && return write(io, major | 0x1a) + write(io, hton(UInt32(n)))
    return write(io, major | 0x1b) + write(io, hton(UInt64(n)))
end

# The round-trip check is `===`, not `==`: `-0.0 == 0.0`, so a value comparison would
# write -0.0 as +0.0 (ADR-0006).
function encode_float64(io::IO, v::Float64)
    isnan(v) && return write_float(io, HEAD_FLOAT16, CANONICAL_NAN_BITS)
    half = Float16(v)
    Float64(half) === v && return write_float(io, HEAD_FLOAT16, reinterpret(UInt16, half))
    single = Float32(v)
    Float64(single) === v &&
        return write_float(io, HEAD_FLOAT32, reinterpret(UInt32, single))
    return write_float(io, HEAD_FLOAT64, reinterpret(UInt64, v))
end

write_float(io::IO, head::UInt8, bits::Unsigned) = write(io, head) + write(io, hton(bits))

function map_entry(k, v)
    k isa Union{AbstractString, Symbol} ||
        throw(ArgumentError("map keys are text; got a key of type $(typeof(k))"))
    return (; key = string(k), bytes = encode(string(k)), value = v)
end
