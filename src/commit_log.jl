const LogEntry = @NamedTuple{
    slot::Int64, transaction_hash::TransactionHash, author::Union{Nothing, String},
    host::Union{Nothing, String}, time_ms::Int64, comment::Union{Nothing, String},
}

"""
    commit_log(local_copy; last = nothing)

Return the commit log of the local copy: one entry per transaction record from its head
down to slot 0, or the `last` newest of them.

Each entry is `(; slot, transaction_hash, author, host, time_ms, comment)`. `author`,
`host` and `comment` are `nothing` when the record has none; `time_ms` is the
committer's clock. The log ends at the copy's head: `sync!` first for the newest
commits. A record that the record cache lacks or holds other bytes for is fetched from
the store, else `RewrittenChainError`.

Examples: test/test_commit_log_examples.jl
"""
function commit_log(local_copy::LocalCopy; last = nothing)
    check_open(local_copy)
    check_log_length(last)
    head_file = bound_head(local_copy)
    chain = chain_of(local_copy, "commit_log")
    n = last === nothing ? head_file.slot + 1 : min(Int64(last), head_file.slot + 1)
    return read_log_entries(local_copy, chain, n)
end

check_log_length(::Nothing) = nothing

function check_log_length(last)
    last isa Integer || throw(ArgumentError("last is an Integer or nothing, got $last"))
    last >= 1 || throw(ArgumentError("last is at least 1, got $last"))
    return nothing
end

# The records are read down from the head and held against the hashes that name them,
# so the log is what the copy applied (ADR-0044).
function read_log_entries(local_copy::LocalCopy, chain::Chain, n)
    entries = LogEntry[]
    read_back_from_head(local_copy, chain; fetch = true) do slot, record, transaction_hash
        push!(entries, log_entry(slot, record, transaction_hash))
        return length(entries) == n
    end
    return entries
end

function log_entry(slot, record::Ops.Record, transaction_hash)
    client = record.client
    return (;
        slot, transaction_hash = TransactionHash(transaction_hash), author = client.user,
        client.host, client.time_ms, record.comment,
    )
end
