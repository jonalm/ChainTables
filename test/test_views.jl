using Test
using ChainTables: ChainTables, Chain, WriteBuilderError, add_column!, column!, commit!,
    create_chain, create_table!, drop_column!, head, insert_rows!, primary_key!, shape,
    sync!, table, tables, update_rows!, write_builder
using ChainTables.Testing: InMemoryObjectStore
using Tables: Tables

function declare_samples!(w, name)
    create_table!(w, name) do t
        column!(t, :id, Int64)
        column!(t, :label, String)
        column!(t, :mass, Float64; nullable = true)
        primary_key!(t, :id)
    end
    return nothing
end

# A copy at slot 1 holding samples and pairs.
function with_fixture(f)
    return mktempdir() do dir
        store = InMemoryObjectStore()
        chain = Chain("bkt", "p"; store, cache_dir = joinpath(dir, "cache"))
        create_chain(chain)
        copy = ChainTables.open(chain, joinpath(dir, "one"))
        sync!(copy)
        w = write_builder(copy)
        declare_samples!(w, :samples)
        rows = [(id = 2, label = "b", mass = missing), (id = 1, label = "a", mass = 1.5)]
        insert_rows!(w, :samples, rows)
        create_table!(w, :pairs) do t
            column!(t, :n, Float64)
            column!(t, :a, Int64)
            column!(t, :b, String)
            primary_key!(t, :a, :b)
        end
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
    return commit!(w)
end

@testset "table returns one view per table per head" begin
    with_fixture() do chain, copy, dir
        v = table(copy, :samples)
        @test table(copy, :samples) === v
        @test table(copy, :pairs) !== v
    end
end

@testset "a commit! moves the copy and leaves the view taken" begin
    with_fixture() do chain, copy, dir
        v = table(copy, :samples)
        r = committed(w -> update_rows!(w, :samples, [(id = 2, mass = 2.5)]), copy)
        @test v[2].mass === missing
        @test v.slot == 1
        moved = table(copy, :samples)
        @test moved !== v
        @test moved[2].mass == 2.5
        @test moved.slot == 2
        @test moved.transaction_hash == r.transaction_hash
        @test table(copy, :samples) === moved
    end
end

@testset "a sync! moves the copy and leaves the view taken" begin
    with_fixture() do chain, copy, dir
        two = ChainTables.open(chain, joinpath(dir, "two"))
        sync!(two)
        v = table(two, :samples)
        @test isequal(collect(v), collect(table(copy, :samples)))
        committed(w -> update_rows!(w, :samples, [(id = 2, mass = 2.5)]), copy)
        @test sync!(two).slot == 2
        @test v[2].mass === missing
        @test table(two, :samples)[2].mass == 2.5
        close(two)
    end
end

@testset "a refused commit! keeps the cached view" begin
    with_fixture() do chain, copy, dir
        v = table(copy, :samples)
        w = write_builder(copy)
        insert_rows!(w, :samples, [(id = 2, label = "dup", mass = 0.0)])
        @test_throws WriteBuilderError "insert names a key that is present" commit!(w)
        @test table(copy, :samples) === v
    end
end

@testset "a view's rows go back into the write builder unchanged" begin
    with_fixture() do chain, copy, dir
        v = table(copy, :samples)
        committed(copy) do w
            update_rows!(w, :samples, [v[2]])
            update_rows!(w, :samples, [(id = 1, mass = missing)])
            declare_samples!(w, :again)
            insert_rows!(w, :again, Tables.rows(v))
        end
        @test table(copy, :samples)[2].mass === missing
        @test table(copy, :samples)[1].mass === missing
        @test isequal(collect(table(copy, :again)), collect(v))
    end
end

@testset "a commit! that reads a view does not change the head's content" begin
    with_fixture() do chain, copy, dir
        v = table(copy, :samples)
        @test_throws ArgumentError v.columns.label[1] = "zzz"
        row = (id = 3, label = "c", mass = 3.0)
        r = committed(w -> insert_rows!(w, :samples, [row]), copy)
        fresh = ChainTables.open(chain, joinpath(dir, "fresh"))
        @test sync!(fresh).slot == 2
        @test head(fresh) == head(copy)
        @test head(fresh).state_fingerprint == r.state_fingerprint
        close(fresh)
    end
end

const TABLE_REFUSALS = [
    (
        name = "an unknown table",
        table = :nope,
        message = "table(copy, :nope): unknown table \"nope\"",
    ),
    (
        name = "a name that is no Symbol",
        table = 1,
        message = "table(copy, 1): table name 1 is not a Symbol",
    ),
]

@testset "table refuses $(case.name)" for case in TABLE_REFUSALS
    with_fixture() do chain, copy, dir
        @test_throws ArgumentError case.message table(copy, case.table)
    end
end

@testset "table refuses a copy with no head" begin
    with_fixture() do chain, copy, dir
        fresh = ChainTables.open(chain, joinpath(dir, "fresh"))
        no_head = "the local copy at $(fresh.path) has no head yet; sync!(copy) binds it"
        @test_throws ArgumentError no_head table(fresh, :samples)
        close(fresh)
    end
end

const SAMPLES_SHAPE = (;
    columns = [
        (name = :id, type = Int64, nullable = false),
        (name = :label, type = String, nullable = false),
        (name = :mass, type = Float64, nullable = true),
    ],
    key = [:id],
)

@testset "shape returns the declaration of a table and of a view" begin
    with_fixture() do chain, copy, dir
        @test tables(copy) == ["pairs", "samples"]
        @test shape(copy, :samples) == SAMPLES_SHAPE
        @test shape(table(copy, :samples)) == SAMPLES_SHAPE
        @test shape(copy, :pairs).key == [:a, :b]
        n = (name = :n, type = Float64, nullable = false)
        @test first(shape(copy, :pairs).columns) == n
    end
end

@testset "shape follows add_column! and drop_column!" begin
    with_fixture() do chain, copy, dir
        committed(copy) do w
            add_column!(w, :samples, :note, String; nullable = true, fill = missing)
            drop_column!(w, :samples, :label)
        end
        expected = (;
            columns = [
                (name = :id, type = Int64, nullable = false),
                (name = :mass, type = Float64, nullable = true),
                (name = :note, type = String, nullable = true),
            ],
            key = [:id],
        )
        @test shape(copy, :samples) == expected
        @test isequal(table(copy, :samples)[1], (id = 1, mass = 1.5, note = missing))
    end
end

@testset "shape refuses an unknown table" begin
    with_fixture() do chain, copy, dir
        unknown = "shape(copy, :nope): unknown table \"nope\""
        @test_throws ArgumentError unknown shape(copy, :nope)
    end
end

@testset "shape infers" begin
    with_fixture() do chain, copy, dir
        @test @inferred(shape(copy, :samples)) == SAMPLES_SHAPE
        @test @inferred(shape(table(copy, :samples))) == SAMPLES_SHAPE
    end
end
