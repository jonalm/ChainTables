using Test
using ChainTables: GatewayMismatchError, GatewaySessionEndingError, WriteRefusedError

include("fixtures/evidence.jl")

const NEXT_MOVES = [
    (reason = "forbidden", fragment = "ask the bucket's operator for the writer"),
    (reason = "not_allowed", fragment = "add the caller's name to the gateway policy"),
    (reason = "author_mismatch", fragment = "Report it."),
    (reason = "s3_refused", fragment = "Report it to the bucket's operator."),
    (reason = "no_mint_route", fragment = "redeploy it (`gateway/deploy.sh`)"),
    (reason = "a_new_code", fragment = "a reason that this client does not know"),
    (reason = nothing, fragment = "a reason that this client does not know"),
]

@testset "WriteRefusedError shows what happened, the evidence and the next move" begin
    e = WriteRefusedError(;
        chain_id = CHAIN_ID, slot = 4, key = SLOT_KEY, caller = "alice@example.com",
        reason = "not_allowed"
    )
    @test sprint(showerror, e) ==
        "WriteRefusedError: the gateway refused the write, and nothing is retried.\n" *
        "  chain_id = AAAAAAAAAAAAAAAAAAAAAAAAAA\n" *
        "  slot = 4\n" *
        "  key = p/000000000004\n" *
        "  caller = alice@example.com\n" *
        "  reason = not_allowed\n" *
        "Ask the bucket's operator to add the caller's name to the gateway policy " *
        "for this prefix."
end

@testset "WriteRefusedError takes its next move from the reason" begin
    @testset "$(repr(case.reason))" for case in NEXT_MOVES
        text = sprint(showerror, WriteRefusedError(; case.reason))
        @test occursin(case.fragment, last(split(text, "\n")))
    end
end

@testset "GatewayMismatchError shows what happened, the evidence and the next move" begin
    e = GatewayMismatchError(;
        chain_id = CHAIN_ID, slot = 4, key = SLOT_KEY, bucket = "bkt", gateway = GATEWAY
    )
    @test sprint(showerror, e) ==
        "GatewayMismatchError: the gateway does not act as the gateway of the " *
        "bucket that this chain reads.\n" *
        "  chain_id = AAAAAAAAAAAAAAAAAAAAAAAAAA\n" *
        "  slot = 4\n" *
        "  key = p/000000000004\n" *
        "  bucket = bkt\n" *
        "  gateway = https://gw\n" *
        "Pair the bucket with its own gateway, as one `ChainTables.Bucket` value. " *
        "If they are paired, ask the bucket's operator to redeploy the gateway " *
        "(`gateway/deploy.sh`)."
end

@testset "GatewaySessionEndingError shows what happened, the evidence, the next move" begin
    e = GatewaySessionEndingError(; key = ATTACHMENT_KEY, gateway = GATEWAY)
    @test fieldnames(GatewaySessionEndingError) == (:key, :gateway, :detail)
    @test sprint(showerror, e) ==
        "GatewaySessionEndingError: the gateway's AWS session ends too soon for it " *
        "to sign an upload URL.\n" *
        "  key = p/_attachments/$ZEROS_HEX\n" *
        "  gateway = https://gw\n" *
        "Nothing was stored. Put the attachment again later, once Lambda has " *
        "replaced the execution environment that answered."
end

@testset "WriteRefusedError takes the chain and the slot of the write it was for" begin
    refusal = WriteRefusedError(;
        caller = "alice@example.com", reason = "not_allowed", detail = "the policy"
    )
    e = WriteRefusedError(refusal, CHAIN_ID, 4, SLOT_KEY)
    @test (e.chain_id, e.slot, e.key) == (CHAIN_ID, 4, SLOT_KEY)
    @test (e.caller, e.reason) == ("alice@example.com", "not_allowed")
    @test e.detail == "the policy"
end

@testset "WriteRefusedError keeps the key that the store refused" begin
    refusal = WriteRefusedError(; key = ATTACHMENT_KEY)
    @test WriteRefusedError(refusal, CHAIN_ID, 4, SLOT_KEY).key == ATTACHMENT_KEY
end

@testset "GatewayMismatchError takes the chain and the slot of the write it was for" begin
    mismatch = GatewayMismatchError(; bucket = "bkt", gateway = GATEWAY, detail = "200")
    e = GatewayMismatchError(mismatch, CHAIN_ID, 4, SLOT_KEY)
    @test (e.chain_id, e.slot, e.key) == (CHAIN_ID, 4, SLOT_KEY)
    @test (e.bucket, e.gateway, e.detail) == ("bkt", GATEWAY, "200")
end
