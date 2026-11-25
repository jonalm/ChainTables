using Test
using ChainTables: ChainTables, Ops, TableDeclaration, WriteBuilder, WriteBuilderError,
    add_column!, column!, commit!, create_table!, delete_rows!, drop_column!, drop_table!,
    insert_rows!, primary_key!, table, update_rows!, write_builder
using ChainTables.Model: Column, Shape
using ChainTables.Ops: AddColumn, CreateTable, DropColumn, DropTable, Insert

include("fixtures/chain_copies.jl")

# The ops that a builder holds are what `commit!` writes. No API name shows them before
# the commit, so these tests read the builder's `ops` field.

const SAMPLES = Shape(
    [
        Column("id", "int64", false), Column("label", "text", false),
        Column("mass", "float64", true),
    ],
    ["id"],
)
const TAGS = "Int64, Float64, String, Vector{UInt8}"
const TYPE_TAGS = [
    (tag = Int64, value_type = "int64"), (tag = Float64, value_type = "float64"),
    (tag = String, value_type = "text"), (tag = Vector{UInt8}, value_type = "bytes"),
]
const NOT_TAGS = [
    Any, Union{Missing, Int64}, Missing, Nothing, Vector{Int64}, SubString{String}, UInt8,
    Int128, Integer, Real, Symbol, Char,
]
const TAGS_WITH_A_HINT = [
    (tag = AbstractString, hint = "; a text column's tag is String"),
    (tag = Int32, hint = "; Int32 values widen at insert, the tag is Int64"),
    (tag = Float32, hint = "; Float32 values widen at insert, the tag is Float64"),
]
const COLUMN_NAME_REFUSALS = [
    (name = :Id, shown = ":Id", fault = "column name \"Id\" is not an identifier"),
    (name = :_slot, shown = ":_slot", fault = "column name \"_slot\" is not an identifier"),
    (name = :é, shown = ":é", fault = "column name \"é\" is not an identifier"),
    (name = "c\n", shown = "\"c\\n\"", fault = "column name \"c\\n\" is not an identifier"),
    (name = 1, shown = "1", fault = "column name 1 is not a Symbol"),
]
const TABLE_NAME_REFUSALS = [
    (
        name = :Samples,
        fault = "table name \"Samples\" is not an identifier ([a-z_][a-z0-9_]*)",
    ),
    (name = "1x", fault = "table name \"1x\" is not an identifier"),
    (name = "t\n", fault = "table name \"t\\n\" is not an identifier"),
    (name = 1, fault = "table name 1 is not a Symbol"),
    (name = :samples, fault = "table \"samples\" already exists"),
]
# Each case is a declaration block that `create_table!(w, :t)` refuses.
const DECLARATION_REFUSALS = [
    (
        name = "no column", declare = t -> nothing,
        fragment = "create_table!(w, :t): table has no columns",
    ),
    (
        name = "no primary key", declare = t -> column!(t, :c, Int64),
        fragment =
            "create_table!(w, :t): table has no primary key; every table needs an explicit key",
    ),
    (
        name = "a nullable key column",
        declare = t -> (column!(t, :m, Float64; nullable = true); primary_key!(t, :m)),
        fragment =
            "primary_key!(t, :m): key column \"m\" is nullable; key columns are non-nullable",
    ),
    (
        name = "a key column that is not declared",
        declare = t -> (column!(t, :c, Int64); primary_key!(t, :zz)),
        fragment = "primary_key!(t, :zz): key column \"zz\" is not a column of the table",
    ),
    (
        name = "a key column named twice",
        declare = t -> (column!(t, :c, Int64); primary_key!(t, :c, :c)),
        fragment = "primary_key!(t, :c, :c): duplicate key column \"c\"",
    ),
    (
        name = "a second primary key",
        declare = t -> (column!(t, :c, Int64); primary_key!(t, :c); primary_key!(t, :c)),
        fragment =
            "primary_key!(t, :c): primary_key! was already called; a table has one primary key",
    ),
    (
        name = "a key column that is no Symbol",
        declare = t -> (column!(t, :c, Int64); primary_key!(t, 1)),
        fragment = "primary_key!(t, 1): column name 1 is not a Symbol",
    ),
    (
        name = "a column declared twice",
        declare = t -> (column!(t, :c, Int64); column!(t, :c, String)),
        fragment = "column!(t, :c, String): duplicate column name \"c\"",
    ),
]
# Each case is a call on a builder over the table `samples` that the builder refuses.
const COLUMN_OP_REFUSALS = [
    (
        name = "add a column that exists",
        call = w -> add_column!(w, :samples, :label, String; fill = ""),
        fragment =
            "add_column!(w, :samples, :label, String): column \"label\" already exists",
    ),
    (
        name = "add a column of a type that is no tag",
        call = w -> add_column!(w, :samples, :c, Bool; fill = true),
        fragment =
            "add_column!(w, :samples, :c, Bool): type tag Bool for column \"c\" is not one of",
    ),
    (
        name = "add a column with a fill off its value type",
        call = w -> add_column!(w, :samples, :w, Float64; fill = "x"),
        fragment =
            "add_column!(w, :samples, :w, Float64): column \"w\" is float64, got a value of type String",
    ),
    (
        name = "add a non-nullable column with a null fill",
        call = w -> add_column!(w, :samples, :w, Int64; fill = missing),
        fragment =
            "add_column!(w, :samples, :w, Int64): column \"w\" is int64 and does not admit null",
    ),
    (
        name = "add a column with nothing as fill",
        call = w -> add_column!(w, :samples, :w, Int64; fill = nothing),
        fragment =
            "add_column!(w, :samples, :w, Int64): column \"w\": nothing is not a value",
    ),
    (
        name = "add a column whose name starts with an underscore",
        call = w -> add_column!(w, :samples, :_note, String; fill = ""),
        fragment =
            "add_column!(w, :samples, :_note, String): column name \"_note\" is not an identifier",
    ),
    (
        name = "add a column whose name ends in a newline",
        call = w -> add_column!(w, :samples, "c\n", String; fill = ""),
        fragment =
            "add_column!(w, :samples, \"c\\n\", String): column name \"c\\n\" is not an identifier",
    ),
    (
        name = "add a column to an unknown table",
        call = w -> add_column!(w, :nope, :c, Int64; fill = 0),
        fragment = "add_column!(w, :nope, :c, Int64): unknown table \"nope\"",
    ),
    (
        name = "drop a key column",
        call = w -> drop_column!(w, :samples, :id),
        fragment =
            "drop_column!(w, :samples, :id): column \"id\" is a key column and cannot be dropped",
    ),
    (
        name = "drop an unknown column",
        call = w -> drop_column!(w, :samples, :colour),
        fragment = "drop_column!(w, :samples, :colour): unknown column \"colour\"",
    ),
    (
        name = "drop a column of an unknown table",
        call = w -> drop_column!(w, :nope, :c),
        fragment = "drop_column!(w, :nope, :c): unknown table \"nope\"",
    ),
    (
        name = "drop an unknown table",
        call = w -> drop_table!(w, :nope),
        fragment = "drop_table!(w, :nope): unknown table \"nope\"",
    ),
]
# Each case is a call that a spent builder refuses.
const CALLS_ON_A_SPENT_BUILDER = [
    (name = "create_table!", call = w -> declare_samples!(w, :t)),
    (name = "add_column!", call = w -> add_column!(w, :samples, :n, Int64; fill = 0)),
    (name = "drop_column!", call = w -> drop_column!(w, :samples, :label)),
    (name = "drop_table!", call = w -> drop_table!(w, :samples)),
    (name = "insert_rows!", call = w -> insert_rows!(w, :samples, [(id = 3,)])),
    (name = "update_rows!", call = w -> update_rows!(w, :samples, [(id = 1, mass = 1.0)])),
    (name = "delete_rows!", call = w -> delete_rows!(w, :samples, [(id = 1,)])),
]

