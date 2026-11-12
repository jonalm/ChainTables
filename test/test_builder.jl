using Test
using ChainTables: ChainTables, Chain, ChainTablesError, WriteBuilderError, add_column!,
    column!, commit!, create_chain, create_table!, delete_rows!, drop_column!, drop_table!,
    insert_rows!, primary_key!, sync!, table, update_rows!, write_builder
using ChainTables.Testing: InMemoryObjectStore

function declare_samples!(w, name = :samples)
    create_table!(w, name) do t
        column!(t, :id, Int64)
        column!(t, :label, String)
        column!(t, :mass, Float64; nullable = true)
        primary_key!(t, :id)
    end
    return nothing
end

const SAMPLE_ROWS = [
    (id = 1, label = "a", mass = 1.5), (id = 2, label = "b", mass = missing),
]

# A copy whose head holds `samples` with rows 1 and 2.
function with_samples_copy(f)
    return mktempdir() do dir
        store = InMemoryObjectStore()
        chain = Chain("bkt", "p"; store, cache_dir = joinpath(dir, "cache"))
        create_chain(chain)
        copy = ChainTables.open(chain, joinpath(dir, "copy"))
        sync!(copy)
        w = write_builder(copy)
        declare_samples!(w)
        insert_rows!(w, :samples, SAMPLE_ROWS)
        commit!(w)
        try
            f(copy)
        finally
            close(copy)
        end
    end
end

const TAG_REFUSALS = [
    (name = "Bool", tag = Bool, hint = "not one of Int64, Float64, String, Vector{UInt8}."),
    (name = "AbstractString", tag = AbstractString, hint = "a text column's tag is String"),
    (name = "Int32", tag = Int32, hint = "Int32 values widen at insert, the tag is Int64"),
    (
        name = "Float32",
        tag = Float32,
        hint = "Float32 values widen at insert, the tag is Float64",
    ),
    (name = "Any", tag = Any, hint = "is not one of"),
    (name = "Union{Missing, Int64}", tag = Union{Missing, Int64}, hint = "is not one of"),
    (name = "Missing", tag = Missing, hint = "is not one of"),
    (name = "Nothing", tag = Nothing, hint = "is not one of"),
    (name = "Vector{Int64}", tag = Vector{Int64}, hint = "is not one of"),
    (name = "SubString{String}", tag = SubString{String}, hint = "is not one of"),
    (name = "UInt8", tag = UInt8, hint = "is not one of"),
    (name = "Int128", tag = Int128, hint = "is not one of"),
    (name = "Integer", tag = Integer, hint = "is not one of"),
    (name = "Real", tag = Real, hint = "is not one of"),
    (name = "Symbol", tag = Symbol, hint = "is not one of"),
    (name = "Char", tag = Char, hint = "is not one of"),
    (
        name = "a String",
        tag = "int64",
        hint = "type tag \"int64\" for column \"c\" is not one of",
    ),
]

@testset "column! refuses type tag $(case.name)" for case in TAG_REFUSALS
    with_samples_copy() do copy
        w = write_builder(copy)
        declare = t -> column!(t, :c, case.tag)
        @test_throws WriteBuilderError case.hint create_table!(declare, w, :t)
        call = "call = column!(t, :c, $(repr(case.tag)))"
        @test_throws WriteBuilderError call create_table!(declare, w, :t)
    end
end

const ROW = (id = 3, label = "c", mass = 1.0)

