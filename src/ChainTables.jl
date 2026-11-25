"""
Several independent clients agree on the content of a set of tables without a server,
through a hash-chained sequence of immutable records in an S3 bucket. Terms: see
`CONTEXT.md`.
"""
module ChainTables

using SHA: SHA
using Tables: Tables

public AttachmentAbsentError, AttachmentCacheError, AttachmentChangedError,
    AttachmentDigestError, AttachmentURLExpiredError, CBOR, ChainNotFoundError,
    ChainTablesError, CommitOutcomeUnknownError, DivergenceError,
    FingerprintMismatchError, GatewayMismatchError, GatewaySessionEndingError,
    LayoutVersionError, LocalCopy, LocalCopyInconsistentError, LostRaceError,
    MalformedRecordError, Model, NotALocalCopyError, Ops, PinnedCopyError,
    RecordCacheError, RewrittenChainError, StaleHeadError, StateFingerprint,
    TableDeclaration, TableView, TransactionHash, UnsupportedStoreError, WriteBuilder,
    WriteBuilderError, WriteRefusedError, WrongChainError, add_column!, chain_id_bytes,
    chain_id_string, column!, create_table!, delete_rows!, drop_column!, drop_table!,
    head, insert_rows!, is_pinned, ispinned, open, primary_key!, shape, table,
    table_with_slots, tables, unpin!, update_rows!

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
include("store.jl")
include("chain.jl")
include("recovery.jl")
include("s3.jl")
include("gateway.jl")
include("bucket.jl")
include("attachments.jl")
include("Testing.jl")

end
