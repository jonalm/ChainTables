using Test
using ChainTables: ChainTables, AttachmentAbsentError, put_attachment, touch_attachment
using ChainTables.Testing: InMemoryObjectStore

include("fixtures/attachments.jl")
include("fixtures/chain_copies.jl")

const BAD_HASHES = [
    (name = "uppercase", h = uppercase(NEVER_PUT)),
    (name = "63 characters", h = NEVER_PUT[1:63]),
    (name = "65 characters", h = NEVER_PUT * "0"),
    (name = "a path", h = "../" * NEVER_PUT[4:end]),
]

@testset "touch_attachment on a plain bucket only asks whether it holds the key" begin
    mktempdir() do dir
        chain = chain_in(dir)
        h = put_attachment(chain, IOBuffer(b"held"))
        empty!(chain.store.calls)
        @test @inferred(touch_attachment(chain, h)) === nothing
        @test chain.store.calls == [(:stat_object, "p/_attachments/$h")]
    end
end

@testset "touch_attachment throws for an attachment that the bucket lacks" begin
    mktempdir() do dir
        chain = chain_in(dir)
        err = @test_throws AttachmentAbsentError "it was never put" touch_attachment(
            chain, NEVER_PUT
        )
        @test (err.value.bucket, err.value.prefix) == ("bkt", "p")
        @test err.value.key == "p/_attachments/$NEVER_PUT"
        @test err.value.chain_id === nothing
    end
end

@testset "touch_attachment refuses a hash that is $(case.name)" for case in BAD_HASHES
    mktempdir() do dir
        chain = chain_in(dir)
        fragment = "$(repr(case.h)) is not an attachment hash"
        @test_throws ArgumentError fragment touch_attachment(chain, case.h)
        @test isempty(chain.store.calls)
    end
end

@testset "touch_attachment asks again after a failure that may pass" begin
    mktempdir() do dir
        fault = FailingRequests(:stat_object, :before, 1, transport_failure(500))
        chain = chain_in(dir; store = InMemoryObjectStore(; fault))
        h = put_attachment(chain, IOBuffer(b"held"))
        @test touch_attachment(chain, h) === nothing
        @test n_calls(chain.store, :stat_object) == 2
    end
end
