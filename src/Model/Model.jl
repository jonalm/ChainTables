"""
The content of a local copy as Julia values: per table, a `Shape` and its rows of typed
values. Replay, apply and the state fingerprint run on this model. Terms: see
`CONTEXT.md`.
"""
module Model

using SHA: SHA
using ..CBOR: CBOR

public Column, Content, Shape, Table, read_table, state_fingerprint, table_hash,
    write_table

include("model_error.jl")
include("shape.jl")
include("row_checks.jl")
include("table.jl")
include("content.jl")
include("table_file.jl")
include("fingerprint.jl")

end
