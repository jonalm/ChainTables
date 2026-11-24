# ADR-0045: after a sync!, a commit whose outcome was unknown happened exactly when the
# copy's commit log shows its hash at its slot.
function resolve_unknowns!(world::SimWorld, client::SimClient)
    log = ChainTables.commit_log(client.copy)
    hashes = Dict(entry.slot => entry.transaction_hash for entry in log)
    append!(world.violations, claim_violations(client.unknowns, hashes, "a commit log"))
    empty!(client.unknowns)
    return nothing
end

function claim_violations(claims::Vector{Claim}, hashes::AbstractDict, source)
    return [
        "$source shows $(get(hashes, claim.slot, "nothing")) at slot $(claim.slot); " *
            "commit! named $(claim.transaction_hash), which the model says is " *
            (claim.holds ? "there" : "not there")
            for claim in claims
            if (get(hashes, claim.slot, nothing) == claim.transaction_hash) != claim.holds
    ]
end

function check_world!(world::SimWorld)
    append!(world.violations, store_violations(world))
    ChainTables.sync!(world.auditor.copy)
    log = ChainTables.commit_log(world.auditor.copy)
    hashes = Dict(entry.slot => entry.transaction_hash for entry in log)
    append!(world.violations, history_violations(world, log))
    append!(world.violations, claim_violations(world.claims, hashes, "the chain"))
    empty!(world.claims)
    for index in eachindex(world.clients)
        append!(world.violations, client_violations(world, hashes, index))
    end
    return nothing
end

# ADR-0002: no gaps, nothing but slots, and no object ever rewritten.
function store_violations(world::SimWorld)
    objects = world.store.objects
    top = top_slot(world.model)
    rewritten = [key for (key, bytes) in world.seen if get(objects, key, nothing) != bytes]
    violations = ["$key was rewritten" for key in rewritten]
    held = sort!(collect(keys(objects)))
    held == [slot_key(slot) for slot in 0:top] ||
        push!(violations, "the store holds $held, not slots 0 to $top")
    mergewith!((first_seen, _) -> first_seen, world.seen, deepcopy(objects))
    return violations
end

function history_violations(world::SimWorld, log)
    model = world.model
    comments = [entry.comment for entry in reverse(log) if entry.slot > 0]
    expected = [commit.comment for commit in model.commits]
    top_rows = rows_at(model, top_slot(model))
    return vcat(
        differences("the chain's history", comments, expected),
        differences("the chain's table", rows_of(world.auditor), top_rows),
    )
end

function client_violations(world::SimWorld, hashes::AbstractDict, index::Integer)
    client = world.clients[index]
    head = ChainTables.head(client.copy)
    slot = world.model.heads[index]
    record = get(hashes, head.slot, nothing)
    return vcat(
        differences("client $index's head slot", head.slot, slot),
        differences("client $index's head record", head.transaction_hash, record),
        differences("client $index's table", rows_of(client), rows_at(world.model, slot)),
    )
end

function differences(what::AbstractString, observed, expected)
    isequal(observed, expected) && return String[]
    return ["$what is $(shown(observed)); the model says $(shown(expected))"]
end

shown(rows::SampleRows) = [Tuple(rows[id]) for id in sort!(collect(keys(rows)))]
shown(value) = value

function rows_of(client::SimClient)
    view = ChainTables.table(client.copy, TABLE)
    return SampleRows(row.id => SampleRow(row) for row in view)
end

# With the faults over, every client reaches the head, every copy verifies, and a replay
# from slot 0 on a machine that saw none of it gives the model's table.
function quiesce!(world::SimWorld)
    for (index, client) in enumerate(world.clients)
        ChainTables.sync!(client.copy)
        world.model.heads[index] = top_slot(world.model)
        resolve_unknowns!(world, client)
        ChainTables.verify(client.copy; full = true)
    end
    check_world!(world)
    append!(world.violations, fresh_replay_violations(world))
    return nothing
end

function fresh_replay_violations(world::SimWorld)
    fresh = open_client(
        world.store, world.dir, "fresh"; cache = "cache-fresh", read_ahead = 8
    )
    try
        ChainTables.sync!(fresh.copy)
        ChainTables.verify(fresh.copy; full = true)
        expected = rows_at(world.model, top_slot(world.model))
        return differences("a fresh replay's table", rows_of(fresh), expected)
    finally
        close(fresh.copy)
    end
end
