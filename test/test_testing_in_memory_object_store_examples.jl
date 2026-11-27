using Test
using ChainTables: ChainTables, Chain, TransportError, create_chain, fetch_object,
    put_object_if_absent
using ChainTables.Testing: InMemoryObjectStore

# A fault hook: every put fails before it lands.
function refuse_puts(verb, key, phase)
    verb === :put_object_if_absent || return nothing
    throw(TransportError(; method = "PUT", url = "mem:", status = 503))
end

@testset "Testing.InMemoryObjectStore example" begin
    # A chain over the in-memory store, as a test of code that uses ChainTables builds.
    store = InMemoryObjectStore(; clock = () -> 1_700_000_000, seed = 7)
    mktempdir() do dir
        chain = Chain("bkt", "lab"; store, cache_dir = dir)
        create_chain(chain)
        @test haskey(store.objects, "lab/000000000000")
    end

    # The fault hook makes a request fail, here before any put lands.
    store.fault = refuse_puts
    @test_throws TransportError "a request failed" put_object_if_absent(store, "k", b"x")
    @test fetch_object(store, "k") === nothing
    @test last(store.calls) == (:fetch_object, "k")
end
