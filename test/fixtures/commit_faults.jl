using ChainTables: ChainTables, Chain, ChainTablesError, CommitOutcomeUnknownError,
    LostRaceError, StaleHeadError, TransactionHash, TransportError
using ChainTables.Testing: InMemoryObjectStore
using Random: AbstractRNG
using StableRNGs: StableRNG

const BUCKET = "bkt"
const PREFIX = "sim"
const TABLE = :samples
const CREATE_COMMENT = "create samples"

# No host or user in the records, so a trace does not depend on the machine it runs on.
const ANONYMOUS = (; record_host = false, record_user = false)

# "The record hashing to `transaction_hash` is at `slot`", which holds or does not.
const Claim = @NamedTuple{slot::Int64, transaction_hash::TransactionHash, holds::Bool}

# Stands in for the process dying: unlike InterruptException, a testset that sees it
# escape records an error and runs on.
struct SimulatedCrash <: Exception end

mutable struct SimClient{C, L}
    const chain::C
    const path::String
    copy::L                         # replaced when the client restarts
    const unknowns::Vector{Claim}   # commits that ended unknown, until the next sync!
end

struct SimWorld{C}
    dir::String
    store::InMemoryObjectStore
    clients::Vector{C}
    auditor::C                          # follows the chain; never commits after genesis
    model::ChainModel
    seen::Dict{String, Vector{UInt8}}   # every object the store has held, as first seen
    claims::Vector{Claim}               # what this step's commits said about the chain
    violations::Vector{String}
    outcomes::Vector{Outcome}
    unknown_landed::Vector{Bool}        # per unknown outcome: whether the record had landed
end

# The store's `fault` hook for one commit!, following the commit's FaultPlan.
mutable struct Injector{R}
    const faults::FaultPlan
    const put_key::String       # the slot the commit puts its record to
    const head_key::String      # the head's own slot, which the pre-check fetches
    const land_rival::R
    n_puts::Int
    n_readbacks::Int
end

# The store's `fault` hook for one sync!: one request of `verb` times out.
mutable struct ReadFault
    const verb::Symbol
    const request::Int
    n_requests::Int
end

struct TraceFailure
    seed::Int
    steps::Vector{Any}
    violations::Vector{String}
end

function Base.show(io::IO, failure::TraceFailure)
    println(io, "seed $(failure.seed) left the model at step $(length(failure.steps)):")
    println(io, join(("  " * violation for violation in failure.violations), "\n"))
    println(io, "steps:")
    steps = ("  $index: $step" for (index, step) in enumerate(failure.steps))
    return print(io, join(steps, "\n"))
end

"""
    run_trace(seed; n_steps = 40) -> (; failure, outcomes, unknown_landed)

Run `n_steps` random commits, syncs and restarts of $N_CLIENTS clients over one chain,
with faults injected into the store, checking the store and every local copy against the
reference model after each step. `failure` is `nothing`, or the `TraceFailure` naming the
seed, the steps and what disagreed; the same seed runs the same trace.
"""
function run_trace(seed::Integer; n_steps = 40)
    rng = StableRNG(seed)
    return with_world(world -> run_steps!(rng, world, seed, n_steps), rng)
end

function with_world(f::F, rng::AbstractRNG) where {F}
    return mktempdir() do dir
        world = new_world(rng, dir)
        try
            return f(world)
        finally
            foreach(client -> close(client.copy), [world.clients; world.auditor])
        end
    end
end

function new_world(rng::AbstractRNG, dir::AbstractString)
    store = InMemoryObjectStore(; seed = rand(rng, UInt64))
    # ADR-0040: clients on one machine share a record cache; the last one has its own.
    caches = [index < N_CLIENTS ? "cache-shared" : "cache-own" for index in 1:N_CLIENTS]
    clients = [
        open_client(store, dir, "client-$index"; cache, read_ahead = rand(rng, (1, 2, 8)))
            for (index, cache) in enumerate(caches)
    ]
    auditor = open_client(store, dir, "auditor"; cache = "cache-auditor", read_ahead = 8)
    ChainTables.create_chain(auditor.chain)
    create_samples_table!(first(clients))
    foreach(client -> ChainTables.sync!(client.copy), clients)
    model = ChainModel([ModelCommit(CREATE_COMMENT, SampleRows())], fill(1, N_CLIENTS))
    seen = Dict{String, Vector{UInt8}}()
    return SimWorld(
        dir, store, clients, auditor, model, seen, Claim[], String[], Outcome[], Bool[]
    )
end

function open_client(store::InMemoryObjectStore, dir, name; cache, read_ahead)
    cache_dir = joinpath(dir, cache)
    chain = Chain(BUCKET, PREFIX; store, cache_dir, read_ahead, ANONYMOUS...)
    path = joinpath(dir, name)
    return SimClient(chain, path, ChainTables.open(chain, path), Claim[])
