using ChainTables: ChainTables, column!, create_chain, create_table!, head, insert_rows!,
    primary_key!, sync!
using ChainTables.Testing: InMemoryObjectStore

# One more record: a row of `samples` with the key `tag + i`. Record 1 declares the
# table too.
function commit_fork_row!(local_copy, i, tag)
    return commit_ops!(local_copy) do w
        i == 1 && declare_samples!(w)
        insert_rows!(w, :samples, [(id = tag + i, label = "x", mass = 1.0)])
    end
end

# Two stores, `a` and `b`, that hold one chain below slot `at` and two forks of it from
# `at` to slot 5, with one chain id. `head` and `rows` are those of `a`'s chain.
function forked_stores(dir, at)
    a, b = InMemoryObjectStore(), InMemoryObjectStore()
    chain_a = chain_in(dir; store = a, cache = "cache_a$at")
    create_chain(chain_a)
    return with_copy(chain_a, joinpath(dir, "writer_a$at")) do writer_a
        sync!(writer_a)
        foreach(i -> commit_fork_row!(writer_a, i, 100), 1:(at - 1))
        copy_objects!(b, a)
        chain_b = chain_in(dir; store = b, cache = "cache_b$at")
        with_copy(chain_b, joinpath(dir, "writer_b$at")) do writer_b
            sync!(writer_b)
            foreach(i -> commit_fork_row!(writer_a, i, 100), at:5)
            foreach(i -> commit_fork_row!(writer_b, i, 200), at:5)
        end
        (; a, b, head = head(writer_a), rows = sample_rows(writer_a))
    end
end

# A chain over a bucket that held `fork.b`, was read whole into the record cache
# `cache`, and was then emptied and filled with `fork.a`.
function refilled_chain(dir, fork, cache; keywords...)
    store = InMemoryObjectStore()
    copy_objects!(store, fork.b)
    chain = chain_in(dir; store, cache, keywords...)
    with_copy(sync!, chain, joinpath(dir, "reader_of_b_$cache"))
    empty_store!(store)
    copy_objects!(store, fork.a)
    return chain
end

# A clock for `replay!`, in nanoseconds: each call advances by the next of `steps`, in
# a cycle.
mutable struct CyclingClock
    const steps::Vector{Int}
    n_calls::Int
    time::Int
end

CyclingClock(steps) = CyclingClock(steps, 0, 0)

function (clock::CyclingClock)()
    clock.n_calls += 1
    clock.time += clock.steps[mod1(clock.n_calls, length(clock.steps))]
    return clock.time
end

# Apply takes 10 and a checkpoint 1, so `replay!` writes a checkpoint after every
# record.
checkpoint_every_record() = CyclingClock([0, 10, 0, 1])

# A clock that returns the readings of a script, one per call.
struct ScriptedClock
    readings::Vector{Int}
end

(clock::ScriptedClock)() = popfirst!(clock.readings)
