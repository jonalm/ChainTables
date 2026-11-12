# Two types, not one: a transaction hash is never accepted where a state fingerprint is
# due (ADR-0019). First in the include order: the error types carry them as Evidence.

"""
    TransactionHash(bytes)
    TransactionHash(hex::AbstractString)

The transaction hash of a transaction record: 32 bytes, read from bytes or 64 hex
characters. Two are equal when their bytes are, and one equals its raw bytes. Never equal
to a `StateFingerprint`, and never built from one. `bytes2hex(h)` gives the hex form.

Examples: test/test_hashes_examples.jl
"""
struct TransactionHash
    bytes::Vector{UInt8}
    TransactionHash(bytes) = new(hash_bytes(TransactionHash, bytes))
end

"""
    StateFingerprint(bytes)
    StateFingerprint(hex::AbstractString)

The state fingerprint of a content: 32 bytes, read from bytes or 64 hex characters.
Equality, hashing and the hex form are those of `TransactionHash`; the two types are
never equal and never build one from the other.

Examples: test/test_hashes_examples.jl
"""
struct StateFingerprint
    bytes::Vector{UInt8}
    StateFingerprint(bytes) = new(hash_bytes(StateFingerprint, bytes))
end

"""
    HashValue

Either hash type, for the methods the two share.
"""
const HashValue = Union{TransactionHash, StateFingerprint}

TransactionHash(h::TransactionHash) = h
StateFingerprint(h::StateFingerprint) = h

Base.:(==)(a::T, b::T) where {T <: HashValue} = a.bytes == b.bytes
Base.:(==)(a::HashValue, b::AbstractVector{UInt8}) = a.bytes == b
Base.:(==)(a::AbstractVector{UInt8}, b::HashValue) = a == b.bytes
# Hashed as its bytes, since a hash value equals its raw bytes.
Base.hash(h::HashValue, seed::UInt) = hash(h.bytes, seed)
Base.bytes2hex(h::HashValue) = bytes2hex(h.bytes)

function Base.show(io::IO, h::HashValue)
    print(io, nameof(typeof(h)), "(")
    show(io, bytes2hex(h))
    print(io, ")")
    return nothing
end

"""
    hash_bytes(T, x) -> Vector{UInt8}

Return the 32 bytes of a `T` read from bytes or from 64 hex characters, as a new
vector. Throws `ArgumentError` naming `T` for anything else.
"""
function hash_bytes(::Type{T}, bytes::AbstractVector{UInt8}) where {T}
    length(bytes) == 32 ||
        throw(ArgumentError("a $(nameof(T)) is 32 bytes, got $(length(bytes))"))
    return Vector{UInt8}(bytes)
end

hash_bytes(::Type{T}, hex::AbstractString) where {T} = hash_bytes(T, bytes_from_hex(T, hex))

# The refusal is the contract for every other input, including the other hash type.
function hash_bytes(::Type{T}, x) where {T}
    what = "a $(nameof(T)) is 32 bytes or 64 hex characters"
    throw(ArgumentError("$what, got a value of type $(typeof(x))"))
end

function bytes_from_hex(::Type{T}, hex::AbstractString) where {T}
    try
        return hex2bytes(hex)
    catch e
        e isa ArgumentError || rethrow()
        throw(ArgumentError("$(repr(hex)) is not 64 hex characters, so not a $(nameof(T))"))
    end
end

# An error's hash Evidence given as raw bytes is carried as its type.
maybe_hash(::Type{T}, x) where {T} = x === nothing ? nothing : T(x)
