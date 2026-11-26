"""
Several independent clients agree on the content of a set of tables without a server,
through a hash-chained sequence of immutable records in an S3 bucket. Terms: see
`CONTEXT.md`.
"""
module ChainTables

using SHA: SHA
using Tables: Tables

public AbstractObjectStore, AttachmentAbsentError, AttachmentCacheError,
    AttachmentChangedError, AttachmentDigestError, AttachmentURLExpiredError, CBOR,
    Chain, ChainNotFoundError, ChainTablesError, CommitOutcomeUnknownError,
    DivergenceError, FingerprintMismatchError, GatewayMismatchError,
    GatewaySessionEndingError, LayoutVersionError, LocalCopy,
    LocalCopyInconsistentError, LostRaceError, MalformedRecordError, Model,
    NotALocalCopyError, ObjectMeta, Ops, PinnedCopyError, PutOutcome, RecordCacheError,
    RewrittenChainError, StaleHeadError, StateFingerprint, TableDeclaration, TableView,
    TransactionHash, UnsupportedStoreError, WriteBuilder, WriteBuilderError,
    WriteRefusedError, WrongChainError, add_column!, as_of, cache_namespace,
    chain_id_bytes, chain_id_string, column!, commit!, commit_log, create_chain,
    create_table!, delete_rows!, drop_column!, drop_table!, fetch_object, head,
    insert_rows!, is_pinned, ispinned, list_objects, open, primary_key!,
    put_object_if_absent, record_author, repair!, shape, slot_at, stat_object, sync!,
    table, table_with_slots, tables, try_create_chain, unpin!, update_rows!, verify,
    write_builder

include("hashes.jl")
include("errors.jl")
include("commit_errors.jl")
include("chain_errors.jl")
include("local_copy_errors.jl")
include("gateway_errors.jl")
include("attachment_errors.jl")
include("CBOR/CBOR.jl")
include("Model/Model.jl")
include("Ops/Ops.jl")
include("chain_id_text.jl")
include("head_file.jl")
include("table_view.jl")
include("local_copy.jl")
include("table_files.jl")
include("views.jl")
include("row_sets.jl")
include("write_builder.jl")
include("row_ops.jl")
include("object_store.jl")
include("record_cache.jl")
include("chain.jl")
include("chain_records.jl")
include("put_record.jl")
include("create_chain.jl")
include("read_forward.jl")
include("sync.jl")
include("commit.jl")
include("read_back.jl")
include("verify.jl")
include("repair.jl")
include("as_of.jl")
include("slot_at.jl")
include("commit_log.jl")
include("s3.jl")
include("gateway.jl")
include("bucket.jl")
include("attachments.jl")
include("Testing.jl")

end
