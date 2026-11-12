# test/live/ calls ChainTables through `GWT`, and that suite is outside this file's
# reach, so the name stays.
const GWT = ChainTables

"""
    gateway_test_record(user)

The bytes of a record-shaped CBOR map naming `user` as author: what the gateway checks.
"""
function gateway_test_record(user)
    client = Dict{String, Any}("user" => user)
    record = Dict{String, Any}("format_version" => 1, "client" => client, "ops" => Any[])
    return ChainTables.CBOR.encode(record)
end

# The name test/live/gateway.jl calls.
const gwtest_record = gateway_test_record
