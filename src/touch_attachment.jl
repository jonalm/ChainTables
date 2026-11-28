"""
    touch_attachment(chain, hash)

Extend the retention of the attachment `hash` of `chain` before a row refers to it again,
so that the row never outlives it. `hash` is its SHA-256 in 64 lowercase hex, as
`put_attachment` returned it.

A plain bucket keeps no retention, so there it only checks that the bucket holds the
attachment. On a gateway bucket the mint route finds it present and extends the
retention. A failure that may pass is retried as `put_attachment` retries it.

Throws `AttachmentAbsentError` when the bucket does not hold it. On a gateway bucket it
also throws `WriteRefusedError` and `GatewayMismatchError`.

Examples: test/test_touch_attachment_examples.jl
"""
function touch_attachment(chain::Chain, h::AbstractString)
    check_attachment_hash(h)
    key = attachment_key(chain, h)
    with_retries(() -> touch_stored_attachment(chain.store, key)) && return nothing
    throw(
        AttachmentAbsentError(;
            chain.bucket, chain.prefix, key,
            detail = "it was never put, or its retention ended and it was deleted",
        )
    )
end

# `false` when `store` lacks `key`, else `true`, having extended the attachment's
# retention where the store keeps one.
function touch_stored_attachment(store::AbstractObjectStore, key::String)
    return stat_object(store, key) !== nothing
end

# A HEAD first, so that an absent attachment fails and the mint gets the size that its
# `present` answer needs.
function touch_stored_attachment(store::GatewayObjectStore, key::String)
    meta = stat_object(store.s3, key)
    meta === nothing && return false
    answer = mint(store, key, meta.size)
    answer isa MintPresent || throw(
        GatewayMismatchError(
            store, key;
            detail = "the bucket holds the attachment, and the gateway found it absent " *
                "and minted a URL to upload it, so it extended no retention",
        )
    )
    return true
end
