# Shared by the tests of attachments on a gateway bucket: an attachment, and a gateway
# bucket on loopback servers (fixtures/s3_server.jl and fixtures/gateway_server.jl,
# included first).
using ChainTables: ChainTables, put_attachment
using SHA: sha256
using StableRNGs: StableRNG

const FRESH = rand(StableRNG(4), UInt8, 10)
const FRESH_KEY = "p/_attachments/" * bytes2hex(sha256(FRESH))
const EXPIRES = "2026-11-06T12:00:00Z"
"""
    with_gateway(f)

Call `f(g)` with `g = (; s3, filled, double, gw, sts, store, dir)`: the
`with_gateway_doubles` doubles, with a gateway that lets alice write under `p`, and a
temporary directory. Closes the servers after.
"""
function with_gateway(f)
    alice = "alice@example.com"
    with_gateway_doubles(GWTEST_CREDS, alice, ["p" => [alice]]; arn = GWTEST_ARN) do d
        mktempdir(dir -> f((; d..., dir)))
    end
    return nothing
end

"""
    answer_mint(g; minted...)

Make the gateway double answer every mint with a URL for `FRESH_KEY`, minted with the
`gwtest_minted` keywords `minted`.
"""
function answer_mint(g; minted...)
    mint_reply = () -> gwtest_minted(g.s3, FRESH_KEY, length(FRESH); minted...)
    g.double.respond = req -> req.rawpath == "/mint" ? mint_reply() : nothing
    return nothing
end

put_fresh(g) = thrown(() -> put_attachment(g.store, FRESH_KEY, IOBuffer(FRESH)))
mints(g) = filter(r -> r.rawpath == "/mint", g.gw.requests)
