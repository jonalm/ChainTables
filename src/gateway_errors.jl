const REFUSAL_NEXT_MOVES = Dict(
    "forbidden" => "AWS refused the call before the gateway ran. Log in again " *
        "(`aws sso login`) and check this machine's clock; if it is refused again, " *
        "ask the bucket's operator for the writer permission set.",
    "not_allowed" => "Ask the bucket's operator to add the caller's name to the " *
        "gateway policy for this prefix.",
    "author_mismatch" => "The gateway saw another caller than this client resolved " *
        "for itself: a bug, or the login changed between the two calls. Report it.",
    "s3_refused" => "S3 refused one of the gateway's own calls, so the gateway is " *
        "deployed wrongly and a retry cannot help. Report it to the bucket's operator.",
    "no_mint_route" => "The gateway was deployed before attachments. Ask the " *
        "bucket's operator to redeploy it (`gateway/deploy.sh`).",
)

const UNKNOWN_REFUSAL_NEXT_MOVE = "The gateway gave a reason that this client does " *
    "not know. Stop and have the bucket's operator look."

"""
    WriteRefusedError

Thrown when the gateway of a gateway bucket refuses a write: a slot from `commit!` or
`create_chain`, or an attachment.

`key` is the key refused, `caller` the author name that this client resolved for
itself, and `reason` the gateway's code, which says who must act. Nothing is retried.
"""
Base.@kwdef struct WriteRefusedError <: ChainTablesError
    chain_id::Union{Nothing, String} = nothing
    slot::Union{Nothing, Int64} = nothing
    key::Union{Nothing, String} = nothing
    caller::Union{Nothing, String} = nothing
    reason::Union{Nothing, String} = nothing
    detail::String = ""
end

function Base.showerror(io::IO, e::WriteRefusedError)
    print_summary(io, e, "the gateway refused the write, and nothing is retried.")
    print_evidence(io, e)
    print(io, get(REFUSAL_NEXT_MOVES, e.reason, UNKNOWN_REFUSAL_NEXT_MOVE))
    return nothing
end

"""
    GatewayMismatchError

Thrown when a gateway does not act as the gateway of the bucket that this chain reads:
it answers `created` for a slot the bucket does not hold, or mints an upload that does
not fit the bucket.

`gateway` is the gateway's function URL. Nothing is retried, and a record that the
gateway stored stays in the gateway's own bucket.
"""
Base.@kwdef struct GatewayMismatchError <: ChainTablesError
    chain_id::Union{Nothing, String} = nothing
    slot::Union{Nothing, Int64} = nothing
    key::Union{Nothing, String} = nothing
    bucket::Union{Nothing, String} = nothing
    gateway::Union{Nothing, String} = nothing
    detail::String = ""
end

function Base.showerror(io::IO, e::GatewayMismatchError)
    summary = "the gateway does not act as the gateway of the bucket that this chain " *
        "reads."
    print_summary(io, e, summary)
    print_evidence(io, e)
    print(io, "Pair the bucket with its own gateway, as one `ChainTables.Bucket` ")
    print(io, "value. If they are paired, ask the bucket's operator to redeploy the ")
    print(io, "gateway (`gateway/deploy.sh`).")
    return nothing
end

"""
    GatewaySessionEndingError

Thrown when `put_attachment` asks a gateway to mint an upload URL and the gateway
answers that its AWS session ends too soon to sign one.

`gateway` is the gateway's function URL. The call is not retried: the same Lambda
execution environment would most likely answer again. Nothing was stored.
"""
Base.@kwdef struct GatewaySessionEndingError <: ChainTablesError
    key::Union{Nothing, String} = nothing
    gateway::Union{Nothing, String} = nothing
    detail::String = ""
end

function Base.showerror(io::IO, e::GatewaySessionEndingError)
    summary = "the gateway's AWS session ends too soon for it to sign an upload URL."
    print_summary(io, e, summary)
    print_evidence(io, e)
    print(io, "Nothing was stored. Put the attachment again later, once Lambda has ")
    print(io, "replaced the execution environment that answered.")
    return nothing
end
