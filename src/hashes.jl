# #34 step 8 — ADR-0019: the two hash types on the public surface, 32 bytes each, shown
# as hex, distinct so a transaction hash is never passed where a state fingerprint is due.
# First in the include order: the error types carry them as evidence (ADR-0020).

"""
    TransactionHash(bytes)
    TransactionHash(hex::AbstractString)

The hash of a transaction record's stored bytes (ADR-0006), as a value on the public
surface (ADR-0019): what `head(copy)`, `commit!`, `sync!` and `create_chain` return, what
`as_of` accepts as an address, and what every error carries as evidence. Its 32 bytes are
its value: two are equal when their bytes are, `==` against a raw 32-byte vector holds
either way round, and `hash` agrees, so evidence read from an error compares with what the
model computed. A [`StateFingerprint`](@ref) of the same bytes is never equal to it and is
refused by its constructor: the two are distinct types so that no call accepts one for the
other. `bytes2hex(h)` is the hex text `show` prints; the second constructor reads it back,
in either case.
"""
struct TransactionHash
    bytes::Vector{UInt8}
    TransactionHash(bytes) = new(hash_bytes(TransactionHash, bytes))
end

"""
    StateFingerprint(bytes)
    StateFingerprint(hex::AbstractString)

A state fingerprint (ADR-0007) as a value on the public surface (ADR-0019): what
`head(copy)` and `commit!` return, and what a `FingerprintMismatchError` or a
`DivergenceError` carries as `expected` and `computed`. Equality, hashing and the hex
form are [`TransactionHash`](@ref)'s; the two types are never equal and never accept each
other.
"""
struct StateFingerprint
    bytes::Vector{UInt8}
    StateFingerprint(bytes) = new(hash_bytes(StateFingerprint, bytes))
end

# 32 bytes, from bytes or from 64 hex characters, with the type named in every refusal.
function hash_bytes(T, x)
    if x isa AbstractString
        b = try
            hex2bytes(x)
        catch e
            e isa ArgumentError || rethrow()
            throw(ArgumentError("$(repr(x)) is not 64 hex characters, so not a $(nameof(T))"))
        end
    elseif x isa AbstractVector{UInt8}
        b = x
    else
        throw(ArgumentError("a $(nameof(T)) is 32 bytes or 64 hex characters, got a value of type $(typeof(x))"))
    end
    length(b) == 32 || throw(ArgumentError("a $(nameof(T)) is 32 bytes, got $(length(b))"))
    return Vector{UInt8}(b)
end

for T in (:TransactionHash, :StateFingerprint)
    @eval begin
        $T(h::$T) = h
        Base.:(==)(a::$T, b::$T) = a.bytes == b.bytes
        Base.:(==)(a::$T, b::AbstractVector{UInt8}) = a.bytes == b
        Base.:(==)(a::AbstractVector{UInt8}, b::$T) = a == b.bytes
        Base.hash(h::$T, s::UInt) = hash(h.bytes, s)
        Base.bytes2hex(h::$T) = bytes2hex(h.bytes)
        Base.show(io::IO, h::$T) = print(io, $(string(T)), "(\"", bytes2hex(h.bytes), "\")")
    end
end

# The evidence fields of the error types: a hash given as raw bytes is carried typed.
maybe_hash(T, x) = x === nothing ? nothing : T(x)
