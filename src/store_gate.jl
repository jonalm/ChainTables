# The gate of ADR-0016: on a store that may replace a key, a put would split the chain.
# So `commit!` and `create_chain` refuse such a store before anything is applied or
# written, unless the chain makes the promise for it.
function check_supported_store(chain::Chain, call::AbstractString)
    (is_unsupported_store(chain.store) && !chain.assume_first_writer_wins) && throw(
        UnsupportedStoreError(;
            endpoint = s3_half(chain.store).endpoint, detail = "the call was `$call`",
        )
    )
    return nothing
end

# A gateway store is judged by its S3 half: the reads and the read-back go there
# (ADR-0028). A store of the caller's own is not judged.
is_unsupported_store(store::Union{S3ObjectStore, GatewayObjectStore}) = !is_aws(store)
is_unsupported_store(::AbstractObjectStore) = false
