"""
The frozen deterministic CBOR encoder and the rejecting decoder of the record format.
Every byte ChainTables hashes passes through `encode`, and every byte it reads
through `decode`.
"""
module CBOR

public decode, encode, read_array_header, write_array_header

include("profile.jl")
include("encode.jl")
include("decode.jl")

end
