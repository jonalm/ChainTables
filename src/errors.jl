# A type is never split: a caller that catches it would miss the new type. So a type
# whose cases differ keeps one summary, and `detail` says which case it is.
"""
    ChainTablesError

The supertype of every error type that a caller of ChainTables may catch.

`showerror` of a concrete type writes what happened, the evidence and the next move.
The evidence is the type's fields; `detail` holds what no field says.
"""
abstract type ChainTablesError <: Exception end

const ClientVersions = @NamedTuple{lib::String, julia::String}

function print_summary(io::IO, e::ChainTablesError, summary)
    println(io, nameof(typeof(e)), ": ", summary)
    isempty(e.detail) || println(io, e.detail)
    return nothing
end

function print_evidence(io::IO, e::ChainTablesError)
    foreach(name -> print_field(io, name, getfield(e, name)), evidence_names(e))
    return nothing
end

evidence_names(e::ChainTablesError) = filter(!=(:detail), fieldnames(typeof(e)))

print_field(io::IO, name::Symbol, ::Nothing) = nothing

function print_field(io::IO, name::Symbol, value)
    println(io, "  ", name, " = ", evidence_text(value))
    return nothing
end

evidence_text(value) = string(value)
evidence_text(hash::ChainHash) = bytes2hex(hash)
evidence_text(cause::Exception) = sprint(showerror, cause)
evidence_text(client::ClientVersions) = "$(client.lib) on Julia $(client.julia)"

# The form of the throw sites not yet rewritten: the whole message, then the evidence,
# with a hash as raw bytes. The message becomes `detail`.
# TODO: delete with the last such site:
# https://github.com/jonalm/julia_codestyle/issues/130
function (::Type{T})(message::String; evidence...) where {T <: ChainTablesError}
    given = values(evidence)
    field_types = map(name -> fieldtype(T, name), keys(given))
    typed = map(typed_evidence, field_types, Tuple(given))
    return T(; detail = message, NamedTuple{keys(given)}(typed)...)
end

typed_evidence(::Type, value) = value

function typed_evidence(::Type{Union{Nothing, TransactionHash}}, bytes::Vector{UInt8})
    return TransactionHash(bytes)
end

function typed_evidence(::Type{Union{Nothing, StateFingerprint}}, bytes::Vector{UInt8})
    return StateFingerprint(bytes)
end
