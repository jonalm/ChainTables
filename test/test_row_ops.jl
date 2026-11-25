using Test
using Tables: Tables
using ChainTables: ChainTables, WriteBuilderError, column!, create_table!, delete_rows!,
    insert_rows!, primary_key!, update_rows!
using ChainTables.Ops: Delete, Insert, Update

include("fixtures/chain_copies.jl")

# The ops that a builder holds are what `commit!` writes. No API name shows them before
# the commit, so these tests read the builder's `ops` field.

# A type that is no typed value and no row.
struct NotAValue
    year::Int
end

const SIGNBIT_NAN = reinterpret(Float64, 0xfff8000000000000)
const CANONICAL_NAN_BITS = 0x7ff8000000000000

const SAMPLE_3 = (id = 3, label = "c", mass = 1.0)

# Each case is a cell that `insert_rows!` refuses, in a row of the table `samples`.
const REFUSED_CELLS = [
    (
        name = "a float in an int64 column", row = (id = 1.0, label = "a", mass = 1.0),
        fragment =
            "insert_rows!(w, :samples): column \"id\" is int64, got a value of type Float64",
    ),
    (
        name = "a bool in an int64 column", row = (id = true, label = "a", mass = 1.0),
        fragment = "column \"id\" is int64, got a value of type Bool",
    ),
    (
        name = "an unsigned integer", row = (id = UInt64(1), label = "a", mass = 1.0),
        fragment = "column \"id\" is int64, got a value of type UInt64",
    ),
    (
        name = "an integer in a float64 column", row = (id = 1, label = "a", mass = 1),
        fragment = "column \"mass\" is float64, got a value of type Int64",
    ),
    (
        name = "a Symbol in a text column", row = (id = 1, label = :a, mass = 1.0),
        fragment = "column \"label\" is text, got a value of type Symbol",
    ),
    (
        name = "a value of another type",
        row = (id = 1, label = NotAValue(2020), mass = 1.0),
        fragment = "column \"label\" is text, got a value of type ",
    ),
    (
        name = "null in a non-nullable column", row = (id = 1, label = missing, mass = 1.0),
        fragment = "column \"label\" is text and does not admit null",
    ),
    (
        name = "nothing", row = (id = 1, label = "a", mass = nothing),
        fragment = "column \"mass\": nothing is not a value; null is spelt missing",
    ),
    (
        name = "text that is not UTF-8", row = (id = 1, label = "\xff", mass = 1.0),
        fragment = "column \"label\" is not well-formed UTF-8",
    ),
    (
        name = "text with U+0000", row = (id = 1, label = "a\0", mass = 1.0),
        fragment = "column \"label\" contains U+0000",
    ),
]
# Each case is a call on a builder over the table `samples` that the builder refuses.
const ROW_SET_REFUSALS = [
    (
        name = "insert into an unknown table",
        call = w -> insert_rows!(w, :nope, [(id = 1,)]),
        fragment = "insert_rows!(w, :nope): unknown table \"nope\"",
    ),
    (
        name = "update an unknown table",
        call = w -> update_rows!(w, :nope, [(id = 1,)]),
        fragment = "update_rows!(w, :nope): unknown table \"nope\"",
    ),
    (
        name = "delete from an unknown table",
        call = w -> delete_rows!(w, :nope, [(id = 1,)]),
        fragment = "delete_rows!(w, :nope): unknown table \"nope\"",
    ),
    (
        name = "a table name that is no Symbol",
        call = w -> insert_rows!(w, 1, [(id = 1,)]),
        fragment = "insert_rows!(w, 1): table name 1 is not a Symbol",
    ),
    (
        name = "insert an unknown column",
        call = w -> insert_rows!(w, :samples, [(; SAMPLE_3..., hue = "red")]),
        fragment = "insert_rows!(w, :samples): unknown column \"hue\"",
    ),
    (
        name = "update an unknown column",
        call = w -> update_rows!(w, :samples, [(id = 1, colour = "red")]),
        fragment = "update_rows!(w, :samples): unknown column \"colour\"",
    ),
    (
        name = "delete with an unknown column",
        call = w -> delete_rows!(w, :samples, [(id = 1, colour = "red")]),
        fragment = "delete_rows!(w, :samples): unknown column \"colour\"",
    ),
    (
        name = "insert without a column",
        call = w -> insert_rows!(w, :samples, [(id = 3, label = "c")]),
        fragment =
            "insert_rows!(w, :samples): row set names no column \"mass\"; an insert names every column",
    ),
    (
        name = "update without the key",
        call = w -> update_rows!(w, :samples, [(mass = 1.0,)]),
        fragment =
            "update_rows!(w, :samples): row set names no key column \"id\"; an update names the full key",
    ),
    (
        name = "update with the key only",
        call = w -> update_rows!(w, :samples, [(id = 1,)]),
        fragment = "update_rows!(w, :samples): update names no non-key column",
    ),
    (
        name = "update a cell off its value type",
        call = w -> update_rows!(w, :samples, [(id = 1, mass = "x")]),
        fragment =
            "update_rows!(w, :samples): column \"mass\" is float64, got a value of type String",
    ),
    (
        name = "delete with a column that is no key column",
        call = w -> delete_rows!(w, :samples, [(id = 1, label = "a")]),
        fragment =
            "delete_rows!(w, :samples): row set names column \"label\"; a delete names the key columns only",
    ),
    (
        name = "delete without the key",
        call = w -> delete_rows!(w, :samples, [NamedTuple()]),
        fragment =
            "delete_rows!(w, :samples): row set names no key column \"id\"; a delete names the full key",
    ),
    (
        name = "delete a key off its value type",
        call = w -> delete_rows!(w, :samples, [(id = 1.0,)]),
        fragment =
            "delete_rows!(w, :samples): column \"id\" is int64, got a value of type Float64",
    ),
    (
        name = "insert rows that name different columns",
        call = w -> insert_rows!(w, :samples, [SAMPLE_3, (id = 4, label = "d")]),
        fragment =
            "insert_rows!(w, :samples): row 2 names columns (:id, :label) but row 1 names (:id, :label, :mass); the columns of an op are uniform",
    ),
    (
        name = "update rows that name different columns",
        call = w -> update_rows!(w, :samples, [(id = 1, mass = 1.0), (id = 2, label = "")]),
        fragment =
            "update_rows!(w, :samples): row 2 names columns (:id, :label) but row 1 names (:id, :mass)",
    ),
    (
        name = "delete rows that name different columns",
        call = w -> delete_rows!(w, :samples, [(id = 1,), (id = 2,), (id = 3, label = "")]),
        fragment =
            "delete_rows!(w, :samples): row 3 names columns (:id, :label) but row 1 names (:id,)",
    ),
    (
        name = "insert a key twice",
        call = w -> insert_rows!(w, :samples, [SAMPLE_3, SAMPLE_3]),
        fragment = "insert_rows!(w, :samples): duplicate key (3,) inside one op",
    ),
    (
        name = "update a key twice",
        call = w -> update_rows!(w, :samples, [(id = 1, mass = 1.0), (id = 1, mass = 2.0)]),
        fragment = "update_rows!(w, :samples): duplicate key (1,) inside one op",
    ),
    (
        name = "delete a key twice",
        call = w -> delete_rows!(w, :samples, [(id = 1,), (id = 1,)]),
        fragment = "delete_rows!(w, :samples): duplicate key (1,) inside one op",
    ),
    (
        name = "one NamedTuple in place of a row set",
        call = w -> insert_rows!(w, :samples, (id = 3, label = "c", mass = 1.0)),
        fragment =
            "insert_rows!(w, :samples): a row set is a collection of rows, got one NamedTuple; wrap the row in a vector",
    ),
    (
        name = "an empty row set to insert",
        call = w -> insert_rows!(w, :samples, NamedTuple[]),
        fragment =
            "insert_rows!(w, :samples): the row set is empty; an op carries at least one row",
    ),
    (
        name = "an empty row set to delete",
        call = w -> delete_rows!(w, :samples, ()),
        fragment =
            "delete_rows!(w, :samples): the row set is empty; an op carries at least one row",
    ),
    (
        name = "a vector in place of a row",
        call = w -> insert_rows!(w, :samples, [Any[3, "c", 1.0]]),
        fragment =
            "insert_rows!(w, :samples): row 1 is not a row (a NamedTuple or a Tables.jl row), got a value of type Vector{Any}",
    ),
    (
        name = "a number in place of a row",
        call = w -> delete_rows!(w, :samples, [(id = 1,), 2]),
        fragment =
            "delete_rows!(w, :samples): row 2 is not a row (a NamedTuple or a Tables.jl row), got a value of type Int64",
    ),
    (
        name = "keys of two types to insert",
        call = w -> insert_rows!(w, :samples, [SAMPLE_3, (; SAMPLE_3..., id = :x)]),
        fragment =
            "insert_rows!(w, :samples): column \"id\" is int64, got a value of type Symbol",
    ),
    (
        name = "keys of two types to delete",
        call = w -> delete_rows!(w, :samples, [(id = 1,), (id = "x",)]),
        fragment =
            "delete_rows!(w, :samples): column \"id\" is int64, got a value of type String",
    ),
]

