"""
    ModelError(detail)

Thrown when a rule of the table model is broken: a malformed shape, a cell of the wrong
value type, null in a non-nullable column, an op that contradicts the content, rows out
of key order.

Internal: the write builder throws it as `WriteBuilderError`, apply as
`MalformedRecordError`, and the read of a table file as `LocalCopyInconsistentError`.
"""
struct ModelError <: Exception
    detail::String
end

# TODO: delete with its last callers, in builder.jl, localcopy.jl and recovery.jl:
# https://github.com/jonalm/julia_codestyle/issues/127
fail(detail) = throw(ModelError(detail))
