"""
    TransactionHash(bytes)
    TransactionHash(hex::AbstractString)

The hash of a transaction record's stored bytes, as a value: 32 bytes.

Two are equal when their bytes are. `==` against a raw 32-byte vector holds either way
round, and `hash` agrees. A `StateFingerprint` of the same bytes is never equal to it,
and the constructor refuses one, so no call takes one for the other. `bytes2hex(h)` is
the hex text that `show` prints; the second form reads it back, in either case. Throws
`ArgumentError` for anything but 32 bytes or 64 hex characters.

Examples: test/test_hashes_examples.jl
"""
struct TransactionHash
    bytes::Vector{UInt8}
    TransactionHash(bytes) = new(hash_bytes(TransactionHash, bytes))
end

TransactionHash(h::TransactionHash) = h

"""
    StateFingerprint(bytes)
    StateFingerprint(hex::AbstractString)

A state fingerprint as a value: 32 bytes.

Equality, hashing and the hex form are those of `TransactionHash`. The two types are
never equal and never accept each other. Throws `ArgumentError` for anything but 32
bytes or 64 hex characters.

Examples: test/test_hashes_examples.jl
"""
struct StateFingerprint
    bytes::Vector{UInt8}
    StateFingerprint(bytes) = new(hash_bytes(StateFingerprint, bytes))
end

StateFingerprint(h::StateFingerprint) = h

const ChainHash = Union{StateFingerprint, TransactionHash}

Base.:(==)(a::T, b::T) where {T <: ChainHash} = a.bytes == b.bytes
Base.:(==)(a::ChainHash, b::AbstractVector{UInt8}) = a.bytes == b
Base.:(==)(a::AbstractVector{UInt8}, b::ChainHash) = a == b.bytes
Base.hash(h::ChainHash, s::UInt) = hash(h.bytes, s)
Base.bytes2hex(h::ChainHash) = bytes2hex(h.bytes)

function Base.show(io::IO, h::ChainHash)
    print(io, nameof(typeof(h)), "(")
    show(io, bytes2hex(h.bytes))
    print(io, ")")
    return nothing
end

function hash_bytes(::Type{T}, hex::AbstractString) where {T}
    iseven(ncodeunits(hex)) && all(isxdigit, hex) || throw(
        ArgumentError("$(repr(hex)) is not 64 hex characters, so not a $(nameof(T))")
    )
    return hash_bytes(T, hex2bytes(hex))
end

function hash_bytes(::Type{T}, bytes::AbstractVector{UInt8}) where {T}
    length(bytes) == 32 ||
        throw(ArgumentError("a $(nameof(T)) is 32 bytes, got $(length(bytes))"))
    return Vector{UInt8}(bytes)
end

function hash_bytes(::Type{T}, x) where {T}
    throw(
        ArgumentError(
            "a $(nameof(T)) is 32 bytes or 64 hex characters, " *
                "got a value of type $(typeof(x))"
        )
    )
end
