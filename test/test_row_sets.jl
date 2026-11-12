using Test
using ChainTables: ChainTables, Chain, Ops, WriteBuilderError, add_column!, column!,
    commit!, create_chain, create_table!, delete_rows!, insert_rows!, primary_key!, sync!,
    table, update_rows!, write_builder
using ChainTables.Testing: InMemoryObjectStore

# A type that is none of the four tags, standing in for DateTime.
struct RowSetTestDateTime
    year::Int
end

# A Tables.jl-style row without Tables.jl: propertynames and getproperty are all the
# builder reads of a row.
struct RowSetTestRow
    fields::Dict{Symbol, Any}
end
Base.propertynames(r::RowSetTestRow) = Tuple(sort!(collect(keys(getfield(r, :fields)))))
Base.getproperty(r::RowSetTestRow, n::Symbol) = getfield(r, :fields)[n]

function declare_samples!(w)
    create_table!(w, :samples) do t
        column!(t, :id, Int64)
        column!(t, :label, String)
        column!(t, :mass, Float64; nullable = true)
        primary_key!(t, :id)
    end
    return nothing
end

# A copy whose head holds an empty `samples`.
function with_samples_copy(f)
    return mktempdir() do dir
        store = InMemoryObjectStore()
        chain = Chain("bkt", "p"; store, cache_dir = joinpath(dir, "cache"))
        create_chain(chain)
        copy = ChainTables.open(chain, joinpath(dir, "copy"))
        sync!(copy)
        w = write_builder(copy)
        declare_samples!(w)
        commit!(w)
        try
            f(copy)
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

@testset "insert_rows! widens integers, floats and text" begin
    with_samples_copy() do copy
        rows = [
            (id = Int32(1), label = SubString("xa", 2), mass = 1.5f0),
            (id = Int8(2), label = "b", mass = 2.5),
            (id = Int16(3), label = "c", mass = Float16(2)),
        ]
        committed(w -> insert_rows!(w, :samples, rows), copy)
        v = table(copy, :samples)
        expected = [
            (id = 1, label = "a", mass = 1.5), (id = 2, label = "b", mass = 2.5),
            (id = 3, label = "c", mass = 2.0),
        ]
        @test collect(v) == expected
        @test eltype(v.columns.id) == Int64
    end
end

@testset "insert_rows! stores every NaN as the one canonical NaN" begin
    with_samples_copy() do copy
        signbit_nan = reinterpret(Float64, 0xfff8000000000000)
        row = (id = 1, label = "n", mass = signbit_nan)
        committed(w -> insert_rows!(w, :samples, [row]), copy)
        @test reinterpret(UInt64, table(copy, :samples)[1].mass) == 0x7ff8000000000000
    end
end

@testset "insert_rows! takes any byte vector as bytes" begin
    with_samples_copy() do copy
        committed(copy) do w
            create_table!(w, :blobs) do t
                column!(t, :k, Vector{UInt8})
                primary_key!(t, :k)
            end
            rows = [(k = view(UInt8[1, 2, 3], 2:3),), (k = codeunits("ab"),)]
            insert_rows!(w, :blobs, rows)
        end
        @test keys(table(copy, :blobs)) == [UInt8[2, 3], UInt8[0x61, 0x62]]
    end
end

@testset "update_rows! writes missing as null" begin
    with_samples_copy() do copy
        committed(w -> insert_rows!(w, :samples, [(id = 1, label = "a", mass = 1.0)]), copy)
        committed(w -> update_rows!(w, :samples, [(id = 1, mass = missing)]), copy)
        @test table(copy, :samples)[1].mass === missing
    end
end

@testset "insert_rows! takes any iterable of rows in any field order" begin
    with_samples_copy() do copy
        committed(copy) do w
            rows = ((mass = missing, id = i, label = "g") for i in 10:11)
            insert_rows!(w, :samples, rows)
            row = RowSetTestRow(Dict(:id => 20, :label => "r", :mass => 1.0))
            insert_rows!(w, :samples, [row])
        end
        @test keys(table(copy, :samples)) == [10, 11, 20]
        @test table(copy, :samples)[20] == (id = 20, label = "r", mass = 1.0)
    end
end

@testset "add_column! widens its fill like a cell" begin
    with_samples_copy() do copy
        committed(w -> insert_rows!(w, :samples, [(id = 1, label = "a", mass = 1.0)]), copy)
        committed(w -> add_column!(w, :samples, :w, Int64; fill = Int32(7)), copy)
        @test table(copy, :samples)[1].w === Int64(7)
    end
end

