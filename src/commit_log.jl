"""
    CommitLogEntry

One transaction record in a commit log: its slot and transaction hash, the record's
author (`client.user`), `client.host` and `client.time_ms`, and its comment. `author`,
`host` and `comment` are `nothing` when the record carries none.
"""
const CommitLogEntry = @NamedTuple{
    slot::Int64, transaction_hash::TransactionHash, author::Union{Nothing, String},
    host::Union{Nothing, String}, time_ms::Int64, comment::Union{Nothing, String},
}

# Over 8 lines: whose history it is, and where the records come from, is the contract.
"""
    commit_log(copy; last = nothing)

Return the local copy's history newest first, as `(; slot, transaction_hash, author,
host, time_ms, comment)` entries: from the copy's head down to slot 0, or the `last`
newest. `time_ms` is milliseconds since the Unix epoch, UTC, by the committer's clock.

The history is the copy's: `sync!(copy)` first for the newest commits. Records come from
the record cache, each held against the hash the one above names; one the cache lacks or
holds other bytes for is fetched from the store, and must hash as named, else
`RewrittenChainError`.

Examples: test/test_commit_log_examples.jl
"""
function commit_log(copy::LocalCopy; last = nothing)
    check_open(copy)
    last === nothing || last isa Integer && last >= 1 ||
        throw(ArgumentError("commit_log: last must be nothing or an Integer ≥ 1: $last"))
    h = copy.head
    h === nothing && throw(ArgumentError(no_head(copy, "commit_log(copy)")))
    chain = chain_of(copy, "commit_log")
    n = last === nothing ? h.slot + 1 : min(Int64(last), h.slot + 1)
    log = CommitLogEntry[]
    walk_back(BackwardWalk(copy, chain, "commit_log(copy)", true)) do s, record, th
        push!(log, commit_log_entry(s, record, th))
        return length(log) == n
    end
    return log
end

function commit_log_entry(slot, record, th)
    c = record.client
    transaction_hash = TransactionHash(th)
    fields = (slot, transaction_hash, c.user, c.host, c.time_ms, record.comment)
    return CommitLogEntry(fields)
end
