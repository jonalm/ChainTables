# Keyed by `is_retryable`.
const TRANSPORT_NEXT_MOVES = Dict(
    true => "The failure may pass: run the call again later. `commit!` and " *
        "`create_chain` have retried it already.",
    false => "A retry will not help. Check the credentials, the bucket and its region, " *
        "and that the endpoint is S3.",
)

"""
    TransportError

Thrown when a request of an object store fails: its response has a status that the
call does not expect, or no response came.

`status` is `nothing` when no response came (a connect failure, a timeout). `url` leaves
out the query of a presigned URL, which holds a signature. `detail` holds the text of
the server's error, when it sent one.
"""
Base.@kwdef struct TransportError <: ChainTablesError
    method::String
    url::String
    status::Union{Nothing, Int}
    detail::String = ""
end

# A response whose status the verb does not expect. S3's and STS's error document gives
# its code and message.
function TransportError(method::AbstractString, url::AbstractString, response)
    detail = error_document_text(response.body)
    return TransportError(; method, url, response.status, detail)
end

# No response came: a connect failure, a timeout, TLS.
function TransportError(
        method::AbstractString, url::AbstractString, failure::Downloads.RequestError
    )
    detail = "no response: $(failure.message)"
    return TransportError(; method, url, status = nothing, detail)
end

# The form of the gateway and attachment throw sites not yet rewritten: the message
# names the method and the URL, so the two fields are empty.
# TODO: delete with the last such site:
# https://github.com/jonalm/julia_codestyle/issues/130
function TransportError(message::String; status = nothing)
    return TransportError(; method = "", url = "", status, detail = message)
end

function Base.showerror(io::IO, e::TransportError)
    print_summary(io, e, "a request failed.")
    print_evidence(io, e)
    print(io, TRANSPORT_NEXT_MOVES[is_retryable(e)])
    return nothing
end

# No response, a `5xx`, a `409` and a `429` are retried (ADR-0010, ADR-0028). Every
# other status is not, an authorisation `4xx` above all. A `412` never gets here: the
# store returns it as a `PutOutcome`.
function is_retryable(e::TransportError)
    status = e.status
    status === nothing && return true
    return 500 <= status < 600 || status == 409 || status == 429
end

# A predicate over any exception that a `catch` hands on: only the transport's own word
# is retried.
is_retryable(e) = false

function error_document_text(body::AbstractVector{UInt8})
    text = String(copy(body))
    code = match(r"<Code>([^<]*)</Code>", text)
    code === nothing && return ""
    message = match(r"<Message>([^<]*)</Message>", text)
    message === nothing && return xml_unescape(code[1])
    return xml_unescape(code[1]) * ": " * xml_unescape(message[1])
end
