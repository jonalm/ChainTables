using Test
using ChainTables: ChainTables, CommitOutcomeUnknownError, Ops, TransactionHash,
    TransportError, WriteBuilderError, commit!, commit_log, delete_rows!, head,
    insert_rows!, sync!, write_builder

include("fixtures/chain_copies.jl")
include("fixtures/object_stores.jl")
include("fixtures/forged_records.jl")

const RETRIED_STATUSES = [nothing, 500, 502, 503, 504, 409, 429]
const REFUSED_STATUSES = [400, 403, 404, 412, 413]
const UNAVAILABLE = TransportError(;
    method = "PUT", url = "p/000000000002", status = 503,
    detail = "ServiceUnavailable: Service Unavailable",
)
const THREE_SAMPLES = [(1, "a", 1.5), (2, "b", missing), (3, "3", 3.0)]

head_files(local_copy) = sort(readdir(joinpath(local_copy.path, "heads")))
table_files(local_copy) = sort(readdir(joinpath(local_copy.path, "tables")))
on_disk(local_copy) = (head_files(local_copy), table_files(local_copy), head(local_copy))
n_puts(store, slot) = n_requests(store, :put_object_if_absent, slot_key(slot))

function sample_builder(local_copy, id)
    w = write_builder(local_copy)
    insert_rows!(w, :samples, [(; id, label = string(id), mass = Float64(id))])
    return w
end

@testset "a put that fails with a status that may be retried is issued again" begin
    @testset "status $(repr(status))" for status in RETRIED_STATUSES
        with_samples_copy() do local_copy
            store = local_copy.chain.store
            failure = TransportError(; method = "PUT", url = slot_key(2), status)
            store.fault = LostPuts(1, failure)
            @test commit_sample!(local_copy, 3).slot == 2
            @test n_puts(store, 2) == 2
        end
    end
end

@testset "a put that the store refuses is not issued again" begin
    @testset "status $status" for status in REFUSED_STATUSES
        with_samples_copy() do local_copy
            store = local_copy.chain.store
            failure = TransportError(; method = "PUT", url = slot_key(2), status)
            store.fault = LostPuts(4, failure)
            before = on_disk(local_copy)
            w = sample_builder(local_copy, 3)
            @test_throws TransportError "status = $status" commit!(w)
            @test n_puts(store, 2) == 1
            @test !haskey(store.objects, slot_key(2))
            @test on_disk(local_copy) == before
            @test isequal(sample_rows(local_copy), THREE_SAMPLES[1:2])
        end
    end
end

@testset "a put that fails twice and then lands is one commit" begin
    with_samples_copy() do local_copy
        store = local_copy.chain.store
        store.fault = LostPuts(2, UNAVAILABLE)
        @test commit_sample!(local_copy, 3).slot == 2
        @test n_puts(store, 2) == 3
        @test isequal(sample_rows(local_copy), THREE_SAMPLES)
    end
end

@testset "a put that fails at every attempt leaves the outcome unknown" begin
    with_samples_copy() do local_copy
        store = local_copy.chain.store
        store.fault = LostPuts(4, UNAVAILABLE)
        before = on_disk(local_copy)
        w = sample_builder(local_copy, 3)
        cause = "Service Unavailable"
        err = @test_throws CommitOutcomeUnknownError cause commit!(w)
        @test err.value.cause isa TransportError
        @test err.value.landed === nothing
        @test n_puts(store, 2) == 4
        @test on_disk(local_copy) == before
    end
end

@testset "a commit whose response is lost is settled by the commit log" begin
    with_samples_copy() do local_copy
        store = local_copy.chain.store
        # The record lands, and the response is lost with a failure that is not retried.
        dropped = ErrorException("response dropped")
        store.fault = FaultAt(:put_object_if_absent, nothing, :after, () -> throw(dropped))
        before = on_disk(local_copy)
        w = sample_builder(local_copy, 3)
        err = @test_throws CommitOutcomeUnknownError "cause = response dropped" commit!(w)
        store.fault = no_fault
        e = err.value
        @test (e.bucket, e.prefix, e.chain_id) == ("bkt", "p", bound_chain_id(local_copy))
        @test (e.slot, e.landed) == (2, nothing)
        @test e.cause isa ErrorException
        @test e.transaction_hash isa TransactionHash
        @test on_disk(local_copy) == before
        @test_throws WriteBuilderError "this builder is spent" commit!(w)
        sync!(local_copy)
        newest = only(commit_log(local_copy; last = 1))
        @test (newest.slot, newest.transaction_hash) == (2, e.transaction_hash)
    end
end

@testset "a commit that fails before its put lands leaves the slot empty" begin
    with_samples_copy() do local_copy
        store = local_copy.chain.store
        store.fault = LostPuts(1, ErrorException("interrupted"))
        w = sample_builder(local_copy, 3)
        err = @test_throws CommitOutcomeUnknownError "cause = interrupted" commit!(w)
        store.fault = no_fault
        @test (err.value.slot, err.value.landed) == (2, nothing)
        @test sync!(local_copy).slot == 1
        @test !haskey(store.objects, slot_key(2))
    end
end

@testset "a head that cannot be written after the put leaves the copy at its old head" begin
    with_samples_copy() do local_copy
        store = local_copy.chain.store
        w = sample_builder(local_copy, 3)
        heads = joinpath(local_copy.path, "heads")
        chmod(heads, 0o555)
        not_written = "the head of the local copy was not written"
        err = try
            @test_throws CommitOutcomeUnknownError not_written commit!(w)
        finally
            chmod(heads, 0o755)
        end
        @test err.value.landed === true
        @test err.value.cause isa SystemError
        @test haskey(store.objects, slot_key(2))
        @test head(local_copy).slot == 1
        # The next sync applies the copy's own record onto the old head.
        @test sync!(local_copy).slot == 2
        @test isequal(sample_rows(local_copy), THREE_SAMPLES)
    end
end

@testset "a crash after the put and before the head is mended by the next sync" begin
    with_samples_copy() do local_copy
        chain = local_copy.chain
        heads = joinpath(local_copy.path, "heads")
        old_head = read(joinpath(heads, "000000000001"))
        tables = joinpath(local_copy.path, "tables")
        old_tables = [name => read(joinpath(tables, name)) for name in readdir(tables)]
        committed = commit_sample!(local_copy, 3)
        # Undo the local commit point and its sweep: the record is in the chain, and
        # the copy is at slot 1 with the table file of slot 2 as an orphan.
        rm(joinpath(heads, "000000000002"))
        write(joinpath(heads, "000000000001"), old_head)
        foreach(file -> write(joinpath(tables, first(file)), last(file)), old_tables)
        close(local_copy)
        with_copy(chain, local_copy.path) do reopened
            @test head(reopened).slot == 1
            synced = sync!(reopened)
            @test (synced.applied, synced.slot) == (1, 2)
            @test head(reopened) == committed
            @test isequal(sample_rows(reopened), THREE_SAMPLES)
        end
    end
end