function declare_key_only!(t)
    column!(t, :k, Vector{UInt8})
    primary_key!(t, :k)
    return nothing
end

@testset "write_builder gives a builder bound to the copy's head" begin
    with_samples_copy() do local_copy
        w = write_builder(local_copy)
        @test w isa WriteBuilder
        @test w.copy === local_copy
        @test w.head === local_copy.head
        @test isempty(w.ops)
        @test !w.spent
    end
end

@testset "create_table! adds the op with the declared shape" begin
    with_empty_builder() do w
        @test declare_samples!(w) === nothing
        @test w.ops == [CreateTable("samples", SAMPLES)]
    end
end

@testset "create_table! passes a TableDeclaration to its block" begin
    with_empty_builder() do w
        create_table!(w, :t) do t
            @test t isa TableDeclaration
            @test @inferred(column!(t, :k, Int64)) === nothing
            @test @inferred(primary_key!(t, :k)) === nothing
        end
        @test @inferred(create_table!(declare_key_only!, w, :blobs)) === nothing
    end
end

@testset "create_table! takes a table name that starts with an underscore" begin
    with_empty_builder() do w
        declare_samples!(w, :_private)
        @test only(w.ops).table == "_private"
    end
end

@testset "create_table! refuses a table name" begin
    with_samples_builder() do w
        @testset "$(repr(case.name))" for case in TABLE_NAME_REFUSALS
            fragment = "create_table!(w, $(repr(case.name))): $(case.fault)"
            @test_throws WriteBuilderError fragment declare_samples!(w, case.name)
        end
        @test isempty(w.ops)
    end
