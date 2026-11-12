# Shared by the tests of attachments on a gateway bucket: an attachment, and a gateway
# bucket on loopback servers (fixtures/s3_server.jl and fixtures/gateway_double.jl,
# included first).
using ChainTables: ChainTables, GatewayObjectStore, put_attachment
using SHA: sha256
using StableRNGs: StableRNG

const FRESH = rand(StableRNG(4), UInt8, 10)
const FRESH_KEY = "p/_attachments/" * bytes2hex(sha256(FRESH))
const EXPIRES = "2026-11-06T12:00:00Z"
"""
    with_gateway(f)

Call `f(g)` with `g = (; s3, double, gw, store, dir)`: a loopback S3, a gateway double
that lets alice write under `p`, its loopback server, a gateway store on both, and a
temporary directory. Closes the servers after.
"""
function with_gateway(f)
    s3 = S3TestServer(; bucket = "bkt", credentials = GWTEST_CREDS)
    policy = ["p" => ["alice@example.com"]]
    alice = "alice@example.com"
    double = GatewayDouble(s3, GWTEST_CREDS, "eu-north-1", alice, policy, _ -> nothing)
    gw = LoopbackServer(double)
    try
        store = GatewayObjectStore(
            "bkt", loopback_url(gw); region = "eu-north-1", credentials = GWTEST_CREDS,
            endpoint = s3test_endpoint(s3), path_style = true, timeout = 30
        )
        mktempdir(dir -> f((; s3, double, gw, store, dir)))
    finally
        close(gw)
        close(s3)
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
