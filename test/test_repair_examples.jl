using Test
using ChainTables: ChainTables, Chain, column!, commit!, create_chain, create_table!,
    primary_key!, repair!, sync!, verify, write_builder
using ChainTables.Testing: InMemoryObjectStore

@testset "repair! example" begin
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
        commit!(w)
        # Damage a table file, then repair it from the record cache.
        file = only(readdir(joinpath(copy.path, "tables"); join = true))
        write(file, b"damaged")
        @test repair!(copy) == (; slot = 1, files_rewritten = 1, attachments_repaired = 0)
        @test verify(copy) === nothing
        close(copy)
    end
end
