using Test
using ChainTables: ChainTables, Chain, ReadOnlyColumn, TableView, TransactionHash,
    add_column!, as_of, column!, commit!, create_chain, create_table!, delete_rows!,
    drop_column!, head, insert_rows!, primary_key!, sync!, table, table_with_slots,
    update_rows!, write_builder
using ChainTables.Testing: InMemoryObjectStore
using Tables: Tables
using TestConventions: check_inferred

const SAMPLES_ROW =
    NamedTuple{(:id, :label, :mass), Tuple{Int64, String, Union{Missing, Float64}}}

function declare_tables!(w)
    create_table!(w, :samples) do t
        column!(t, :id, Int64)
        column!(t, :label, String)
        column!(t, :mass, Float64; nullable = true)
        primary_key!(t, :id)
    end
    create_table!(w, :pairs) do t
        column!(t, :n, Float64)
        column!(t, :a, Int64)
        column!(t, :b, String)
        primary_key!(t, :a, :b)
    end
    create_table!(w, :blobs) do t
        column!(t, :k, Vector{UInt8})
        column!(t, :v, Vector{UInt8}; nullable = true)
        primary_key!(t, :k)
    end
    return nothing
end

function insert_fixture_rows!(w)
    samples = [(id = 2, label = "b", mass = missing), (id = 1, label = "a", mass = 1.5)]
    insert_rows!(w, :samples, samples)
    pairs = [
        (a = 2, b = "y", n = 0.5), (a = 1, b = "x", n = 0.25), (a = 1, b = "w", n = 0.0),
    ]
    insert_rows!(w, :pairs, pairs)
    blobs = [(k = UInt8[1, 2], v = UInt8[9]), (k = UInt8[1], v = missing)]
    insert_rows!(w, :blobs, blobs)
    return nothing
end

# A copy at slot 1 holding samples, pairs and blobs.
function with_fixture(f)
    return mktempdir() do dir
        store = InMemoryObjectStore()
        chain = Chain("bkt", "p"; store, cache_dir = joinpath(dir, "cache"))
        create_chain(chain)
        copy = ChainTables.open(chain, joinpath(dir, "one"))
        sync!(copy)
        w = write_builder(copy)
        declare_tables!(w)
        insert_fixture_rows!(w)
        commit!(w)
        try
            f(chain, copy, dir)
        finally
            close(copy)
        end
    end
end

function committed(f, copy)
    w = write_builder(copy)
    f(w)
    commit!(w)
    return nothing
end

@testset "a TableView names the head it was taken at" begin
    with_fixture() do chain, copy, dir
        v = table(copy, :samples)
        @test v isa TableView
        @test v.name == "samples"
        @test v.slot == 1
        @test v.transaction_hash == head(copy).transaction_hash
        @test v.transaction_hash isa TransactionHash
    end
end

@testset "a TableView iterates its rows in key order" begin
    with_fixture() do chain, copy, dir
        v = table(copy, :samples)
        @test length(v) == 2
        rows = [(id = 1, label = "a", mass = 1.5), (id = 2, label = "b", mass = missing)]
        @test isequal(collect(v), rows)
        @test eltype(v) == SAMPLES_ROW
        @test v[2].mass === missing
    end
end

@testset "a TableView looks up a one-column key" begin
    with_fixture() do chain, copy, dir
        v = table(copy, :samples)
        @test keys(v) == [1, 2]
        @test isequal(v[2], (id = 2, label = "b", mass = missing))
        @test v[2] isa eltype(v)
        @test isequal(v[(2,)], v[2])
        @test isequal(v[(id = 2,)], v[2])
        @test haskey(v, 1)
        @test !haskey(v, 9)
        @test get(v, 9, nothing) === nothing
        @test isequal(get(v, 1, nothing), v[1])
        @test_throws KeyError v[9]
        @test_throws KeyError v[(9,)]
        wrong_arity = "table \"samples\" has a one-column key (id); a key of 2 cells " *
            "does not address it"
        @test_throws ArgumentError wrong_arity v[(1, 2)]
    end
end

