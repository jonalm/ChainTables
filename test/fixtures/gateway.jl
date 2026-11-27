# What a test writes through a gateway. test/live/gateway.jl includes it too, so it needs
# no other fixture.
using ChainTables: CBOR

# A CBOR map that passes the gateway's checks: a record-shaped map naming `user`.
function gwtest_record(user)
    client = Dict{String, Any}("user" => user)
    map = Dict{String, Any}("format_version" => 1, "client" => client, "ops" => Any[])
    return CBOR.encode(map)
end