end

function create_samples_table!(client::SimClient)
    ChainTables.sync!(client.copy)
    builder = ChainTables.write_builder(client.copy)
    ChainTables.create_table!(builder, TABLE) do table
        ChainTables.column!(table, :id, Int64)
        ChainTables.column!(table, :label, String)
        ChainTables.column!(table, :mass, Float64; nullable = true)
        ChainTables.primary_key!(table, :id)
    end
    ChainTables.commit!(builder; comment = CREATE_COMMENT)
    return nothing
end

function run_steps!(rng::AbstractRNG, world::SimWorld, seed::Integer, n_steps::Integer)
    steps = Any[]
    for index in 1:n_steps
        push!(steps, random_step(rng, world.model, index))
        run_step!(world, last(steps))
        check_world!(world)
        isempty(world.violations) || return trace_result(world, seed, steps)
    end
    push!(steps, "sync every client, verify, replay afresh")
    quiesce!(world)
    return trace_result(world, seed, steps)
end

function trace_result(world::SimWorld, seed::Integer, steps)
    violations = copy(world.violations)
    failure = isempty(violations) ? nothing : TraceFailure(seed, steps, violations)
    return (; failure, world.outcomes, world.unknown_landed)
end

function run_step!(world::SimWorld, plan::CommitPlan)
    client = world.clients[plan.client]
    aimed = ChainTables.head(client.copy).slot + 1
    expected = expected_commit!(world.model, plan)
    observed = commit_with_faults!(world, client, plan, aimed)
    push!(world.outcomes, observed.outcome)
    observed.outcome == expected || push!(
        world.violations,
        "commit! by client $(plan.client) ended as $(outcome_text(observed.outcome)); " *
            "the model says $(outcome_text(expected)). $(observed.message)",
    )
    note_claim!(world, client, plan, observed)
    # A process that died holds no copy: the client starts again from what is on disk.
    observed.outcome.detail == (nothing, :SimulatedCrash) && restart!(client)
    return nothing
end

function run_step!(world::SimWorld, plan::SyncPlan)
    client = world.clients[plan.client]
    before = world.model.heads[plan.client]
    top = top_slot(world.model)
    _is_synced = sync_with_fault!(world, client, plan.fault)
    slot = ChainTables.head(client.copy).slot
    # ADR-0013: a failed sync! leaves the copy at a checkpoint, anywhere up to the head.
    world.model.heads[plan.client] = slot
    (_is_synced ? slot == top : before <= slot <= top) || push!(
        world.violations,
        "sync! by client $(plan.client) $(_is_synced ? "returned" : "failed") with the " *
            "copy at slot $slot; it was at slot $before and the chain is at slot $top",
    )
    _is_synced && resolve_unknowns!(world, client)
    return nothing
end

function run_step!(world::SimWorld, plan::RestartPlan)
    restart!(world.clients[plan.client])
    return nothing
end

# The old copy is dropped unclosed, as a dead process leaves it.
function restart!(client::SimClient)
    client.copy = ChainTables.open(client.chain, client.path)
    return nothing
end

function commit_with_faults!(world::SimWorld, client::SimClient, plan::CommitPlan, aimed)
    builder = builder_for(client, plan.write)
    heads = joinpath(client.path, "heads")
    land_rival = () -> land_rival!(world, plan)
    put_key, head_key = slot_key(aimed), slot_key(aimed - 1)
    world.store.fault = Injector(plan.faults, put_key, head_key, land_rival, 0, 0)
    plan.faults.head_unwritable && chmod(heads, 0o555)
    try
        result = ChainTables.commit!(builder; comment = plan.write.comment)
        committed = outcome(:committed, result.slot, nothing)
        return (; outcome = committed, result.transaction_hash, message = "")
    catch e
        e isa Union{ChainTablesError, TransportError} || rethrow()
        return observed_failure(e, aimed)
    finally
        chmod(heads, 0o755)
        world.store.fault = no_fault
    end
end

function builder_for(client::SimClient, write::WritePlan)
    builder = ChainTables.write_builder(client.copy)
    deletes = [(; id) for id in write.deletes]
    isempty(write.inserts) || ChainTables.insert_rows!(builder, TABLE, write.inserts)
    isempty(write.updates) || ChainTables.update_rows!(builder, TABLE, write.updates)
    isempty(deletes) || ChainTables.delete_rows!(builder, TABLE, deletes)
    return builder
end

# ADR-0011: the slot key is the prefix and the slot as 12 digits.
slot_key(slot::Integer) = PREFIX * "/" * lpad(slot, 12, '0')

no_fault(verb, key, phase) = nothing

