module ChainTables

# Layout follows the build order of #34 §3. Nothing is exported (ADR-0019).
# errors.jl comes first so every lane raises the same types (ADR-0020).

include("errors.jl")     # ADR-0020: ChainTablesError and the fourteen concrete types; AbstractObjectStore (ADR-0010)
include("cbor.jl")       # step 1
include("model.jl")      # step 2
include("ops.jl")        # step 3
include("builder.jl")    # step 4
include("localcopy.jl")  # steps 5, 7, 8
include("store.jl")      # steps 6, 7
include("s3.jl")         # step 9
include("Testing.jl")    # step 6

end # module ChainTables
