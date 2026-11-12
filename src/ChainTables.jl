"""
Several clients agree on a set of tables without a server, through a hash-chained
sequence of records in an S3 bucket. Terms: see `CONTEXT.md`.
"""
module ChainTables

using Base64: Base64
using Downloads: Downloads
using SHA: SHA, hmac_sha256, sha256
using Tables: Tables

public AbstractObjectStore, AttachmentAbsentError, AttachmentCacheError,
    AttachmentChangedError, AttachmentDigestError, AttachmentURLExpiredError, Bucket,
    CBOR, Chain, ChainNotFoundError, ChainTablesError, CommitOutcomeUnknownError,
    Credentials, CredentialsError, DivergenceError, FingerprintMismatchError,
    GatewayMismatchError, GatewayObjectStore, GatewaySessionEndingError,
    LayoutVersionError, LocalCopy, LocalCopyInconsistentError, LostRaceError,
    MalformedRecordError, NotALocalCopyError, ObjectMeta, Ops, PinnedCopyError,
    PutOutcome, RecordCacheError, RewrittenChainError, S3ObjectStore, StaleHeadError,
    StateFingerprint, TableView, Testing, TransactionHash, TransportError,
    UnsupportedStoreError, WriteBuilderError, WriteRefusedError, WrongChainError,
    add_column!, as_of, attachment, cache_namespace, column!, commit!, commit_log,
    create_chain, create_table!, delete_rows!, drop_column!, drop_table!, fetch_object,
    head, insert_rows!, is_pinned, list_objects, open, pin!, primary_key!,
    put_attachment, put_object_if_absent, record_author, repair!, shape, slot_at,
    sso_credentials, sso_login, stat_object, sync!, table, table_with_slots, tables,
    touch_attachment, try_create_chain, unpin!, update_rows!, verify, write_builder

abstract type AbstractObjectStore end

# Layout follows the build order of #34 §3. Nothing is exported (ADR-0019).
# errors.jl comes first so every lane raises the same types (ADR-0020).

include("hashes.jl")
include("errors.jl")
include("local_copy_errors.jl")
include("attachment_errors.jl")
include("legacy_error_constructors.jl")
include("CBOR/CBOR.jl")
include("model_error.jl")
include("shape.jl")
include("row_checks.jl")
include("table.jl")
include("content.jl")
include("table_file.jl")
include("fingerprint.jl")
include("Ops/Ops.jl")
include("builder.jl")
include("row_sets.jl")
include("chain_id_text.jl")
include("head_file.jl")
include("table_view.jl")
include("local_copy.jl")
include("table_files.jl")
include("views.jl")
include("store.jl")      # steps 6, 7
include("chain.jl")      # step 7: Chain, create_chain, sync!, commit!
include("recovery.jl")   # step 8: verify, repair!, as_of, slot_at (ADR-0014, ADR-0015)
include("credentials.jl")
include("sso.jl")
include("dates.jl")
include("sigv4.jl")
include("http.jl")
include("s3_store.jl")
include("gateway.jl")
include("gateway_reply.jl")
include("gateway_author.jl")
include("bucket.jl")
include("attachments.jl")
include("gateway_attachments.jl")
include("attachment_cache.jl")
include("attachment_repair.jl")
include("Testing/Testing.jl")

end # module ChainTables