function declare_grid!(w)
    return create_table!(w, :grid) do t
        column!(t, :a, Int64)
        column!(t, :b, String)
        column!(t, :v, Int64; nullable = true)
        primary_key!(t, :b, :a)
    end
end

function declare_blobs!(w)
    return create_table!(w, :blobs) do t
        column!(t, :k, Vector{UInt8})
        primary_key!(t, :k)
    end
end

function declare_points!(w)
    return create_table!(w, :points) do t
        column!(t, :label, String; nullable = true)
        column!(t, :x, Float64)
        primary_key!(t, :x)
    end
end

@testset "insert_rows! adds the op with its cells in declaration order" begin
    with_samples_builder() do w
        rows = [(mass = 3.5, id = 3, label = "c")]
        @test @inferred(insert_rows!(w, :samples, rows)) === nothing
        @test w.ops == [Insert("samples", [Any[3, "c", 3.5]])]
    end
end

@testset "insert_rows! sorts its rows by the typed key order" begin
    with_empty_builder() do w
        declare_points!(w)
        rows = [
            (x = NaN, label = "nan"), (x = 0.0, label = "zero"), (x = Inf, label = missing),
            (x = -0.0, label = "negative zero"), (x = 1.5, label = "one and a half"),
            (x = -Inf, label = "-inf"),
        ]
        insert_rows!(w, :points, rows)
        @test w.ops[end] == Insert(
            "points", [
                Any["-inf", -Inf], Any["negative zero", -0.0], Any["zero", 0.0],
                Any["one and a half", 1.5], Any[missing, Inf], Any["nan", NaN],
            ]
        )
    end
