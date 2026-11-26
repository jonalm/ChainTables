"""
    verify(local_copy; full = false)

Check the local copy without the network, and return `nothing` when it is sound.

Every table file that the head names must hash to its name, else
`FingerprintMismatchError`. With `full`, the record cache must hold the copy's records
from its head down, else `RecordCacheError`. Their replay from slot 0 must give each
record's state fingerprint, else `FingerprintMismatchError` for the first slot that does
not. Last, every attachment the copy confirmed must hash to its name, else
`AttachmentCacheError`. The head never moves.

Examples: test/test_verify_examples.jl
"""
function verify(local_copy::LocalCopy; full = false)
    check_open(local_copy)
    head_file = bound_head(local_copy)
    verify_table_files(local_copy, head_file)
    full || return nothing
    chain = chain_of(local_copy, "verify")
    verify_replay(local_copy, read_cached_records(local_copy, chain))
    verify_attachments(local_copy, chain)
    return nothing
end

# A table file that does not hash to its name is a damaged copy: the check that `open`
# leaves out (ADR-0023).
function verify_table_files(local_copy::LocalCopy, head_file::Head)
    checked = [
        (; hash, names, found = hash_table_file(local_copy, hash))
            for (hash, names) in table_files_of(head_file)
    ]
    faults = [table_file_fault(file) for file in checked if file.found != file.hash]
    isempty(faults) && return nothing
    throw(
        FingerprintMismatchError(;
            local_copy.path, head_file.chain_id, head_file.slot,
            expected = StateFingerprint(head_file.state_fingerprint),
            computed = found_fingerprint(checked), detail = join(faults, "; "),
        )
    )
end

function table_file_fault(file)
    state = file.found === nothing ? "is missing" : "hashes to $(bytes2hex(file.found))"
    tables = join(map(repr, file.names), ", ", " and ")
    return "table file tables/$(bytes2hex(file.hash)) of $tables $state"
end

# The state fingerprint that the table files give as they are, `nothing` when one is
# missing.
function found_fingerprint(checked)
    any(file -> file.found === nothing, checked) && return nothing
    tables = [name => file.found for file in checked for name in file.names]
    return StateFingerprint(Model.state_fingerprint(sort!(tables; by = first)))
end

# Returns the records of slots 0 to the head's, by slot, from the record cache only.
function read_cached_records(local_copy::LocalCopy, chain::Chain)
    records = Vector{Ops.Record}(undef, local_copy.head.slot + 1)
    read_back_from_head(local_copy, chain; fetch = false) do slot, record, _
        records[slot + 1] = record
        return false
    end
    return records
end

# Replay determinism: once a slot does not reproduce, no slot above it does, so the
# first such slot is found by bisection (ADR-0007).
function verify_replay(local_copy::LocalCopy, records)
    content = apply_records!(Model.Content(), records, eachindex(records))
    reproduces(content, last(records)) && return nothing
    mismatch = bisect_first_mismatch(records)
    record = records[mismatch.slot + 1]
    head_file = local_copy.head
    throw(
        FingerprintMismatchError(;
            local_copy.path, head_file.chain_id, mismatch.slot,
            expected = StateFingerprint(record.state_fingerprint),
            computed = StateFingerprint(Model.state_fingerprint(mismatch.content)),
            record_client = (; record.client.lib, record.client.julia),
            this_client = written_by_here(), detail = replay_detail(mismatch.slot),
        )
    )
end

# Returns the first slot whose record's state fingerprint the replay does not give, and
# the content after that record. `records[end]` is known not to reproduce.
function bisect_first_mismatch(records)
    good, bad = 0, length(records)  # indices into `records`, slot + 1
    content = Model.Content()  # the content after `records[good]`
    while bad - good > 1
        middle = (good + bad) ÷ 2
        tried = apply_records!(deepcopy(content), records, (good + 1):middle)
        if reproduces(tried, records[middle])
            good, content = middle, tried
        else
            bad = middle
        end
    end
    content = apply_records!(content, records, (good + 1):bad)
    return (; slot = Int64(bad - 1), content)
end

function apply_records!(content::Model.Content, records, indices)
    foreach(i -> Ops.apply!(content, records[i]), indices)
    return content
end

function reproduces(content::Model.Content, record::Ops.Record)
    return Model.state_fingerprint(content) == record.state_fingerprint
end

function replay_detail(slot)
    slot == 0 && return "a replay of the record cache fails at its first record"
    return "a replay of the record cache reproduces slots 0 to $(slot - 1)"
end
