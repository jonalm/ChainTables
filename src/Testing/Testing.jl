"""
The in-process object store a user testing their own ChainTables-backed code runs against
instead of AWS: `Testing.InMemoryObjectStore`. Terms: see `CONTEXT.md`.
"""
module Testing

using ..ChainTables: ChainTables, AbstractObjectStore, AttachmentChangedError, ObjectMeta,
    PutOutcome, attachment_hash, startswith_bytes, stream_size
using SHA: sha256

public InMemoryObjectStore

include("in_memory_object_store.jl")

end
