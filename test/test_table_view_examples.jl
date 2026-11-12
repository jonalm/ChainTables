using Test
using ExplicitImports: check_all_explicit_imports_are_public,
    check_all_qualified_accesses_are_public
using ChainTables: ChainTables, Chain, TableView, column!, commit!, create_chain,
    create_table!, insert_rows!, primary_key!, sync!, table, table_with_slots, update_rows!,
    write_builder
using ChainTables.Testing: InMemoryObjectStore
using Tables: Tables

# A synced copy holding `samples` with two rows at slot 1.
function with_samples(f)
    return mktempdir() do dir
        store = InMemoryObjectStore()
        chain = Chain("bkt", "p"; store, cache_dir = joinpath(dir, "cache"))
        create_chain(chain)
        copy = ChainTables.open(chain, joinpath(dir, "copy"))
        sync!(copy)
        w = write_builder(copy)
        create_table!(w, :samples) do t
            column!(t, :id, Int64)
            column!(t, :label, String)
            primary_key!(t, :id)
        end
        insert_rows!(w, :samples, [(id = 2, label = "b"), (id = 1, label = "a")])
        commit!(w)
        try
            f(copy)
        finally
            close(copy)
        end
    end
end

@testset "TableView example" begin
    with_samples() do copy
        v = table(copy, :samples)
        @test v isa TableView
        # Rows iterate in key order, as NamedTuples.
        @test collect(v) == [(id = 1, label = "a"), (id = 2, label = "b")]
        # Look a row up by its primary key.
        @test v[2] == (id = 2, label = "b")
        @test keys(v) == [1, 2]
        # A view is a Tables.jl table.
        @test Tables.columntable(v) == (id = [1, 2], label = ["a", "b"])
    end
end

@testset "table_with_slots example" begin
    with_samples() do copy
        w = write_builder(copy)
        update_rows!(w, :samples, [(id = 2, label = "B")])
        commit!(w)
        s = table_with_slots(table(copy, :samples))
        # Row 1 was last changed at slot 1, row 2 at slot 2.
        @test s._slot == [1, 2]
        @test s.label == ["a", "B"]
    end
end

@testset "the examples use only public names" begin
    @test check_all_explicit_imports_are_public(@__MODULE__, @__FILE__) === nothing
    @test check_all_qualified_accesses_are_public(@__MODULE__, @__FILE__) === nothing
end