@testset "a TableView looks up a composite key" begin
    with_fixture() do chain, copy, dir
        p = table(copy, :pairs)
        @test keys(p) == [(1, "w"), (1, "x"), (2, "y")]
        @test p[(1, "x")] == (n = 0.25, a = 1, b = "x")
        @test p[1, "x"] == p[(1, "x")]
        @test p[first(p)] == first(p)
        @test haskey(p, (a = 2, b = "y", n = -1.0))
        @test !haskey(p, (a = 2, b = "z"))
        @test get(p, (a = 9, b = "x"), :none) === :none
        @test get(p, (1, "z"), :none) === :none
        @test_throws KeyError p[(1, "z")]
        @test_throws KeyError p[1, "z"]
        @test_throws KeyError p[(a = 1, b = "z")]
        bare = "table \"pairs\" has a composite key (a, b); look it up as a tuple in key " *
            "declaration order, got 1"
        @test_throws ArgumentError bare p[1]
        no_key = "table \"pairs\": the row (a = 1,) names no key column \"b\"; " *
            "a row looks up its key, so it names every key column (a, b)"
        @test_throws ArgumentError no_key p[(a = 1,)]
    end
end

@testset "a TableView is a Tables.jl table of its declared types" begin
    with_fixture() do chain, copy, dir
        v = table(copy, :samples)
        @test Tables.istable(v)
        @test Tables.istable(typeof(v))
        @test Tables.columnaccess(typeof(v))
        @test Tables.rowaccess(typeof(v))
        @test Tables.columns(v) === v.columns
        @test Tables.columns(v).label == ["a", "b"]
        types = (Int64, String, Union{Missing, Float64})
        @test Tables.schema(v) == Tables.Schema((:id, :label, :mass), types)
        @test Tables.schema(Tables.rows(v)).types == types
        mass = Union{Missing, Float64}[1.5, missing]
        expected = (id = [1, 2], label = ["a", "b"], mass)
        @test isequal(Tables.columntable(v), expected)
        @test isequal(Tables.rowtable(v), collect(v))
    end
end

@testset "a TableView copies bytes cells out on each read" begin
    with_fixture() do chain, copy, dir
        b = table(copy, :blobs)
        @test keys(b) == [UInt8[1], UInt8[1, 2]]
        @test isequal(b[UInt8[1]], (k = UInt8[1], v = missing))
        b[UInt8[1, 2]].v[1] = 0xff
        b.columns.v[2][1] = 0xff
        @test b[UInt8[1, 2]].v == UInt8[9]
        @test table(copy, :blobs).columns.v[2] == UInt8[9]
    end
end

@testset "a TableView's columns are read-only" begin
    with_fixture() do chain, copy, dir
        v = table(copy, :samples)
        read_only = "a table view's columns are read-only: every table(copy, :t) at one " *
            "head returns the same view; copy(column) is a vector of your own"
        @test_throws ArgumentError read_only Tables.columns(v).label[1] = "zzz"
        @test_throws ArgumentError read_only v.columns.mass[1] = 99.0
        @test_throws ArgumentError read_only table_with_slots(v).label[2] = "yyy"
        @test_throws ArgumentError read_only table_with_slots(v)._slot[1] = 7
        @test_throws ArgumentError read_only sort!(v.columns.label; rev = true)
        @test_throws ArgumentError read_only Tables.columntable(v).label[1] = "zzz"
        mine = Base.copy(v.columns.label)
        mine[1] = "zzz"
        @test v.columns.label == ["a", "b"]
        @test isequal(collect(table(copy, :samples)), collect(v))
    end
end

@testset "a TableView shows its head and columns" begin
    with_fixture() do chain, copy, dir
        v = table(copy, :samples)
        expected = "TableView(:samples at slot 1 of chain $(v.chain_id); 2 rows, " *
            "columns id, label, mass)"
        @test sprint(show, v) == expected
    end
end

@testset "a TableView of an empty table has its declared schema" begin
    with_fixture() do chain, copy, dir
        committed(copy) do w
            create_table!(w, :none) do t
                column!(t, :a, Int64)
                column!(t, :b, String)
                column!(t, :c, Float64; nullable = true)
                primary_key!(t, :a, :b)
            end
        end
        e = table(copy, :none)
        @test length(e) == 0
        @test isempty(collect(e))
        @test isempty(keys(e))
        row_type = NamedTuple{(:a, :b, :c), Tuple{Int64, String, Union{Missing, Float64}}}
        @test eltype(e) == row_type
        @test eltype(collect(e)) == row_type
        types = (Int64, String, Union{Missing, Float64})
        @test Tables.schema(e) == Tables.Schema((:a, :b, :c), types)
        @test eltype(Tables.columns(e).c) == Union{Missing, Float64}
        @test Tables.rowtable(e) == row_type[]
        @test table_with_slots(e)._slot == Int64[]
        @test !haskey(e, (1, "x"))
        @test get(e, (1, "x"), :none) === :none
        @test_throws KeyError e[1, "x"]
    end
