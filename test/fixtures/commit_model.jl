using Random: AbstractRNG, shuffle

const N_CLIENTS = 3
const SAMPLE_IDS = 1:8
const MASSES = (missing, 0.5, 1.5, 2.5)

# ADR-0010: the retry loop issues its conditional put at most this many times.
const PUT_ATTEMPTS = 4

# Put attempts that never reach the store, with the status the transport reports;
# ADR-0010 retries every one of them.
const RETRIED_STATUS =
    (timeout = nothing, unavailable = 503, conflict = 409, throttled = 429)

# Put attempts the store refuses with a client error; ADR-0045: the record was not written.
const REFUSED_STATUS = (forbidden = 403, bad_request = 400)

# Each retried attempt costs the retry loop's real backoff sleep, so most plans have none.
const N_RETRIED = (0, 0, 0, 0, 0, 0, 0, 1, 1, 2, PUT_ATTEMPTS - 1, PUT_ATTEMPTS)
const LAST_PUT =
    (:ok, :ok, :lost_ack, :lost_ack, :crash_after, :crash_before, :forbidden, :bad_request)

# The requests a sync! makes: head discovery probes with one, the replay fetches with
# the other.
const SYNC_VERBS = (:stat_object, :fetch_object)

const SampleRow = @NamedTuple{id::Int64, label::String, mass::Union{Missing, Float64}}
const SampleRows = Dict{Int64, SampleRow}

# How one commit! ended: `kind` is :committed, :stale_head, :lost_race, :unknown or
# :transport; `detail` is the evidence that kind carries.
const Outcome = @NamedTuple{kind::Symbol, slot::Int64, detail::Any}

struct WritePlan
    comment::String             # unique per commit: it names the record in the commit log
    inserts::Vector{SampleRow}
    updates::Vector{SampleRow}
    deletes::Vector{Int64}
    rows::SampleRows            # the table once the ops are applied
end

struct FaultPlan
    precheck_times_out::Bool    # the fetch of the head's own slot fails
    puts::Vector{Symbol}        # one event per put attempt; attempts past the end are :ok
    readbacks::Vector{Symbol}   # one event per read-back; :ok or :timeout
    rival_before_put::Int       # the put attempt a rival lands just before; 0: none
    head_unwritable::Bool
end

const NO_FAULTS = FaultPlan(false, Symbol[], Symbol[], 0, false)

struct CommitPlan
    client::Int
    write::WritePlan
    faults::FaultPlan
    rival::Int                  # commits rival_write if rival_before_put is reached
    rival_write::WritePlan
end

struct SyncPlan
    client::Int
    fault::Union{Nothing, @NamedTuple{verb::Symbol, request::Int}}  # that request times out
end

struct RestartPlan
    client::Int
end

struct ModelCommit
    comment::String
    rows::SampleRows
end

# The reference model: the chain as one sequential history, and where each client is in it.
struct ChainModel
    commits::Vector{ModelCommit}    # commits[slot]; slot 0, the genesis record, is not held
    heads::Vector{Int}              # the slot each client's local copy is at
end

top_slot(model::ChainModel) = length(model.commits)
rows_at(model::ChainModel, slot::Integer) = model.commits[slot].rows

function holds(model::ChainModel, slot::Integer, comment::AbstractString)
    return slot <= top_slot(model) && model.commits[slot].comment == comment
end

outcome(kind::Symbol, slot::Integer, detail) = Outcome((kind, slot, detail))
function outcome_text(o::Outcome)
    return "$(o.kind) at slot $(o.slot)" * (o.detail === nothing ? "" : " $(o.detail)")
end
unknown(slot::Integer, landed, cause::Symbol) = outcome(:unknown, slot, (landed, cause))

"""
    expected_commit!(model, plan) -> Outcome

Apply `plan` to the model as the protocol says a commit under those faults ends
(ADR-0002, ADR-0009, ADR-0010, ADR-0045), and return how `commit!` must report it.
"""
function expected_commit!(model::ChainModel, plan::CommitPlan)
    head = model.heads[plan.client]
    plan.faults.precheck_times_out && return outcome(:transport, head + 1, nothing)
    head < top_slot(model) && return outcome(:stale_head, head, top_slot(model))
    return expected_put!(model, plan, head + 1)
end

# ADR-0010: a put attempt is refused, never arrives, or reaches the store, where it creates
# the record unless the slot is taken. Only a created record that is acknowledged skips
# the read-back, and the read-back alone decides every other attempt.
function expected_put!(model::ChainModel, plan::CommitPlan, slot::Integer)
    faults = plan.faults
    n_readbacks = 0
    for attempt in 1:PUT_ATTEMPTS
        attempt == faults.rival_before_put && land!(model, plan.rival, plan.rival_write)
        event = get(faults.puts, attempt, :ok)
        event === :crash_before && return unknown(slot, nothing, :SimulatedCrash)
        refusal = get(REFUSED_STATUS, event, nothing)
        refusal === nothing || return outcome(:transport, slot, refusal)
        _is_created = top_slot(model) < slot && !haskey(RETRIED_STATUS, event)
        _is_created && land!(model, plan.client, plan.write; head = slot - 1)
        event === :crash_after && return unknown(slot, nothing, :SimulatedCrash)
        _is_created && event === :ok && return expected_head_write!(model, plan, slot)
        n_readbacks += 1
        _is_lost = get(faults.readbacks, n_readbacks, :ok) === :timeout
        _is_lost && return unknown(slot, nothing, :TransportError)
        _is_ours = holds(model, slot, plan.write.comment)
        _is_ours && return expected_head_write!(model, plan, slot)
        top_slot(model) >= slot && return outcome(:lost_race, slot, nothing)
    end
    return unknown(slot, nothing, :TransportError)