# Each case: the op on a fresh builder over `samples`, the call it names, the detail.
const REFUSALS = [
    (
        name = "insert into an unknown table",
        op = w -> insert_rows!(w, :nope, [ROW]),
        call = "insert_rows!(w, :nope)",
        detail = "unknown table \"nope\"",
    ),
    (
        name = "update of an unknown table",
        op = w -> update_rows!(w, :nope, [ROW]),
        call = "update_rows!(w, :nope)",
        detail = "unknown table \"nope\"",
    ),
    (
        name = "delete from an unknown table",
        op = w -> delete_rows!(w, :nope, [(id = 1,)]),
        call = "delete_rows!(w, :nope)",
        detail = "unknown table \"nope\"",
    ),
    (
        name = "add_column! to an unknown table",
        op = w -> add_column!(w, :nope, :c, Int64; fill = 0),
        call = "add_column!(w, :nope, :c, Int64)",
        detail = "unknown table \"nope\"",
    ),
    (
        name = "drop_column! of an unknown table",
        op = w -> drop_column!(w, :nope, :c),
        call = "drop_column!(w, :nope, :c)",
        detail = "unknown table \"nope\"",
    ),
    (
        name = "drop_table! of an unknown table",
        op = w -> drop_table!(w, :nope),
        call = "drop_table!(w, :nope)",
        detail = "unknown table \"nope\"",
    ),
    (
        name = "insert of an unknown column",
        op = w -> insert_rows!(w, :samples, [(ROW..., colour = "red")]),
        call = "insert_rows!(w, :samples)",
        detail = "unknown column \"colour\"",
    ),
    (
        name = "update of an unknown column",
        op = w -> update_rows!(w, :samples, [(id = 1, colour = "red")]),
        call = "update_rows!(w, :samples)",
        detail = "unknown column \"colour\"",
    ),
    (
        name = "delete naming an unknown column",
        op = w -> delete_rows!(w, :samples, [(id = 1, colour = "red")]),
        call = "delete_rows!(w, :samples)",
        detail = "unknown column \"colour\"",
    ),
    (
        name = "drop_column! of an unknown column",
        op = w -> drop_column!(w, :samples, :colour),
        call = "drop_column!(w, :samples, :colour)",
        detail = "unknown column \"colour\"",
    ),
    (
        name = "add_column! with a refused tag",
        op = w -> add_column!(w, :samples, :c, Bool; fill = true),
        call = "add_column!(w, :samples, :c, Bool)",
        detail = "type tag Bool for column \"c\" is not one of",
    ),
    (
        name = "insert with non-uniform columns",
        op = w -> insert_rows!(w, :samples, [ROW, (id = 4, label = "d")]),
        call = "insert_rows!(w, :samples)",
        detail = "row 2 names columns (:id, :label) but row 1 names " *
            "(:id, :label, :mass); the columns of an op are uniform",
    ),
    (
        name = "update with non-uniform columns",
        op = w -> update_rows!(w, :samples, [(id = 1, mass = 1.0), (id = 2, label = "d")]),
        call = "update_rows!(w, :samples)",
        detail = "row 2 names columns (:id, :label) but row 1 names (:id, :mass)",
    ),
    (
        name = "delete with non-uniform columns",
        op = w -> delete_rows!(w, :samples, [(id = 1,), (id = 2,), (id = 3, label = "x")]),
        call = "delete_rows!(w, :samples)",
        detail = "row 3 names columns (:id, :label) but row 1 names (:id,)",
    ),
    (
        name = "insert with a duplicate key",
        op = w -> insert_rows!(w, :samples, [ROW, (ROW..., label = "d")]),
        call = "insert_rows!(w, :samples)",
        detail = "duplicate key (3,) inside one op",
    ),
    (
        name = "update with a duplicate key",
        op = w -> update_rows!(w, :samples, [(id = 1, mass = 1.0), (id = 1, mass = 2.0)]),
        call = "update_rows!(w, :samples)",
        detail = "duplicate key (1,) inside one op",
    ),
    (
        name = "delete with a duplicate key",
        op = w -> delete_rows!(w, :samples, [(id = 1,), (id = 1,)]),
        call = "delete_rows!(w, :samples)",
        detail = "duplicate key (1,) inside one op",
    ),
    (
        name = "a table name that is no identifier",
        op = w -> declare_samples!(w, :Samples),
        call = "create_table!(w, :Samples)",
        detail = "table name \"Samples\" is not an identifier ([a-z_][a-z0-9_]*)",
    ),
    (
        name = "a table name starting with a digit",
        op = w -> declare_samples!(w, "1x"),
        call = "create_table!(w, \"1x\")",
        detail = "table name \"1x\" is not an identifier",
    ),
    (
        name = "a table name with a trailing newline",
        op = w -> declare_samples!(w, "t\n"),
        call = "create_table!(w, \"t\\n\")",
        detail = "table name \"t\\n\" is not an identifier",
    ),
    (
        name = "an upper-case column name",
        op = w -> create_table!(t -> column!(t, :Id, Int64), w, :t),
        call = "column!(t, :Id, Int64)",
        detail = "column name \"Id\" is not an identifier " *
            "([a-z][a-z0-9_]*: a column name starts with a letter)",
    ),
    (
        name = "the column name _slot",
        op = w -> create_table!(t -> column!(t, :_slot, Int64), w, :t),
        call = "column!(t, :_slot, Int64)",
        detail = "column name \"_slot\" is not an identifier",
    ),
    (
        name = "a column name with a trailing newline",
        op = w -> create_table!(t -> column!(t, "c\n", Int64), w, :t),
        call = "column!(t, \"c\\n\", Int64)",
        detail = "column name \"c\\n\" is not an identifier",
    ),
    (
        name = "a non-ASCII column name",
        op = w -> create_table!(t -> column!(t, :é, Int64), w, :t),
        call = "column!(t, :é, Int64)",
        detail = "column name \"é\" is not an identifier",
    ),
    (
        name = "an added column starting with _",
        op = w -> add_column!(w, :samples, :_note, String; fill = ""),
        call = "add_column!(w, :samples, :_note, String)",
        detail = "column name \"_note\" is not an identifier",
    ),
    (
        name = "an added upper-case column",
        op = w -> add_column!(w, :samples, :Colour, String; fill = ""),
        call = "add_column!(w, :samples, :Colour, String)",
        detail = "column name \"Colour\" is not an identifier",
    ),
    (
        name = "an added column with a trailing newline",
        op = w -> add_column!(w, :samples, "c\n", String; fill = ""),
        call = "add_column!(w, :samples, \"c\\n\", String)",
        detail = "column name \"c\\n\" is not an identifier",
    ),
    (
        name = "a table without a primary key",
        op = w -> create_table!(t -> column!(t, :c, Int64), w, :t),
        call = "create_table!(w, :t)",
        detail = "table has no primary key; every table needs an explicit key",
    ),
    (
        name = "a table without columns",
        op = w -> create_table!(t -> nothing, w, :t),
        call = "create_table!(w, :t)",
        detail = "table has no columns",
    ),
    (
        name = "a table name already in use",
        op = w -> declare_samples!(w),
        call = "create_table!(w, :samples)",
        detail = "table \"samples\" already exists",
    ),
    (
        name = "an insert missing a column",
        op = w -> insert_rows!(w, :samples, [(id = 3, label = "c")]),
        call = "insert_rows!(w, :samples)",
        detail = "row set names no column \"mass\"; an insert names every column",
    ),
    (
        name = "an update missing the key",
        op = w -> update_rows!(w, :samples, [(mass = 1.0,)]),
        call = "update_rows!(w, :samples)",
        detail = "row set names no key column \"id\"; an update names the full key",
    ),
    (
        name = "an update of no non-key column",
        op = w -> update_rows!(w, :samples, [(id = 1,)]),
        call = "update_rows!(w, :samples)",
        detail = "update names no non-key column",
    ),
    (
        name = "a delete naming a non-key column",
        op = w -> delete_rows!(w, :samples, [(id = 1, label = "a")]),
        call = "delete_rows!(w, :samples)",
        detail = "row set names column \"label\"; a delete names the key columns only",
    ),
    (
        name = "a delete missing the key",
        op = w -> delete_rows!(w, :samples, [NamedTuple()]),
        call = "delete_rows!(w, :samples)",
        detail = "row set names no key column \"id\"; a delete names the full key",
    ),
    (
        name = "an added column that exists",
        op = w -> add_column!(w, :samples, :label, String; fill = ""),
        call = "add_column!(w, :samples, :label, String)",
        detail = "column \"label\" already exists",
    ),
    (
        name = "dropping a key column",
        op = w -> drop_column!(w, :samples, :id),
        call = "drop_column!(w, :samples, :id)",
        detail = "column \"id\" is a key column and cannot be dropped",
    ),
    (
        name = "one NamedTuple as a row set",
        op = w -> insert_rows!(w, :samples, ROW),
        call = "insert_rows!(w, :samples)",
        detail = "a row set is a collection of rows, got one NamedTuple; " *
            "wrap it in a vector",
    ),
    (
        name = "an empty insert",
        op = w -> insert_rows!(w, :samples, NamedTuple[]),
        call = "insert_rows!(w, :samples)",
        detail = "the row set is empty; an op carries at least one row",
    ),
    (
        name = "an empty delete",
        op = w -> delete_rows!(w, :samples, ()),
        call = "delete_rows!(w, :samples)",
        detail = "the row set is empty",
    ),
    (
        name = "a vector as a row",
        op = w -> insert_rows!(w, :samples, [Any[3, "c", 1.0]]),
        call = "insert_rows!(w, :samples)",
        detail = "row 1 is not a row (a NamedTuple or a Tables.jl row), " *
            "got a value of type Vector{Any}",
    ),
    (
        name = "an integer as a row",
        op = w -> delete_rows!(w, :samples, [(id = 1,), 2]),
        call = "delete_rows!(w, :samples)",
        detail = "row 2 is not a row (a NamedTuple or a Tables.jl row), " *
            "got a value of type Int64",
    ),
    (
        name = "a table name that is no Symbol",
        op = w -> insert_rows!(w, 1, [ROW]),
        call = "insert_rows!(w, 1)",
        detail = "table name 1 is not a Symbol",
    ),
    (
        name = "a column name that is no Symbol",
        op = w -> create_table!(t -> column!(t, 1, Int64), w, :t),
        call = "column!(t, 1, Int64)",
        detail = "column name 1 is not a Symbol",
    ),
]

