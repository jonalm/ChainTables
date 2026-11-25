using Test
using ChainTables: ChainTables, LocalCopyInconsistentError, TableView, WriteBuilderError,
    add_column!, drop_column!, shape, table, update_rows!

include("fixtures/chain_copies.jl")

const SAMPLES_SHAPE = (;
    columns = [
        (name = :id, type = Int64, nullable = false),
        (name = :label, type = String, nullable = false),
        (name = :mass, type = Float64, nullable = true),
    ],
    key = [:id],
)

@testset "table gives the same view until the head moves" begin
    with_tables_copy() do local_copy
        v = table(local_copy, :samples)
        @test v isa TableView
        @test table(local_copy, :samples) === v
        @test table(local_copy, "samples") === v
        @test table(local_copy, :pairs) !== v
    end
end

@testset "table gives a new view after a commit" begin
    with_tables_copy() do local_copy
        v = table(local_copy, :samples)
        committed = commit_ops!(local_copy) do w
            update_rows!(w, :samples, [(id = 2, mass = 2.5)])
        end
        moved = table(local_copy, :samples)
        @test moved !== v
        @test moved.slot == 2
        @test moved.transaction_hash == committed.transaction_hash
        @test table(local_copy, :samples) === moved
    end
end

@testset "table gives a new view after a sync" begin
    with_tables_copy() do local_copy
        mktempdir() do dir
            other = ChainTables.open(local_copy.chain, dir)
            sync!(other)
            v = table(other, :samples)
            commit_ops!(w -> update_rows!(w, :samples, [(id = 2, mass = 2.5)]), local_copy)
            sync!(other)
            @test table(other, :samples) !== v
            @test table(other, :samples)[2].mass == 2.5
            @test v[2].mass === missing
            close(other)
        end
    end
end

@testset "table keeps its view when a commit is refused" begin
    with_tables_copy() do local_copy
        v = table(local_copy, :samples)
        w = write_builder(local_copy)
        insert_rows!(w, :samples, [(id = 2, label = "dup", mass = 0.0)])
        @test_throws WriteBuilderError "insert names a key that is present" commit!(w)
        @test table(local_copy, :samples) === v
    end
end

@testset "table drops its views when the copy closes" begin
    with_tables_copy() do local_copy
        table(local_copy, :samples)
        close(local_copy)
        @test isempty(local_copy.views)
    end
end

@testset "table refuses an unknown table" begin
    with_tables_copy() do local_copy
        @test_throws(
            ArgumentError, "table(copy, :nope): unknown table \"nope\"",
            table(local_copy, :nope)
        )
    end
end

@testset "table refuses a name that is no Symbol or text" begin
    with_tables_copy() do local_copy
        @test_throws(
            ArgumentError, "table(copy, 1): table name 1 is not a Symbol",
            table(local_copy, 1)
        )
    end
end

@testset "table refuses a copy with no head" begin
    with_tables_copy() do local_copy
        mktempdir() do dir
            fresh = ChainTables.open(local_copy.chain, dir)
            @test_throws(
                ArgumentError, "has no head yet; sync!(copy) binds it",
                table(fresh, :samples)
            )
            close(fresh)
        end
    end
end

@testset "table refuses a closed copy" begin
    with_tables_copy() do local_copy
        close(local_copy)
        @test_throws ArgumentError "is closed" table(local_copy, :samples)
    end
end

@testset "table refuses a damaged table file" begin
    with_tables_copy() do local_copy
        path = local_copy.path
        chain = local_copy.chain
        close(local_copy)
        again = ChainTables.open(chain, path)
        file = joinpath(path, "tables", bytes2hex(again.tables["samples"]))
        write(file, "changed")
        err = @test_throws(
            LocalCopyInconsistentError, "Run `repair!(copy)`", table(again, :samples)
        )
        @test err.value.reason === :table_file_hash
        close(again)
    end
end

@testset "shape gives the declaration of a table" begin
    with_tables_copy() do local_copy
        @test @inferred(shape(local_copy, :samples)) == SAMPLES_SHAPE
        @test shape(local_copy, "samples") == SAMPLES_SHAPE
        @test shape(local_copy, :pairs).key == [:a, :b]
        @test shape(local_copy, :blobs).columns[1] ==
            (name = :k, type = Vector{UInt8}, nullable = false)
    end
end

@testset "shape of a view is the shape at the view's head" begin
    with_tables_copy() do local_copy
        v = table(local_copy, :samples)
        commit_ops!(w -> drop_column!(w, :samples, :label), local_copy)
        @test @inferred(shape(v)) == SAMPLES_SHAPE
    end
end

@testset "shape follows the column ops" begin
    with_tables_copy() do local_copy
        commit_ops!(local_copy) do w
            add_column!(w, :samples, :note, String; nullable = true, fill = missing)
            drop_column!(w, :samples, :label)
        end
        @test shape(local_copy, :samples).columns == [
            (name = :id, type = Int64, nullable = false),
            (name = :mass, type = Float64, nullable = true),
            (name = :note, type = String, nullable = true),
        ]
        @test isequal(table(local_copy, :samples)[1], (id = 1, mass = 1.5, note = missing))
    end
end

@testset "shape refuses an unknown table" begin
    with_tables_copy() do local_copy
        @test_throws(
            ArgumentError, "shape(copy, :nope): unknown table \"nope\"",
            shape(local_copy, :nope)
        )
    end
end

@testset "shape refuses a name that is no Symbol or text" begin
    with_tables_copy() do local_copy
        @test_throws(
            ArgumentError, "shape(copy, 1): table name 1 is not a Symbol",
            shape(local_copy, 1)
        )
    end
end
