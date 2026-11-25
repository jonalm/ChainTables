using Test
using Tables: Tables
using ChainTables: ChainTables, TableView, TransactionHash, add_column!, delete_rows!,
    drop_column!, head, table, table_with_slots, update_rows!

include("fixtures/chain_copies.jl")

const SAMPLE_ROW_TYPE = @NamedTuple{id::Int64, label::String, mass::Union{Missing, Float64}}
const READ_ONLY = "a table view's columns are read-only"

slots_of(local_copy, name) = table_with_slots(table(local_copy, name))._slot

@testset "TableView iterates its rows in typed key order" begin
    with_tables_copy() do local_copy
        v = table(local_copy, :samples)
        rows = [(id = 1, label = "a", mass = 1.5), (id = 2, label = "b", mass = missing)]
        @test isequal(collect(v), rows)
        @test length(v) == 2
        @test eltype(v) == SAMPLE_ROW_TYPE
        @test first(v) isa SAMPLE_ROW_TYPE
    end
end

@testset "TableView honours the iteration interface" begin
    with_tables_copy() do local_copy
        v = table(local_copy, :samples)
        V = typeof(v)
        Step = Union{Nothing, Tuple{eltype(v), Int}}
        @test eltype(collect(v)) == eltype(v)
        @test length(collect(v)) == length(v)
        @test Base.infer_return_type(iterate, (V,)) == Step
        @test Base.infer_return_type(iterate, (V, Int)) == Step
        @test haskey(v, 1) isa Bool
    end
end

@testset "TableView names the head that it is a read of" begin
    with_tables_copy() do local_copy
        v = table(local_copy, :samples)
        @test v isa TableView
        @test v.name == "samples"
        @test v.slot == 1
        @test v.chain_id == local_copy.head.chain_id
        @test v.transaction_hash isa TransactionHash
        @test v.transaction_hash == head(local_copy).transaction_hash
    end
end

@testset "TableView looks up a row by its key" begin
    with_tables_copy() do local_copy
        v = table(local_copy, :samples)
        @test isequal(v[2], (id = 2, label = "b", mass = missing))
        @test v[2] isa SAMPLE_ROW_TYPE
        @test isequal(v[(2,)], v[2])
        @test haskey(v, 1)
        @test !haskey(v, 9)
        @test isequal(get(v, 1, nothing), v[1])
        @test get(v, 9, nothing) === nothing
        @test keys(v) == [1, 2]
    end
end

@testset "TableView throws KeyError for a key with no row" begin
    with_tables_copy() do local_copy
        @test_throws KeyError "KeyError: key 9 not found" table(local_copy, :samples)[9]
        @test_throws KeyError "key (9,) not found" table(local_copy, :samples)[(9,)]
        @test_throws KeyError "key (1, \"z\") not found" table(local_copy, :pairs)[1, "z"]
    end
end

@testset "TableView refuses a key of another length" begin
    with_tables_copy() do local_copy
        @test_throws(
            ArgumentError,
            "table \"samples\" has a one-column key (id); a key of 2 cells does not address",
            table(local_copy, :samples)[(1, 2)]
        )
        @test_throws(
            ArgumentError,
            "table \"pairs\" has a composite key (a, b); a key of 3 cells does not address",
            table(local_copy, :pairs)[(1, "x", 2)]
        )
    end
end

@testset "TableView looks up a composite key as a tuple or as arguments" begin
    with_tables_copy() do local_copy
        p = table(local_copy, :pairs)
        @test keys(p) == [(1, "w"), (1, "x"), (2, "y")]
        @test p[(1, "x")] == (n = 0.25, a = 1, b = "x")
        @test p[1, "x"] == p[(1, "x")]
        @test haskey(p, (2, "y"))
        @test get(p, (1, "z"), :none) === :none
    end
end

@testset "TableView refuses a bare value for a composite key" begin
    with_tables_copy() do local_copy
        @test_throws(
            ArgumentError,
            "table \"pairs\" has a composite key (a, b); look it up as a tuple in key " *
                "declaration order, got 1",
            table(local_copy, :pairs)[1]
        )
    end
end