@testset "write builder refuses $(case.name)" for case in REFUSALS
    with_samples_copy() do copy
        @test_throws WriteBuilderError case.detail case.op(write_builder(copy))
        @test_throws WriteBuilderError "call = $(case.call)" case.op(write_builder(copy))
    end
end

const KEY_REFUSALS = [
    (
        name = "a nullable key column",
        declare = t -> (column!(t, :m, Float64; nullable = true); primary_key!(t, :m)),
        call = "primary_key!(t, :m)",
        detail = "key column \"m\" is nullable; key columns are non-nullable",
    ),
    (
        name = "a key column that is not declared",
        declare = t -> (column!(t, :c, Int64); primary_key!(t, :zz)),
        call = "primary_key!(t, :zz)",
        detail = "key column \"zz\" is not a column of the table",
    ),
    (
        name = "a key column named twice",
        declare = t -> (column!(t, :c, Int64); primary_key!(t, :c, :c)),
        call = "primary_key!(t, :c, :c)",
        detail = "duplicate key column \"c\"",
    ),
    (
        name = "a second primary_key!",
        declare = t -> (column!(t, :c, Int64); primary_key!(t, :c); primary_key!(t, :c)),
        call = "primary_key!(t, :c)",
        detail = "primary_key! was already called; a table has one key",
    ),
    (
        name = "a column declared twice",
        declare = t -> (column!(t, :c, Int64); column!(t, :c, String)),
        call = "column!(t, :c, String)",
        detail = "duplicate column name \"c\"",
    ),
]

