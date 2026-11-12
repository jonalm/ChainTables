# Over 8 lines: what is rewritten, and what is refused, is the contract.
"""
    repair!(copy)

Repair a damaged copy in place: replay the record cache to the head's slot in memory and,
when every table hashes as the head names it, rewrite only the table files whose bytes do
not hash to their name. Then repair the attachments the copy confirmed. Return
`(; slot, files_rewritten, attachments_repaired)`; the head and the pin are untouched.

A record the cache lacks or holds other bytes for is fetched again. Throws
`DivergenceError`, writing nothing, when the replay does not reproduce the head, and
`RewrittenChainError` when the store's record does not hash as the chain names it.

Examples: test/test_repair_examples.jl
"""
function repair!(copy::LocalCopy)
    check_open(copy)
    h = copy.head
    h === nothing && throw(ArgumentError(no_head(copy, "repair!(copy)")))
    chain = chain_of(copy, "repair!")
    walk = BackwardWalk(copy, chain, "repair!(copy)", true)
    content = replay_records!(Content(), walked_records(walk), 0, h.slot)
    replayed = sort!([name => table_hash(t) for (name, t) in content]; by = first)
    replayed == h.tables || throw_divergence(copy, replayed)
    damaged = filter(file -> is_damaged_file(copy, first(file)), files_of(h))
    foreach(file -> rewrite_table_file!(copy, content, file), damaged)
    attachments_repaired = repair_attachments!(copy, chain)
    return (; h.slot, files_rewritten = length(damaged), attachments_repaired)
end

function throw_divergence(copy::LocalCopy, replayed)
    h = copy.head
    evidence = (;
        copy.path, h.chain_id, h.slot, expected = h.state_fingerprint,
        computed = state_fingerprint(replayed),
        tables = differing_tables(replayed, h.tables),
        detail = "a fresh replay of the record cache yields other tables than the head",
    )
    throw(DivergenceError(; evidence...))
end

function differing_tables(replayed, held)
    ours, theirs = Dict(replayed), Dict(held)
    names = sort!(unique!([first.(replayed); first.(held)]))
    return filter(name -> get(ours, name, nothing) != get(theirs, name, nothing), names)
end

is_damaged_file(copy::LocalCopy, hash) = table_file_hash(copy, hash) != hash

# The one write that replaces a table file: to a .tmp, checked to hash to the name it is
# about to take, then renamed over the damaged or missing file.
function rewrite_table_file!(copy::LocalCopy, content, file)
    hash, names = file
    t = content[first(names)]
    dir = tables_dir(copy)
    tmp = joinpath(dir, bytes2hex(rand(UInt8, 8)) * ".tmp")
    try
        got = Base.open(io -> write_table(io, t), tmp, "w")
        got == hash || throw(AssertionError("BUG: a replayed table changed under repair!"))
        mv(tmp, joinpath(dir, bytes2hex(hash)); force = true)
    finally
        rm(tmp; force = true)
    end
    return nothing
end
