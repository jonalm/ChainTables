"""
    repair!(local_copy)

Write the damaged table files of the local copy again from a replay of its records, and
return `(; slot, files_rewritten, attachments_repaired)`.

A record that the record cache lacks or holds other bytes for is fetched from the
store, else `RewrittenChainError`. A replay that does not give the head's tables is
`DivergenceError`, and then nothing is written. The head and the pin stay as they are.
Last, the attachments that the copy confirmed are repaired from the store.

Examples: test/test_repair_examples.jl
"""
function repair!(local_copy::LocalCopy)
    check_open(local_copy)
    head_file = bound_head(local_copy)
    chain = chain_of(local_copy, "repair!")
    hashes = fetch_chain_hashes(local_copy, chain)
    content = replay_named_records(local_copy, chain, hashes)
    verify_head_reproduces(local_copy, content)
    files_rewritten = rewrite_damaged_table_files(local_copy, content)
    attachments_repaired = repair_attachments!(local_copy, chain)
    return (; head_file.slot, files_rewritten, attachments_repaired)
end

# Returns the transaction hash that the chain names for each slot from 0 to the head's.
function fetch_chain_hashes(local_copy::LocalCopy, chain::Chain)
    hashes = Vector{Vector{UInt8}}(undef, local_copy.head.slot + 1)
    read_back_from_head(local_copy, chain; fetch = true) do slot, _, transaction_hash
        hashes[slot + 1] = transaction_hash
        return false
    end
    return hashes
end

# One record at a time, so that the replay never holds all records of the chain. A
# cache file that changed since the read down is fetched again.
function replay_named_records(local_copy::LocalCopy, chain::Chain, hashes)
    content = Model.Content()
    for (i, expected) in enumerate(hashes)
        slot = Int64(i - 1)
        bytes = fetch_named_record(
            chain, slot, expected;
            local_copy.path, local_copy.head.chain_id,
            detail = rewritten_detail(local_copy, slot),
        )
        Ops.apply!(content, Ops.decode_record(bytes; slot))
    end
    return content
end

# A damaged copy is found by hash, so a replay that does not give the head's tables is
# divergence (ADR-0014).
function verify_head_reproduces(local_copy::LocalCopy, content::Model.Content)
    head_file = local_copy.head
    replayed = sort!([name => Model.table_hash(t) for (name, t) in content]; by = first)
    replayed == head_file.tables && return nothing
    throw(
        DivergenceError(;
            local_copy.path, head_file.chain_id, head_file.slot,
            expected = StateFingerprint(head_file.state_fingerprint),
            computed = StateFingerprint(Model.state_fingerprint(replayed)),
            tables = differing_tables(replayed, head_file.tables),
        )
    )
end

function differing_tables(replayed, held)
    ours, theirs = Dict(replayed), Dict(held)
    names = sort!(collect(union(keys(ours), keys(theirs))))
    return filter(name -> get(ours, name, nothing) != get(theirs, name, nothing), names)
end

# Returns the number of table files written. Two tables that share a file count once.
function rewrite_damaged_table_files(local_copy::LocalCopy, content::Model.Content)
    damaged = [
        (; hash, table = content[first(names)])
            for (hash, names) in table_files_of(local_copy.head)
            if hash_table_file(local_copy, hash) != hash
    ]
    foreach(file -> rewrite_table_file(local_copy, file.hash, file.table), damaged)
    return length(damaged)
end

# The one write that replaces a table file, over a damaged or missing one. Every other
# table file is written once (ADR-0009).
function rewrite_table_file(local_copy::LocalCopy, hash, t::Model.Table)
    tmp = temporary_table_path(local_copy)
    try
        written = Base.open(io -> Model.write_table(io, t), tmp, "w")
        written == hash || throw(
            AssertionError(
                "BUG: the replayed table encodes to $(bytes2hex(written)), not to " *
                    "$(bytes2hex(hash)), the hash its replay gave"
            )
        )
        mv(tmp, table_path(local_copy, hash); force = true)
    finally
        rm(tmp; force = true)
    end
    return nothing
end
