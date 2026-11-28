"""
An object store in memory, `Testing.InMemoryObjectStore`, for the tests of code that
uses ChainTables.
"""
module Testing

using SHA: sha256
using ..ChainTables: ChainTables, AbstractObjectStore, AttachmentChangedError,
    AttachmentUpload, ObjectMeta, PutOutcome, startswith_bytes

public InMemoryObjectStore

include("in_memory_object_store.jl")

end