end

@testset "create_table! refuses a declaration" begin
    with_empty_builder() do w
        @testset "$(case.name)" for case in DECLARATION_REFUSALS
            @test_throws WriteBuilderError case.fragment create_table!(case.declare, w, :t)
        end
        @test isempty(w.ops)
    end
end

@testset "column! takes each type tag as its value type" begin
    with_empty_builder() do w
        @testset "$(case.tag)" for case in TYPE_TAGS
            create_table!(w, :t) do t
                column!(t, :c, case.tag)
                primary_key!(t, :c)
            end
            @test w.ops[end].shape.columns == [Column("c", case.value_type, false)]
            drop_table!(w, :t)
        end
    end
end

@testset "column! declares a nullable column" begin
    with_empty_builder() do w
        create_table!(w, :t) do t
            column!(t, :k, Int64)
            column!(t, :v, String; nullable = true)
            primary_key!(t, :k)
        end
        @test only(w.ops).shape.columns[2] == Column("v", "text", true)
    end
end

@testset "column! refuses a type that is no type tag" begin
    with_empty_builder() do w
        @testset "$T" for T in NOT_TAGS
            @test_throws(
                WriteBuilderError, "type tag $T for column \"c\" is not one of $TAGS\n",
                create_table!(t -> column!(t, :c, T), w, :t)
            )
        end
        @test_throws(
            WriteBuilderError,
            "column!(t, :c, Bool): type tag Bool for column \"c\" is not one of $TAGS\n",
            create_table!(t -> column!(t, :c, Bool), w, :t)
        )
        @test_throws(
            WriteBuilderError,
            "column!(t, :c, \"int64\"): type tag \"int64\" for column \"c\" is not one of",
            create_table!(t -> column!(t, :c, "int64"), w, :t)
        )
    end
end

@testset "column! names the tag to use for a type that widens" begin
    with_empty_builder() do w
        @testset "$(case.tag)" for case in TAGS_WITH_A_HINT
            @test_throws(
                WriteBuilderError,
                "type tag $(case.tag) for column \"c\" is not one of $TAGS$(case.hint)\n",
                create_table!(t -> column!(t, :c, case.tag), w, :t)
            )
        end
    end
end

@testset "column! refuses a column name" begin
    with_empty_builder() do w
        @testset "$(case.shown)" for case in COLUMN_NAME_REFUSALS
            @test_throws(
                WriteBuilderError, "column!(t, $(case.shown), Int64): $(case.fault)",
                create_table!(t -> column!(t, case.name, Int64), w, :t)
            )
        end
    end
end

@testset "column! names the rule of a column name" begin
    with_empty_builder() do w
        @test_throws(
            WriteBuilderError,
            "is not an identifier ([a-z][a-z0-9_]*: a column name starts with a letter)",
            create_table!(t -> column!(t, :Id, Int64), w, :t)
        )
    end
end

@testset "column! is refused outside a create_table! block" begin
    with_empty_builder() do w
        @test_throws MethodError "no method matching column!" column!(w, :c, Int64)
    end
end

@testset "primary_key! keeps the key declaration order" begin
    with_empty_builder() do w
        create_table!(w, :grid) do t
            column!(t, :a, Int64)
            column!(t, :b, String)
            primary_key!(t, :b, :a)
        end
        @test only(w.ops).shape.key == ["b", "a"]
    end
end

@testset "add_column! adds the op with the column and its fill" begin
    with_samples_builder() do w
        @test @inferred(
            add_column!(w, :samples, :note, String; nullable = true, fill = missing)
        ) === nothing
        @test w.ops == [AddColumn("samples", Column("note", "text", true), missing)]
    end
end