@testset "TableView looks up the key of a row" begin
    with_tables_copy() do local_copy
        p = table(local_copy, :pairs)
        @test p[first(p)] == first(p)
        @test haskey(p, (a = 2, b = "y", n = -1.0))
        @test !haskey(p, (a = 2, b = "z"))
        @test get(p, (a = 9, b = "x"), :none) === :none
        @test isequal(table(local_copy, :samples)[(id = 2,)].mass, missing)
    end
end

@testset "TableView refuses a row that names no key column" begin
    with_tables_copy() do local_copy
        @test_throws(
            ArgumentError,
            "table \"pairs\": the row (a = 1,) names no key column \"b\"; a row looks up " *
                "its key, so it names every key column (a, b)",
            table(local_copy, :pairs)[(a = 1,)]
        )
    end
end

@testset "TableView is a Tables.jl table with the declared column types" begin
    with_tables_copy() do local_copy
        v = table(local_copy, :samples)
        types = (Int64, String, Union{Missing, Float64})
        @test Tables.istable(v)
        @test Tables.istable(typeof(v))
        @test Tables.columnaccess(typeof(v))
        @test Tables.rowaccess(typeof(v))
        @test Tables.columns(v) === v.columns
        @test Tables.rows(v) === v
        @test Tables.schema(v) == Tables.Schema((:id, :label, :mass), types)
        @test Tables.columntable(v).mass isa AbstractVector{Union{Missing, Float64}}
        @test isequal(Tables.rowtable(v), collect(v))
    end
end

@testset "TableView shows its name, its head and its size" begin
    with_tables_copy() do local_copy
        chain_id = local_copy.head.chain_id
        @test sprint(show, table(local_copy, :samples)) ==
            "TableView(\"samples\"; chain_id = \"$chain_id\", slot = 1, n_rows = 2, " *
            "columns = (:id, :label, :mass))"
    end
end

@testset "TableView hands out a copy of a bytes cell at each read" begin
    with_tables_copy() do local_copy
        b = table(local_copy, :blobs)
        @test keys(b) == [UInt8[1], UInt8[1, 2]]
        @test isequal(b[UInt8[1]], (k = UInt8[1], v = missing))
        b[UInt8[1, 2]].v[1] = 0xff
        b.columns.v[2][1] = 0xff
        @test b[UInt8[1, 2]].v == UInt8[9]
        @test table(local_copy, :blobs).columns.v[2] == UInt8[9]
    end
end

@testset "TableView refuses a write to a column" begin
    with_tables_copy() do local_copy
        v = table(local_copy, :samples)
        @test_throws ArgumentError READ_ONLY Tables.columns(v).label[1] = "zzz"
        @test_throws ArgumentError READ_ONLY v.columns.mass[1] = 99.0
        @test_throws ArgumentError READ_ONLY sort!(v.columns.label; rev = true)
        @test_throws ArgumentError READ_ONLY table_with_slots(v).label[2] = "yyy"
        @test_throws ArgumentError READ_ONLY table_with_slots(v)._slot[1] = 7
        @test v.columns.label == ["a", "b"]
    end
end

@testset "TableView gives a vector of the caller's own through copy" begin
    with_tables_copy() do local_copy
        v = table(local_copy, :samples)
        own = copy(v.columns.label)
        own[1] = "zzz"
        @test own isa Vector{String}
        @test v.columns.label == ["a", "b"]
    end
end

@testset "TableView of a table with no rows has the declared row type" begin
    with_tables_copy() do local_copy
        commit_ops!(w -> declare_samples!(w, :none), local_copy)
        v = table(local_copy, :none)
        @test length(v) == 0
        @test isempty(collect(v))
        @test isempty(keys(v))
        @test eltype(v) == SAMPLE_ROW_TYPE
        @test Tables.rowtable(v) == SAMPLE_ROW_TYPE[]
        @test eltype(Tables.columns(v).mass) == Union{Missing, Float64}
        @test table_with_slots(v)._slot == Int64[]
        @test !haskey(v, 1)
        @test_throws KeyError "key 1 not found" v[1]
    end
end

@testset "TableView stays as it was when the copy moves" begin
    with_tables_copy() do local_copy
        v = table(local_copy, :samples)
        commit_ops!(w -> update_rows!(w, :samples, [(id = 2, mass = 2.5)]), local_copy)
        @test v[2].mass === missing
        @test v.slot == 1
        @test table(local_copy, :samples)[2].mass == 2.5
    end
