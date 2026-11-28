const BASE32_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"

"""
    chain_id_string(bytes)

Return a chain id as text: its 16 bytes in base32, 26 characters with no padding.

A transaction record holds the bytes. A head file and every message hold the text.
`chain_id_bytes` is the inverse. Throws `ArgumentError` for anything but 16 bytes.

Examples: test/test_chain_id_text_examples.jl
"""
function chain_id_string(bytes::AbstractVector{UInt8})
    length(bytes) == 16 ||
        throw(ArgumentError("a chain id is 16 bytes, got $(length(bytes))"))
    out = IOBuffer()
    bits = UInt64(0)
    n_bits = 0
    for byte in bytes
        bits = (bits << 8) | byte
        n_bits += 8
        while n_bits >= 5
            n_bits -= 5
            write(out, BASE32_ALPHABET[Int((bits >> n_bits) & 0x1f) + 1])
            bits &= (UInt64(1) << n_bits) - 1
        end
    end
    # 128 = 25 × 5 + 3: the last three bits sit at the left of a 26th character.
    write(out, BASE32_ALPHABET[Int((bits << (5 - n_bits)) & 0x1f) + 1])
    return String(take!(out))
end

"""
    chain_id_bytes(text)

Return the 16 bytes of a chain id written as `chain_id_string` writes it.

Case is ignored. Throws `ArgumentError` for anything but 26 base32 characters whose
last two bits are zero.

Examples: test/test_chain_id_text_examples.jl
"""
function chain_id_bytes(text::AbstractString)
    length(text) == 26 ||
        throw(ArgumentError("a chain id is 26 base32 characters, got $(repr(text))"))
    out = UInt8[]
    bits = UInt64(0)
    n_bits = 0
    for character in uppercase(text)
        bits = (bits << 5) | base32_value(character, text)
        n_bits += 5
        if n_bits >= 8
            n_bits -= 8
            push!(out, UInt8((bits >> n_bits) & 0xff))
            bits &= (UInt64(1) << n_bits) - 1
        end
    end
    bits == 0 || throw(
        ArgumentError("$(repr(text)) is not a chain id: its trailing bits are not zero")
    )
    return out
end

function base32_value(character, text)
    position = findfirst(==(character), BASE32_ALPHABET)
    position === nothing && throw(
        ArgumentError(
            "$(repr(character)) in $(repr(text)) is not a base32 character (A–Z, 2–7)"
        )
    )
    return UInt64(position - 1)
end
