# Temporary during the rewrite: the old `T(msg; evidence...)` call form, so throw sites
# not yet rewritten still build their error. Deleted before the rewrite is merged.
for T in (
        :StaleHeadError, :LostRaceError, :CommitOutcomeUnknownError, :UnsupportedStoreError,
        :WriteBuilderError, :ChainNotFoundError, :RewrittenChainError, :MalformedRecordError,
        :WriteRefusedError, :GatewayMismatchError, :PinnedCopyError, :FingerprintMismatchError,
        :DivergenceError, :NotALocalCopyError, :LayoutVersionError, :WrongChainError,
        :LocalCopyInconsistentError, :RecordCacheError, :AttachmentChangedError,
        :AttachmentURLExpiredError, :GatewaySessionEndingError, :AttachmentAbsentError,
        :AttachmentDigestError, :AttachmentCacheError,
    )
    @eval $T(detail::AbstractString; evidence...) = $T(; detail = String(detail), evidence...)
end
