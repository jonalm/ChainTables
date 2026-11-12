# A chain id is 128 bits; humans read it as 26 base32 characters, no padding and no case
# to lose (ADR-0011). Records carry the 16 bytes; the head file and messages the text.
const BASE32_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"

"""
    chain_id_string(bytes) -> String

The 16-byte chain id a record carries, as the 26-character base32 text the head file
stores. `chain_id_bytes` is its inverse.
"""
function chain_id_string(bytes::AbstractVector{UInt8})
    length(bytes) == 16 ||
        throw(ArgumentError("a chain id is 16 bytes, got $(length(bytes))"))
    out = IOBuffer()
    acc = UInt64(0)
    n_bits = 0
    for b in bytes
        acc = (acc << 8) | b
        n_bits += 8
        while n_bits >= 5
            n_bits -= 5
            write(out, BASE32_ALPHABET[Int((acc >> n_bits) & 0x1f) + 1])
            acc &= (UInt64(1) << n_bits) - 1
        end
    end
    # 128 = 25 × 5 + 3: the last three bits are left-aligned in a 26th character.
    write(out, BASE32_ALPHABET[Int((acc << (5 - n_bits)) & 0x1f) + 1])
    return String(take!(out))
end

"""
    chain_id_bytes(s) -> Vector{UInt8}

The 16 bytes of a chain id spelt as `chain_id_string` spells it. Case is ignored;
anything but 26 base32 characters with zero trailing bits throws `ArgumentError`.
"""
function chain_id_bytes(s::AbstractString)
    length(s) == 26 ||
        throw(ArgumentError("a chain id is 26 base32 characters, got $(repr(s))"))
    out = UInt8[]
    acc = UInt64(0)
    n_bits = 0
    for c in uppercase(s)
        acc = (acc << 5) | UInt64(base32_value(c, s))
        n_bits += 5
        if n_bits >= 8
            n_bits -= 8
            push!(out, UInt8((acc >> n_bits) & 0xff))
            acc &= (UInt64(1) << n_bits) - 1
        end
    end
    acc == 0 ||
        throw(ArgumentError("$(repr(s)) is not a chain id: its trailing bits are not zero"))
    return out
end

function base32_value(c::AbstractChar, s::AbstractString)
    v = findfirst(==(c), BASE32_ALPHABET)
    v === nothing && throw(
        ArgumentError("$(repr(c)) in $(repr(s)) is not a base32 character (A–Z, 2–7)")
    )
    return v - 1
end
