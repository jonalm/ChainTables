"""
Several independent clients agree on the content of a set of tables without a server,
through a hash-chained sequence of immutable records in an S3 bucket. Terms: see
`CONTEXT.md`.
"""
module ChainTables

public AttachmentAbsentError, AttachmentCacheError, AttachmentChangedError,
    AttachmentDigestError, AttachmentURLExpiredError, CBOR, ChainNotFoundError,
    ChainTablesError, CommitOutcomeUnknownError, DivergenceError,
    FingerprintMismatchError, GatewayMismatchError, GatewaySessionEndingError,
    LayoutVersionError, LocalCopyInconsistentError, LostRaceError, MalformedRecordError,
    Model, NotALocalCopyError, Ops, PinnedCopyError, RecordCacheError,
    RewrittenChainError, StaleHeadError, StateFingerprint, TransactionHash,
    UnsupportedStoreError, WriteBuilderError, WriteRefusedError, WrongChainError

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
include("builder.jl")
include("localcopy.jl")
include("views.jl")
include("store.jl")
include("chain.jl")
include("recovery.jl")
include("s3.jl")
include("gateway.jl")
include("bucket.jl")
include("attachments.jl")
include("Testing.jl")

end