const REFUSED_VALUES = [
    (
        name = "a Float64 for int64",
        row = (id = 1.0, label = "a", mass = 1.0),
        detail = "column \"id\" is int64, got a value of type Float64",
    ),
    (
        name = "a Bool for int64",
        row = (id = true, label = "a", mass = 1.0),
        detail = "column \"id\" is int64, got a value of type Bool",
    ),
    (
        name = "a UInt64 for int64",
        row = (id = UInt64(1), label = "a", mass = 1.0),
        detail = "column \"id\" is int64, got a value of type UInt64",
    ),
    (
        name = "an Int64 for float64",
        row = (id = 1, label = "a", mass = 1),
        detail = "column \"mass\" is float64, got a value of type Int64",
    ),
    (
        name = "a Symbol for text",
        row = (id = 1, label = :a, mass = 1.0),
        detail = "column \"label\" is text, got a value of type Symbol",
    ),
    (
        name = "another type for text",
        row = (id = 1, label = RowSetTestDateTime(2020), mass = 1.0),
        detail = "column \"label\" is text, got a value of type ",
    ),
    (
        name = "missing for a non-nullable column",
        row = (id = 1, label = missing, mass = 1.0),
        detail = "column \"label\" is text and does not admit null",
    ),
    (
        name = "nothing",
        row = (id = 1, label = "a", mass = nothing),
        detail = "column \"mass\": nothing is not a value; null is spelt missing",
    ),
    (
        name = "text that is not UTF-8",
        row = (id = 1, label = "\xff", mass = 1.0),
        detail = "column \"label\" is not well-formed UTF-8",
    ),
    (
        name = "text holding U+0000",
        row = (id = 1, label = "a\0", mass = 1.0),
        detail = "column \"label\" contains U+0000",
    ),
]

@testset "insert_rows! refuses $(case.name)" for case in REFUSED_VALUES
    with_samples_copy() do copy
        w = write_builder(copy)
        @test_throws WriteBuilderError case.detail insert_rows!(w, :samples, [case.row])
    end
end

const REFUSED_OP_VALUES = [
    (
        name = "update_rows! with a String for float64",
        op = w -> update_rows!(w, :samples, [(id = 1, mass = "x")]),
        detail = "column \"mass\" is float64, got a value of type String",
    ),
    (
        name = "delete_rows! with a Float64 for int64",
        op = w -> delete_rows!(w, :samples, [(id = 1.0,)]),
        detail = "column \"id\" is int64, got a value of type Float64",
    ),
    (
        name = "add_column! with a String fill for float64",
        op = w -> add_column!(w, :samples, :w, Float64; fill = "x"),
        detail = "column \"w\" is float64, got a value of type String",
    ),
    (
        name = "add_column! with a missing fill, not nullable",
        op = w -> add_column!(w, :samples, :w, Int64; fill = missing),
        detail = "column \"w\" is int64 and does not admit null",
    ),
    (
        name = "add_column! with a nothing fill",
        op = w -> add_column!(w, :samples, :w, Int64; fill = nothing),
        detail = "column \"w\": nothing is not a value",
    ),
]

@testset "$(case.name) is refused" for case in REFUSED_OP_VALUES
    with_samples_copy() do copy
        @test_throws WriteBuilderError case.detail case.op(write_builder(copy))
    end
end

# The canonical form of an op is what replay determinism rests on, and only the op
# itself shows it: these tests read the builder's internal `ops`.
@testset "insert_rows! orders float keys by typed order" begin
    with_samples_copy() do copy
        w = write_builder(copy)
        create_table!(w, :points) do t
            column!(t, :label, String; nullable = true)
            column!(t, :x, Float64)
            primary_key!(t, :x)
        end
        rows = [
            (x = NaN, label = "nan"), (x = 0.0, label = "zero"), (x = Inf, label = missing),
            (x = -0.0, label = "negative zero"), (x = 1.5, label = "one and a half"),
            (x = -Inf, label = "-inf"),
        ]
        insert_rows!(w, :points, rows)
        expected = [
            Any["-inf", -Inf], Any["negative zero", -0.0], Any["zero", 0.0],
            Any["one and a half", 1.5], Any[missing, Inf], Any["nan", NaN],
        ]
        @test isequal(w.ops[end], Ops.Insert("points", expected))
    end
end

@testset "row ops order a composite key in key declaration order" begin
    with_samples_copy() do copy
        w = write_builder(copy)
        create_table!(w, :grid) do t
            column!(t, :a, Int64)
            column!(t, :b, String)
            column!(t, :v, Int64; nullable = true)
            primary_key!(t, :b, :a)
        end
        rows = [(a = 2, b = "x", v = 1), (a = 1, b = "y", v = 2), (a = 1, b = "x", v = 3)]
        insert_rows!(w, :grid, rows)
        inserted = [Any[1, "x", 3], Any[2, "x", 1], Any[1, "y", 2]]
        @test isequal(w.ops[end], Ops.Insert("grid", inserted))
        update_rows!(w, :grid, [(v = 9, a = 2, b = "x"), (a = 1, b = "x", v = 8)])
        updated = [Any["x", 1, 8], Any["x", 2, 9]]
        @test isequal(w.ops[end], Ops.Update("grid", ["v"], updated))
        delete_rows!(w, :grid, [(a = 1, b = "y"), (b = "x", a = 1)])
        @test isequal(w.ops[end], Ops.Delete("grid", [Any["x", 1], Any["y", 1]]))
        commit!(w)
        @test keys(table(copy, :grid)) == [("x", 2)]
    end
end

@testset "update_rows! names the changed columns in declaration order" begin
    with_samples_copy() do copy
        w = write_builder(copy)
        create_table!(w, :wide) do t
            column!(t, :k, Int64)
            column!(t, :p, Int64)
            column!(t, :q, Int64)
            primary_key!(t, :k)
        end
        insert_rows!(w, :wide, [(k = 1, p = 0, q = 0)])
        update_rows!(w, :wide, [(q = 1, k = 1, p = 2)])
        @test isequal(w.ops[end], Ops.Update("wide", ["p", "q"], [Any[1, 2, 1]]))
    end
end