end

@testset "TableView outlives its local copy" begin
    with_tables_copy() do local_copy
        v = table(local_copy, :samples)
        close(local_copy)
        @test isequal(v[2], (id = 2, label = "b", mass = missing))
    end
end

@testset "TableView rows go back into the write builder unchanged" begin
    with_tables_copy() do local_copy
        v = table(local_copy, :samples)
        commit_ops!(local_copy) do w
            update_rows!(w, :samples, [v[2]])
            declare_samples!(w, :again)
            insert_rows!(w, :again, Tables.rows(v))
        end
        @test table(local_copy, :samples)[2].mass === missing
        @test isequal(collect(table(local_copy, :again)), collect(v))
    end
end

@testset "table_with_slots adds the row slots to the view's own columns" begin
    with_tables_copy() do local_copy
        v = table(local_copy, :samples)
        with_slots = table_with_slots(v)
        @test @inferred(table_with_slots(v))._slot == [1, 1]
        @test keys(with_slots) == (:id, :label, :mass, :_slot)
        @test with_slots.label === v.columns.label
        @test keys(Tables.columntable(v)) == (:id, :label, :mass)
    end
end

@testset "table_with_slots shows an update on the rows that it names" begin
    with_tables_copy() do local_copy
        commit_ops!(local_copy) do w
            # The same value again still stamps the row.
            update_rows!(w, :samples, [(id = 2, mass = missing)])
            insert_rows!(w, :samples, [(id = 3, label = "c", mass = 3.0)])
        end
        @test slots_of(local_copy, :samples) == [1, 2, 2]
        @test slots_of(local_copy, :pairs) == [1, 1, 1]
    end
end

@testset "table_with_slots leaves the other rows as they were after a delete" begin
    with_tables_copy() do local_copy
        commit_ops!(w -> update_rows!(w, :samples, [(id = 2, mass = 0.5)]), local_copy)
        commit_ops!(w -> delete_rows!(w, :samples, [(id = 1,)]), local_copy)
        @test keys(table(local_copy, :samples)) == [2]
        @test slots_of(local_copy, :samples) == [2]
    end
end

@testset "table_with_slots shows a column op on every row of its table" begin
    with_tables_copy() do local_copy
        commit_ops!(local_copy) do w
            add_column!(w, :pairs, :note, String; nullable = true, fill = missing)
        end
        @test slots_of(local_copy, :pairs) == [2, 2, 2]
        @test slots_of(local_copy, :samples) == [1, 1]
        commit_ops!(w -> drop_column!(w, :samples, :label), local_copy)
        @test slots_of(local_copy, :samples) == [3, 3]
    end
end

@testset "table_with_slots of a view is fixed at the view's head" begin
    with_tables_copy() do local_copy
        before = table(local_copy, :pairs)
        commit_ops!(w -> update_rows!(w, :pairs, [(a = 1, b = "x", n = 9.0)]), local_copy)
        @test table_with_slots(before)._slot == [1, 1, 1]
        @test slots_of(local_copy, :pairs) == [1, 2, 1]
    end
end

@testset "table_with_slots of a replay equals the committing copy's" begin
    with_tables_copy() do local_copy
        commit_ops!(w -> update_rows!(w, :pairs, [(a = 1, b = "x", n = 9.0)]), local_copy)
        commit_ops!(w -> drop_column!(w, :samples, :label), local_copy)
        mktempdir() do dir
            other = ChainTables.open(local_copy.chain, dir)
            sync!(other)
            @test slots_of(other, :pairs) == slots_of(local_copy, :pairs)
            @test slots_of(other, :samples) == slots_of(local_copy, :samples)
            close(other)
        end
    end
end

@testset "table_with_slots of a pinned copy shows the slots as of its slot" begin
    with_tables_copy() do local_copy
        commit_ops!(w -> update_rows!(w, :pairs, [(a = 1, b = "x", n = 9.0)]), local_copy)
        commit_ops!(w -> update_rows!(w, :pairs, [(a = 2, b = "y", n = 9.0)]), local_copy)
        pinned = ChainTables.as_of(local_copy.chain, 2)
        @test slots_of(pinned, :pairs) == [1, 2, 1]
        close(pinned)
    end
end
