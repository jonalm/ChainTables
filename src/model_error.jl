"""
    ModelError

A rule of the table model is broken: a malformed shape, a cell off its value type, null
in a non-nullable column, an op that contradicts the content, or rows out of key order.
Internal: the write builder reports it as a `WriteBuilderError`, apply as a
`MalformedRecordError`.
"""
struct ModelError <: ChainTablesError
    detail::String
end

ModelError(; detail = "") = ModelError(detail)

function Base.showerror(io::IO, e::ModelError)
    print_summary(io, e, "a rule of the table model is broken")
    print(io, "\nFix the shape, op or row named above.")
    return nothing
end

"""
    fail(detail)

Throw a `ModelError` with `detail`.
"""
# Kept for the write builder and the local copy, which raise the model's rules with it.
fail(detail) = throw(ModelError(; detail))