end

@testset "a TableView outlives its copy" begin
    with_fixture() do chain, copy, dir
        v = table(copy, :samples)
        close(copy)
        @test isequal(v[2], (id = 2, label = "b", mass = missing))
    end
end

@testset "table_with_slots adds the row slots to the view's own columns" begin
    with_fixture() do chain, copy, dir
        v = table(copy, :samples)
        s = table_with_slots(v)
        @test s._slot == [1, 1]
        @test s.label === v.columns.label
        @test keys(s) == (:id, :label, :mass, :_slot)
        @test !haskey(Tables.columns(v), :_slot)
    end
end

slots(copy, name) = table_with_slots(table(copy, name))._slot

@testset "a row slot is the slot of the last record that changed the row" begin
    with_fixture() do chain, copy, dir
        committed(copy) do w
            update_rows!(w, :samples, [(id = 2, mass = missing)])
            insert_rows!(w, :samples, [(id = 3, label = "c", mass = 3.0)])
        end
        @test slots(copy, :samples) == [1, 2, 2]
        @test slots(copy, :pairs) == [1, 1, 1]
        committed(w -> delete_rows!(w, :samples, [(id = 2,)]), copy)
        @test keys(table(copy, :samples)) == [1, 3]
        @test slots(copy, :samples) == [1, 2]
        add_note = w -> add_column!(w, :pairs, :note, String; nullable = true, fill = "")
        committed(add_note, copy)
        @test slots(copy, :pairs) == [4, 4, 4]
        committed(w -> drop_column!(w, :samples, :label), copy)
        @test slots(copy, :samples) == [5, 5]
        committed(w -> update_rows!(w, :pairs, [(a = 1, b = "x", n = 9.0)]), copy)
        @test slots(copy, :pairs) == [4, 6, 4]
        @test maximum(slots(copy, :pairs)) <= table(copy, :pairs).slot
        committed(w -> update_rows!(w, :pairs, Tables.rows(table(copy, :pairs))), copy)
        @test slots(copy, :pairs) == [7, 7, 7]
    end
end

@testset "a replay stamps the row slots the committing copy stamped" begin
    with_fixture() do chain, copy, dir
        other = ChainTables.open(chain, joinpath(dir, "other"))
        sync!(other)
        before = table(other, :pairs)
        committed(w -> update_rows!(w, :pairs, [(a = 1, b = "x", n = 9.0)]), copy)
        committed(w -> insert_rows!(w, :pairs, [(a = 3, b = "z", n = 1.0)]), copy)
        @test sync!(other).slot == 3
        @test table_with_slots(before)._slot == [1, 1, 1]
        @test slots(other, :pairs) == slots(copy, :pairs) == [1, 2, 1, 3]
        old = as_of(chain, 2)
        @test slots(old, :pairs) == [1, 2, 1]
        close(old)
        close(other)
    end
end

@testset "TableView conforms to the iteration interface" begin
    with_fixture() do chain, copy, dir
        v = table(copy, :samples)
        @test eltype(collect(v)) == eltype(v)
        @test length(collect(v)) == length(v)
        @test haskey(v, 1) isa Bool
        state_type = Union{Nothing, Tuple{SAMPLES_ROW, Int}}
        check_inferred(state_type, iterate, v)
        check_inferred(state_type, iterate, v, 1)
    end
end

@testset "ReadOnlyColumn conforms to the array interface" begin
    c = ReadOnlyColumn([UInt8[1], UInt8[2, 3]])
    @test collect(c) == [UInt8[1], UInt8[2, 3]]
    @test eltype(collect(c)) == eltype(c)
    @test length(collect(c)) == length(c)
    @test isempty(c) isa Bool
end

@testset "table_with_slots infers" begin
    with_fixture() do chain, copy, dir
        v = table(copy, :samples)
        @test @inferred(table_with_slots(v))._slot == [1, 1]
    end
end
