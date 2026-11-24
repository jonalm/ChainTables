"""
The record format on top of the table model: the seven ops, the transaction record,
its stored bytes and `transaction_hash`, and apply. Terms: see `CONTEXT.md`.
"""
module Ops

using SHA: SHA
using ..CBOR: CBOR
using ..ChainTables: ChainTables, MalformedRecordError, WriteBuilderError
using ..Model: Model, Cell, Column, Content, ModelError, Shape, column_from_entry

public AddColumn, Client, CreateTable, Delete, DropColumn, DropTable, Insert, Op, Record,
    Update, apply!, decode_record, encode_record, local_client, transaction_hash

include("op.jl")
include("record.jl")
include("record_bytes.jl")
include("apply.jl")

end
