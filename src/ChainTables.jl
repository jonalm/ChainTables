module ChainTables

# Layout follows the build order of #34 §3. Nothing is exported (ADR-0019).
# errors.jl comes first so every lane raises the same types (ADR-0020).

include("hashes.jl")     # step 8: TransactionHash, StateFingerprint (ADR-0019)
include("errors.jl")     # ADR-0020: ChainTablesError and the sixteen concrete types; AbstractObjectStore (ADR-0010)
include("cbor.jl")       # step 1
include("model.jl")      # step 2
include("ops.jl")        # step 3
include("builder.jl")    # step 4
include("localcopy.jl")  # steps 5, 8
include("views.jl")      # step 8: TableView, table, shape (ADR-0024)
include("store.jl")      # steps 6, 7
include("chain.jl")      # step 7: Chain, create_chain, sync!, commit!
include("recovery.jl")   # step 8: verify, repair!, as_of, slot_at (ADR-0014, ADR-0015)
include("s3.jl")         # step 9
include("gateway.jl")    # ADR-0028: GatewayObjectStore, the author from STS, the 4 MiB cap
include("bucket.jl")     # ADR-0029: Bucket, Chain(bucket, prefix)
include("Testing.jl")    # step 6

end # module ChainTables