end

function expected_head_write!(model::ChainModel, plan::CommitPlan, slot::Integer)
    plan.faults.head_unwritable && return unknown(slot, true, :SystemError)
    model.heads[plan.client] = slot
    return outcome(:committed, slot, nothing)
end

# The record lands at the next slot. The writer's copy follows it there unless `head`
# says where it stays: a record can land without its writer's head being written.
function land!(
        model::ChainModel, client::Integer, write::WritePlan; head = top_slot(model) + 1
    )
    push!(model.commits, ModelCommit(write.comment, write.rows))
    model.heads[client] = head
    return nothing
end

function random_step(rng::AbstractRNG, model::ChainModel, index::Integer)
    roll = rand(rng)
    roll < 0.1 && return RestartPlan(rand(rng, 1:N_CLIENTS))
    roll < 0.45 && return random_sync(rng, model)
    return random_commit(rng, model, index)
end

# A sync! makes more requests the further behind the copy is, so the request that times
# out is drawn from that many: a late one fails the sync mid-replay.
function random_sync(rng::AbstractRNG, model::ChainModel)
    client = rand(rng, 1:N_CLIENTS)
    rand(rng) < 0.65 && return SyncPlan(client, nothing)
    behind = top_slot(model) - model.heads[client]
    fault = (; verb = rand(rng, SYNC_VERBS), request = rand(rng, 1:(behind + 2)))
    return SyncPlan(client, fault)
end

function random_commit(rng::AbstractRNG, model::ChainModel, index::Integer)
    client = random_committer(rng, model)
    rival = rand(rng, setdiff(1:N_CLIENTS, client))
    seen = rows_at(model, model.heads[client])
    write = random_write(rng, seen, "step $index by client $client")
    top_rows = rows_at(model, top_slot(model))
    rival_write = random_write(rng, top_rows, "step $index by rival $rival")
    return CommitPlan(client, write, random_faults(rng), rival, rival_write)
end

# A commit from behind stops at the stale-head check and never reaches the put, so most
# commits come from a client at the chain's head.
function random_committer(rng::AbstractRNG, model::ChainModel)
    current = findall(==(top_slot(model)), model.heads)
    (isempty(current) || rand(rng) < 0.25) && return rand(rng, 1:N_CLIENTS)
    return rand(rng, current)
end

function random_write(rng::AbstractRNG, rows::SampleRows, comment::AbstractString)
    present = shuffle(rng, sort!(collect(keys(rows))))
    absent = shuffle(rng, setdiff(SAMPLE_IDS, present))
    n_inserts = rand(rng, 0:min(2, length(absent)))
    n_updates = rand(rng, 0:min(2, length(present)))
    n_deletes = rand(rng, 0:min(1, length(present) - n_updates))
    # commit! refuses a builder with no ops, so draw again
    n_inserts + n_updates + n_deletes == 0 && return random_write(rng, rows, comment)
    inserts = [random_row(rng, id, comment) for id in absent[1:n_inserts]]
    updates = [random_row(rng, id, comment) for id in present[1:n_updates]]
    deletes = present[(n_updates + 1):(n_updates + n_deletes)]
    after = rows_after(rows, inserts, updates, deletes)
    return WritePlan(comment, inserts, updates, deletes, after)
end

function random_row(rng::AbstractRNG, id::Integer, label::AbstractString)
    return SampleRow((id, label, rand(rng, MASSES)))
end

function rows_after(rows::SampleRows, inserts, updates, deletes)
    written = SampleRows(row.id => row for row in vcat(inserts, updates))
    return filter(pair -> first(pair) ∉ deletes, merge(rows, written))
end

function random_faults(rng::AbstractRNG)
    rand(rng) < 0.35 && return NO_FAULTS
    puts = random_puts(rng)
    readbacks = rand(rng) < 0.2 ? [:timeout] : Symbol[]
    rival_before_put = rand(rng) < 0.3 ? rand(rng, 1:2) : 0
    return FaultPlan(rand(rng) < 0.05, puts, readbacks, rival_before_put, rand(rng) < 0.1)
end

function random_puts(rng::AbstractRNG)
    puts = [rand(rng, keys(RETRIED_STATUS)) for _ in 1:rand(rng, N_RETRIED)]
    length(puts) < PUT_ATTEMPTS && push!(puts, rand(rng, LAST_PUT))
    return puts
end
