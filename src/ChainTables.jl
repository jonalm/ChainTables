"""
Several clients agree on a set of tables without a server, through a hash-chained
sequence of records in an S3 bucket. Terms: see `CONTEXT.md`.
"""
module ChainTables

using SHA: SHA

public AbstractObjectStore, AttachmentAbsentError, AttachmentCacheError,
    AttachmentChangedError, AttachmentDigestError, AttachmentURLExpiredError, Bucket, CBOR,
    Chain, ChainNotFoundError, ChainTablesError, CommitOutcomeUnknownError, Credentials,
    DivergenceError, FingerprintMismatchError, GatewayMismatchError, GatewayObjectStore,
    GatewaySessionEndingError, LayoutVersionError, LocalCopy, LocalCopyInconsistentError,
    LostRaceError, MalformedRecordError, NotALocalCopyError, ObjectMeta, Ops,
    PinnedCopyError, PutOutcome, RecordCacheError, RewrittenChainError, S3ObjectStore,
    StaleHeadError, StateFingerprint, TableView, Testing, TransactionHash, TransportError,
    UnsupportedStoreError, WriteBuilderError, WriteRefusedError, WrongChainError,
    add_column!, as_of, attachment, cache_namespace, column!, commit!, commit_log,
    create_chain, create_table!, delete_rows!, drop_column!, drop_table!, fetch_object,
    head, insert_rows!, is_pinned, list_objects, open, pin!, primary_key!, put_attachment,
    put_object_if_absent, record_author, repair!, shape, slot_at, sso_credentials,
    sso_login, stat_object, sync!, table, table_with_slots, tables, touch_attachment,
    try_create_chain, unpin!, update_rows!, verify, write_builder

abstract type AbstractObjectStore end

# Layout follows the build order of #34 §3. Nothing is exported (ADR-0019).
# errors.jl comes first so every lane raises the same types (ADR-0020).

include("hashes.jl")     # step 8: TransactionHash, StateFingerprint (ADR-0019)
include("errors.jl")
include("local_copy_errors.jl")
include("attachment_errors.jl")
include("legacy_error_constructors.jl")
include("cbor.jl")       # step 1
include("model.jl")      # step 2
include("ops.jl")        # step 3
include("builder.jl")    # step 4
include("localcopy.jl")  # steps 5, 8
include("views.jl")      # step 8: TableView, table, shape (ADR-0024)
include("store.jl")      # steps 6, 7
include("chain.jl")      # step 7: Chain, create_chain, sync!, commit!
include("recovery.jl")   # step 8: verify, repair!, as_of, slot_at (ADR-0014, ADR-0015)
include("s3.jl")         # step 9
include("gateway.jl")    # ADR-0028: GatewayObjectStore, the author from STS, the 4 MiB cap
include("bucket.jl")     # ADR-0029: Bucket, Chain(bucket, prefix)
include("attachments.jl") # ADR-0046: put_attachment on each store, the mint route
include("Testing.jl")    # step 6

end # module ChainTables