end

@testset "insert_rows! sorts a composite key in key declaration order" begin
    with_empty_builder() do w
        declare_grid!(w)
        rows = [(a = 2, b = "x", v = 1), (a = 1, b = "y", v = 2), (a = 1, b = "x", v = 3)]
        insert_rows!(w, :grid, rows)
        @test w.ops[end] == Insert("grid", [Any[1, "x", 3], Any[2, "x", 1], Any[1, "y", 2]])
    end
end

@testset "insert_rows! widens integers, floats and text" begin
    with_samples_builder() do w
        rows = [
            (id = Int32(11), label = SubString("xa", 2), mass = 1.5f0),
            (id = Int8(12), label = "b", mass = Float16(2)),
            (id = Int16(13), label = "c", mass = missing),
        ]
        insert_rows!(w, :samples, rows)
        cells = only(w.ops).rows
        @test isequal(cells, [Any[11, "a", 1.5], Any[12, "b", 2.0], Any[13, "c", missing]])
        @test cells[1][1] isa Int64
        @test cells[1][2] isa String
        @test cells[1][3] isa Float64
    end
end

@testset "insert_rows! writes every NaN as the one canonical NaN" begin
    with_samples_builder() do w
        insert_rows!(w, :samples, [(id = 3, label = "c", mass = SIGNBIT_NAN)])
        @test reinterpret(UInt64, only(w.ops).rows[1][3]) == CANONICAL_NAN_BITS
    end