@testset "add_column! widens its fill like a cell" begin
    with_samples_builder() do w
        add_column!(w, :samples, :n, Int64; fill = Int32(7))
        add_column!(w, :samples, :weight, Float64; fill = 1.0f0)
        @test w.ops[1].fill === Int64(7)
        @test w.ops[2].fill === 1.0
    end
end

@testset "drop_column! adds the op" begin
    with_samples_builder() do w
        @test @inferred(drop_column!(w, :samples, :label)) === nothing
        @test w.ops == [DropColumn("samples", "label")]
    end
end

@testset "drop_table! adds the op" begin
    with_samples_builder() do w
        @test @inferred(drop_table!(w, :samples)) === nothing
        @test w.ops == [DropTable("samples")]
    end
end

@testset "add_column!, drop_column! and drop_table! refuse a call" begin
    with_samples_builder() do w
        @testset "$(case.name)" for case in COLUMN_OP_REFUSALS
            @test_throws WriteBuilderError case.fragment case.call(w)
        end
        @test isempty(w.ops)
    end
end

@testset "a write builder follows the shape that its own ops leave" begin
    with_samples_builder() do w
        add_column!(w, :samples, :n, Int64; fill = 0)
        drop_column!(w, :samples, :label)
        @test_throws(
            WriteBuilderError,
            "insert_rows!(w, :samples): row set names no column \"n\"; an insert names " *
                "every column",
            insert_rows!(w, :samples, [(id = 3, mass = 1.0)])
        )
        insert_rows!(w, :samples, [(id = 3, mass = 1.0, n = 5)])
        @test w.ops[end] == Insert("samples", [Any[3, 1.0, 5]])
    end
end

@testset "a write builder frees the name of a table that it drops" begin
    with_samples_builder() do w
        drop_table!(w, :samples)
        @test_throws(
            WriteBuilderError, "insert_rows!(w, :samples): unknown table \"samples\"",
            insert_rows!(w, :samples, [(id = 3, label = "c", mass = 1.0)])
        )
        create_table!(w, :samples) do t
            column!(t, :id, Int64)
            primary_key!(t, :id)
        end
        insert_rows!(w, :samples, [(id = 1,)])
        @test length(w.ops) == 3
    end
end

@testset "a write builder leaves the local copy as it was" begin
    with_samples_copy() do local_copy
        w = write_builder(local_copy)
        drop_column!(w, :samples, :label)
        delete_rows!(w, :samples, [(id = 1,)])
        v = table(local_copy, :samples)
        @test v.columns.label == ["a", "b"]
        @test length(v) == 2
    end
end

@testset "a write builder's ops are the ops of the record that commit! writes" begin
    with_samples_copy() do local_copy
        w = write_builder(local_copy)
        add_column!(w, :samples, :note, String; nullable = true, fill = missing)
        update_rows!(w, :samples, [(id = 2, mass = NaN)])
        create_table!(declare_key_only!, w, :blobs)
        insert_rows!(w, :blobs, [(k = UInt8[1],), (k = UInt8[],)])
        ops = copy(w.ops)
        commit!(w)
        stored = local_copy.chain.store.objects["p/000000000002"]
        @test Ops.decode_record(stored; slot = 2).ops == ops
    end
end

@testset "a write builder is spent by commit!" begin
    with_samples_copy() do local_copy
        w = write_builder(local_copy)
        update_rows!(w, :samples, [(id = 2, mass = 2.5)])
        commit!(w)
        @test w.spent
        @test_throws(
            WriteBuilderError,
            "commit!(w): this builder is spent; a builder is used once, take a new one " *
                "with write_builder(copy)",
            commit!(w)
        )
    end
end

@testset "a spent write builder refuses every op function" begin
    with_samples_copy() do local_copy
        w = write_builder(local_copy)
        update_rows!(w, :samples, [(id = 2, mass = 2.5)])
        commit!(w)
        @testset "$(case.name)" for case in CALLS_ON_A_SPENT_BUILDER
            @test_throws(
                WriteBuilderError,
                "this builder is spent; commit! consumed it, take a new one with " *
                    "write_builder(copy)",
                case.call(w)
            )
        end
        @test length(w.ops) == 1
    end
end

@testset "a refused call names the call to fix on its second line" begin
    with_samples_builder() do w
        err = @test_throws(
            WriteBuilderError, "Correct the call that the message names.",
            drop_table!(w, :nope)
        )
        @test err.value.detail == "drop_table!(w, :nope): unknown table \"nope\""
    end
end
