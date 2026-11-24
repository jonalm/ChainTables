"""
Several independent clients agree on the content of a set of tables without a server,
through a hash-chained sequence of immutable records in an S3 bucket. Terms: see
`CONTEXT.md`.
"""
module ChainTables

public CBOR, Model, Ops, StateFingerprint, TransactionHash

include("hashes.jl")
include("errors.jl")
include("CBOR/CBOR.jl")
include("Model/Model.jl")
include("Ops/Ops.jl")
include("builder.jl")
include("localcopy.jl")
include("views.jl")
include("store.jl")
include("chain.jl")
include("recovery.jl")
include("s3.jl")
include("gateway.jl")
include("bucket.jl")
include("attachments.jl")
include("Testing.jl")

end
