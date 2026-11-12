using Test
using ChainTables: ChainTables, Chain, column!, commit!, commit_log, create_chain,
    create_table!, primary_key!, sync!, write_builder
using ChainTables.Testing: InMemoryObjectStore

@testset "commit_log example" begin
    mktempdir() do dir
        chain = Chain("my-bucket", "run-7"; store = InMemoryObjectStore(), cache_dir = dir)
        create_chain(chain)
        copy = ChainTables.open(chain, joinpath(dir, "copy"))
        sync!(copy)
        w = write_builder(copy)
        create_table!(w, :samples) do t
            column!(t, :id, Int64)
            primary_key!(t, :id)
        end
        commit!(w; comment = "make samples")
        # The copy's records, newest first: the commit, then the genesis record.
        log = commit_log(copy)
        @test [entry.slot for entry in log] == [1, 0]
        @test log[1].comment == "make samples"
        @test commit_log(copy; last = 1) == log[1:1]
        close(copy)
    end
end
