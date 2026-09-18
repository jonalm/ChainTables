# Shared by test/gateway.jl (offline) and test/live/gateway.jl. Included once, by
# test/runtests.jl and by test/live/runtests.jl.
import ChainTables
const GWT = ChainTables

# A CBOR map that passes the gateway's checks: a record-shaped map naming `user`.
gwtest_record(user) = GWT.CBOR.encode(Dict{String,Any}("format_version" => 1, "client" => Dict{String,Any}("user" => user), "ops" => Any[]))
