"""
The record format on top of the table model: the seven ops, the transaction record and
its stored bytes, and apply. Terms: see `CONTEXT.md`.
"""
module Ops

using SHA: SHA
using ..ChainTables: ChainTables, CBOR, Column, Content, MalformedRecordError, ModelError,
    Shape, WriteBuilderError, add_table!, append_column!, column_from_entry, content_table,
    delete_table_rows!, insert_table_rows!, remove_column!, remove_table!, shape_wire,
    update_table_rows!

public Client, Record, decode_record, encode_record

include("op.jl")
include("record.jl")
include("record_bytes.jl")
include("apply.jl")

end