function (injector::Injector)(verb::Symbol, key::String, phase::Symbol)
    _is_put = verb === :put_object_if_absent && key == injector.put_key
    _is_put && return inject_put!(injector, phase)
    verb === :fetch_object && phase === :before && return inject_fetch!(injector, key)
    return nothing
end

function inject_put!(injector::Injector, phase::Symbol)
    phase === :before && return inject_before_put!(injector)
    event = get(injector.faults.puts, injector.n_puts, :ok)
    event === :lost_ack &&
        throw(TransportError(; method = "PUT", url = injector.put_key, status = nothing))
    event === :crash_after && throw(SimulatedCrash())
    return nothing
end

function inject_before_put!(injector::Injector)
    injector.n_puts += 1
    injector.n_puts == injector.faults.rival_before_put && injector.land_rival()
    event = get(injector.faults.puts, injector.n_puts, :ok)
    event === :crash_before && throw(SimulatedCrash())
    url = injector.put_key
    haskey(RETRIED_STATUS, event) &&
        throw(TransportError(; method = "PUT", url, status = RETRIED_STATUS[event]))
    haskey(REFUSED_STATUS, event) &&
        throw(TransportError(; method = "PUT", url, status = REFUSED_STATUS[event]))
    return nothing
end

function inject_fetch!(injector::Injector, key::String)
    _is_precheck = key == injector.head_key && injector.faults.precheck_times_out
    _is_precheck && throw(TransportError(; method = "GET", url = key, status = nothing))
    key == injector.put_key || return nothing
    injector.n_readbacks += 1
    event = get(injector.faults.readbacks, injector.n_readbacks, :ok)
    event === :timeout &&
        throw(TransportError(; method = "GET", url = key, status = nothing))
    return nothing
end

# Runs inside the victim's put, as another client's commit would land during it.
function land_rival!(world::SimWorld, plan::CommitPlan)
    injector = world.store.fault
    rival = world.clients[plan.rival]
    world.store.fault = no_fault
    try
        ChainTables.sync!(rival.copy)
        resolve_unknowns!(world, rival)
        builder = builder_for(rival, plan.rival_write)
        result = ChainTables.commit!(builder; comment = plan.rival_write.comment)
        push!(world.claims, Claim((result.slot, result.transaction_hash, true)))
    finally
        world.store.fault = injector
    end
    return nothing
end

function observed_failure(e::StaleHeadError, aimed)
    return observed(outcome(:stale_head, e.slot, e.chain_slot), nothing, e)
end
function observed_failure(e::LostRaceError, aimed)
    return observed(outcome(:lost_race, e.slot, nothing), e.transaction_hash, e)
end
function observed_failure(e::CommitOutcomeUnknownError, aimed)
    cause = nameof(typeof(e.cause))
    return observed(unknown(e.slot, e.landed, cause), e.transaction_hash, e)
end
function observed_failure(e::TransportError, aimed)
    return observed(outcome(:transport, aimed, e.status), nothing, e)
end
# Any other error type is one the model never expects: the mismatch names it.
function observed_failure(e::ChainTablesError, aimed)
    return observed(outcome(nameof(typeof(e)), aimed, nothing), nothing, e)
end

function observed(outcome::Outcome, transaction_hash, e::Exception)
    return (; outcome, transaction_hash, message = sprint(showerror, e))
end

# What the commit said about the chain, to hold against the chain itself (check_world!)
# and, for an unknown outcome, against the client's own commit log after its next sync!.
function note_claim!(world::SimWorld, client::SimClient, plan::CommitPlan, observed)
    hash = observed.transaction_hash
    hash === nothing && return nothing
    slot = observed.outcome.slot
    _is_ours = holds(world.model, slot, plan.write.comment)
    _is_unknown = observed.outcome.kind === :unknown
    # a lost race names the record that is there; a commit, its own; an unknown, either
    push!(world.claims, Claim((slot, hash, _is_ours || !_is_unknown)))
    _is_unknown || return nothing
    push!(client.unknowns, Claim((slot, hash, _is_ours)))
    push!(world.unknown_landed, _is_ours)
    return nothing
end

function (fault::ReadFault)(verb::Symbol, key::String, phase::Symbol)
    (verb === fault.verb && phase === :before) || return nothing
    fault.n_requests += 1
    fault.n_requests == fault.request &&
        throw(TransportError(; method = "GET", url = key, status = nothing))
    return nothing
end

function sync_with_fault!(world::SimWorld, client::SimClient, fault)
    hook = fault === nothing ? no_fault : ReadFault(fault.verb, fault.request, 0)
    world.store.fault = hook
    try
        ChainTables.sync!(client.copy)
        return true
    catch e
        e isa TransportError || rethrow()
        return false
    finally
        world.store.fault = no_fault
    end
end