@testset "create_table! refuses $(case.name)" for case in KEY_REFUSALS
    with_samples_copy() do copy
        w = write_builder(copy)
        @test_throws WriteBuilderError case.detail create_table!(case.declare, w, :t)
        call = "call = $(case.call)"
        @test_throws WriteBuilderError call create_table!(case.declare, w, :t)
    end
end

@testset "a refused call leaves the builder as it was" begin
    with_samples_copy() do copy
        w = write_builder(copy)
        @test_throws WriteBuilderError insert_rows!(w, :samples, [(id = 3, label = "c")])
        @test_throws WriteBuilderError drop_table!(w, :nope)
        insert_rows!(w, :samples, [ROW])
        commit!(w)
        @test length(table(copy, :samples)) == 3
    end
end

@testset "WriteBuilderError is a ChainTablesError" begin
    @test WriteBuilderError <: ChainTablesError
end

@testset "column! outside a create_table! block is a MethodError" begin
    with_samples_copy() do copy
        @test_throws MethodError column!(write_builder(copy), :c, Int64)
    end
end

@testset "create_table! accepts a table name starting with _" begin
    with_samples_copy() do copy
        w = write_builder(copy)
        declare_samples!(w, :_private)
        commit!(w)
        @test length(table(copy, :_private)) == 0
    end
