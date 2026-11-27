"""
Several independent clients agree on the content of a set of tables without a server,
through a hash-chained sequence of immutable records in an S3 bucket. Terms: see
`CONTEXT.md`.
"""
module ChainTables

using Base64: base64encode
using Downloads: Downloads
using SHA: SHA, sha256
using Tables: Tables

public AbstractObjectStore, AttachmentAbsentError, AttachmentCacheError,
    AttachmentChangedError, AttachmentDigestError, AttachmentURLExpiredError, Bucket, CBOR,
    Chain, ChainNotFoundError, ChainTablesError, CommitOutcomeUnknownError, Credentials,
    CredentialsExportError, DivergenceError, FingerprintMismatchError, GatewayMismatchError,
    GatewaySessionEndingError, LayoutVersionError, LocalCopy, LocalCopyInconsistentError,
    LoginError, LostRaceError, MalformedRecordError, Model, NotALocalCopyError, ObjectMeta,
    Ops, PinnedCopyError, ProfileCredentials, PutOutcome, RecordCacheError,
    RewrittenChainError, SigV4, StaleHeadError, StateFingerprint, TableDeclaration,
    TableView, Testing, TransactionHash, TransportError, UnsupportedStoreError,
    WriteBuilder, WriteBuilderError, WriteRefusedError, WrongChainError, add_column!, as_of,
    attachment, cache_namespace, chain_id_bytes, chain_id_string, column!, commit!,
    commit_log, create_chain, create_table!, delete_rows!, drop_column!, drop_table!,
    fetch_object, head, insert_rows!, is_pinned, ispinned, list_objects, open, primary_key!,
    put_attachment, put_object_if_absent, record_author, repair!, shape, slot_at,
    sso_credentials, sso_login, stat_object, sync!, table, table_with_slots, tables,
    touch_attachment, try_create_chain, unpin!, update_rows!, verify, write_builder

include("hashes.jl")
include("errors.jl")
include("commit_errors.jl")
include("chain_errors.jl")
include("local_copy_errors.jl")
include("gateway_errors.jl")
include("attachment_errors.jl")
include("transport_errors.jl")
include("credential_errors.jl")
include("CBOR/CBOR.jl")
include("Model/Model.jl")
include("Ops/Ops.jl")
include("SigV4/SigV4.jl")
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
include("unix_dates.jl")
include("credentials.jl")
include("aws_cli.jl")
include("sso_login.jl")
include("sso_credentials.jl")
include("http_transport.jl")
include("s3_object_store.jl")
include("gateway_reply.jl")
include("gateway_object_store.jl")
include("gateway_author.jl")
include("bucket.jl")
include("store_gate.jl")
include("attachment_keys.jl")
include("put_attachment.jl")
include("gateway_attachment.jl")
include("touch_attachment.jl")
include("attachment_cache.jl")
include("read_attachment.jl")
include("attachment_repair.jl")
include("Testing/Testing.jl")

end
