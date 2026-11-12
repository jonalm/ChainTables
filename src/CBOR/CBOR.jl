"""
The frozen deterministic CBOR encoder and the rejecting decoder of the record format:
every byte ChainTables hashes passes through `encode`, every byte it reads through `decode`.
"""
module CBOR

using ..ChainTables: ChainTablesError, print_evidence, print_summary

public DecodeError, decode, encode

include("profile.jl")
include("encode.jl")
include("decode.jl")

end