end

@testset "the builder tracks the shape its own ops leave" begin
    with_samples_copy() do copy
        w = write_builder(copy)
        add_column!(w, :samples, :n, Int64; fill = 0)
        missing_n = "row set names no column \"n\""
        @test_throws WriteBuilderError missing_n insert_rows!(w, :samples, [ROW])
        insert_rows!(w, :samples, [(ROW..., n = 5)])
        drop_table!(w, :samples)
        unknown = "unknown table \"samples\""
        @test_throws WriteBuilderError unknown insert_rows!(w, :samples, [ROW])
        create_table!(w, :samples) do t
            column!(t, :id, Int64)
            primary_key!(t, :id)
        end
        insert_rows!(w, :samples, [(id = 1,)])
        commit!(w)
        @test collect(table(copy, :samples)) == [(id = 1,)]
    end
end

@testset "the seven ops commit and replay" begin
    with_samples_copy() do copy
        w = write_builder(copy)
        @test update_rows!(w, :samples, [(id = 2, mass = 2.5)]) === nothing
        @test delete_rows!(w, :samples, [(id = 1,)]) === nothing
        @test add_column!(w, :samples, :note, String; nullable = true, fill = missing) ===
            nothing
        @test add_column!(w, :samples, :weight, Float64; fill = 1.0f0) === nothing
        @test drop_column!(w, :samples, :label) === nothing
        create_table!(w, :tags) do t
            column!(t, :k, Vector{UInt8})
            primary_key!(t, :k)
        end
        @test insert_rows!(w, :tags, [(k = UInt8[1],), (k = UInt8[],)]) === nothing
        @test drop_table!(w, :tags) === nothing
        commit!(w)
        expected = [(id = 2, mass = 2.5, note = missing, weight = 1.0)]
        @test isequal(collect(table(copy, :samples)), expected)
        @test_throws ArgumentError "unknown table \"tags\"" table(copy, :tags)
    end
end

@testset "commit! spends the builder" begin
    with_samples_copy() do copy
        w = write_builder(copy)
        insert_rows!(w, :samples, [ROW])
        commit!(w)
        @test_throws WriteBuilderError "this builder is spent" commit!(w)
        @test_throws WriteBuilderError "call = commit!(w)" commit!(w)
        insert_call = "call = insert_rows!(w, :samples)"
        @test_throws WriteBuilderError insert_call insert_rows!(w, :samples, [ROW])
        spent = "this builder is spent: commit! consumed it"
        @test_throws WriteBuilderError spent insert_rows!(w, :samples, [ROW])
        @test_throws WriteBuilderError "this builder is spent" declare_samples!(w, :t)
        @test_throws WriteBuilderError "this builder is spent" drop_table!(w, :samples)
    end
end

@testset "write builder ops infer Nothing" begin
    with_samples_copy() do copy
        w = write_builder(copy)
        declare = t -> (column!(t, :k, Int64); primary_key!(t, :k))
        @test @inferred(create_table!(declare, w, :t)) === nothing
        @test @inferred(insert_rows!(w, :samples, [ROW])) === nothing
        @test @inferred(update_rows!(w, :samples, [(id = 1, mass = 2.0)])) === nothing
        @test @inferred(delete_rows!(w, :samples, [(id = 2,)])) === nothing
        @test @inferred(add_column!(w, :samples, :n, Int64; fill = 0)) === nothing
        @test @inferred(drop_column!(w, :samples, :n)) === nothing
        @test @inferred(drop_table!(w, :t)) === nothing
    end
end

@testset "column! and primary_key! infer Nothing" begin
    with_samples_copy() do copy
        create_table!(write_builder(copy), :t) do t
            @test @inferred(column!(t, :k, Int64)) === nothing
            @test @inferred(primary_key!(t, :k)) === nothing
        end
    end
end
