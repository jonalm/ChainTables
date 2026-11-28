"""
    slot_at(chain, time_ms)

Return the highest slot whose record's `client.time_ms` is at or below `time_ms`
(milliseconds since the Unix epoch, UTC).

Every record of the chain is read from slot 0 and held against its parent, so a broken
link throws `RewrittenChainError`. It is a scan because the time is the committer's
clock, which is not monotone across clients. A time before the genesis record's throws
`ArgumentError`, and a chain with no slot 0 `ChainNotFoundError`.

Examples: test/test_slot_at_examples.jl
"""
function slot_at(chain::Chain, time_ms)
    time_ms isa Integer || throw(
        ArgumentError("time_ms is a $(typeof(time_ms)), not an Integer of milliseconds")
    )
    top = fetch_top_slot(chain, -1)
    top == -1 && throw(ChainNotFoundError(chain, "slot_at"))
    scan = read_last_slot_at(chain, top, time_ms)
    slot = scan.slot
    slot === nothing && throw(
        ArgumentError(
            "$time_ms is before the genesis record's client.time_ms, " *
                "$(scan.genesis_ms); there is no state before slot 0"
        )
    )
    return slot
end

# Returns the highest slot whose record's time is at or below `time_ms`, or `nothing`,
# and the time of the genesis record.
function read_last_slot_at(chain::Chain, top, time_ms)
    found = Ref{Union{Nothing, Int64}}(nothing)
    genesis_ms = Ref{Int64}(0)
    read_forward(chain, 0, top) do slot, record, _
        slot == 0 && (genesis_ms[] = record.client.time_ms)
        record.client.time_ms <= time_ms && (found[] = slot)
        return false
    end
    return (; slot = found[], genesis_ms = genesis_ms[])
end