end

@testset "insert_rows! takes any vector of bytes as a bytes cell" begin
    with_empty_builder() do w
        declare_blobs!(w)
        insert_rows!(w, :blobs, [(k = view(UInt8[1, 2, 3], 2:3),), (k = codeunits("ab"),)])
        cells = w.ops[end].rows
        @test cells == [Any[UInt8[2, 3]], Any[UInt8[0x61, 0x62]]]
        @test cells[1][1] isa Vector{UInt8}
        @test cells[2][1] isa Vector{UInt8}
    end
end

@testset "insert_rows! holds its own copy of a bytes cell" begin
    with_empty_builder() do w
        declare_blobs!(w)
        key = UInt8[1, 2]
        insert_rows!(w, :blobs, [(k = key,)])
        key[1] = 0xff
        @test w.ops[end].rows == [Any[UInt8[1, 2]]]
    end
end

@testset "insert_rows! takes any collection of rows" begin
    with_samples_builder() do w
        insert_rows!(w, :samples, ((mass = missing, id = i, label = "g") for i in 10:11))
        @test isequal(w.ops[1].rows, [Any[10, "g", missing], Any[11, "g", missing]])
        insert_rows!(w, :samples, Tables.rows((id = [20], label = ["r"], mass = [1.0])))
        @test w.ops[2].rows == [Any[20, "r", 1.0]]
    end
end

@testset "insert_rows! refuses a cell that is no typed value of its column" begin
    with_samples_builder() do w
        @testset "$(case.name)" for case in REFUSED_CELLS
            @test_throws(
                WriteBuilderError, case.fragment, insert_rows!(w, :samples, [case.row])
            )
        end
        @test isempty(w.ops)
    end
end

@testset "update_rows! adds the op with the key, then the changed columns" begin
    with_samples_builder() do w
        rows = [(mass = missing, label = "z", id = 1)]
        @test @inferred(update_rows!(w, :samples, rows)) === nothing
        @test w.ops == [Update("samples", ["label", "mass"], [Any[1, "z", missing]])]
    end
end

@testset "update_rows! sorts its rows and writes a composite key in its own order" begin
    with_empty_builder() do w
        declare_grid!(w)
        update_rows!(w, :grid, [(v = 9, a = 2, b = "x"), (a = 1, b = "x", v = 8)])
        @test w.ops[end] == Update("grid", ["v"], [Any["x", 1, 8], Any["x", 2, 9]])
    end
end

@testset "delete_rows! adds the op with the keys in typed key order" begin
    with_empty_builder() do w
        declare_grid!(w)
        rows = [(a = 1, b = "y"), (b = "x", a = 1)]
        @test @inferred(delete_rows!(w, :grid, rows)) === nothing
        @test w.ops[end] == Delete("grid", [Any["x", 1], Any["y", 1]])
    end
end

@testset "insert_rows!, update_rows! and delete_rows! refuse a row set" begin
    with_samples_builder() do w
        @testset "$(case.name)" for case in ROW_SET_REFUSALS
            @test_throws WriteBuilderError case.fragment case.call(w)
        end
        @test isempty(w.ops)
    end
end
