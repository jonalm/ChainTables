# #34 step 4 — ADR-0001, ADR-0019, ADR-0025: every structural check raises WriteBuilderError in the call that is wrong.
using ChainTables: Model, Ops, WriteBuilder, WriteBuilderError, ChainTablesError
using ChainTables.Model: Column, Shape, Table, Content
using ChainTables.Ops: CreateTable, AddColumn, DropColumn, DropTable, Insert, Update, Delete, Client, Record
# A type that is none of the four tags, standing in for DateTime (ADR-0019 names
# it) without loading Dates into the test environment.
struct BuilderTestDateTime
    year::Int
end

# A Tables.jl-style row without Tables.jl: propertynames and getproperty are the
# whole interface the builder reads (Tables.AbstractRow, DataFrameRow, NamedTuple).
struct BuilderTestRow
    fields::Dict{Symbol,Any}
end
Base.propertynames(r::BuilderTestRow) = Tuple(sort!(collect(keys(getfield(r, :fields)))))
Base.getproperty(r::BuilderTestRow, n::Symbol) = getfield(r, :fields)[n]

@testset "builder" begin
    CT = ChainTables
    samples = Shape([Column("id", "int64", false), Column("label", "text", false), Column("mass", "float64", true)], ["id"])
    signbit_nan = reinterpret(Float64, 0xfff8000000000000)
    fresh() = WriteBuilder(Content())
    seeded() = WriteBuilder(Content("samples" => Table(samples, [Any[1, "a", 1.5], Any[2, "b", missing]])))
    declare!(w, name = :samples) = CT.create_table!(w, name) do t
        CT.column!(t, :id, Int64)
        CT.column!(t, :label, String)
        CT.column!(t, :mass, Float64; nullable = true)
        CT.primary_key!(t, :id)
    end
    # the WriteBuilderError a call raises, as its message; anything else is a bug
    refused(f) = try f(); "no error" catch e; e isa WriteBuilderError ? e.msg : rethrow() end
    applied(ops) = (c = Content(); for op in ops; Ops.apply!(c, op); end; c)

    # ------------------------------------------------------------------------
    # The README sequence, at the builder's level: every op function, in the
    # spelling of #34 §1, producing the canonical ops of ADR-0025 that apply
    # exactly as a second client would apply them.
    # ------------------------------------------------------------------------
    @testset "the seven ops" begin
        w = fresh()
        @test w.copy === nothing && w.head === nothing && !w.spent
        @test declare!(w) === nothing
        @test CT.insert_rows!(w, :samples, [(id = 2, label = "b", mass = missing), (id = 1, label = "a", mass = 1.5)]) === nothing
        @test isequal(w.ops, Ops.Op[CreateTable("samples", samples), Insert("samples", [Any[1, "a", 1.5], Any[2, "b", missing]])])
        c = applied(w.ops)
        @test isequal(Model.getrow(c["samples"], (2,)), Any[2, "b", missing])

        w2 = WriteBuilder(c)
        @test CT.update_rows!(w2, :samples, [(id = 2, mass = 2.5)]) === nothing
        @test CT.delete_rows!(w2, :samples, [(id = 1,)]) === nothing
        @test CT.add_column!(w2, :samples, :note, String; nullable = true, fill = missing) === nothing
        @test CT.add_column!(w2, :samples, :weight, Float64; fill = 1.0f0) === nothing
        @test CT.drop_column!(w2, :samples, :label) === nothing
        @test CT.create_table!(w2, :tags) do t
            CT.column!(t, :k, Vector{UInt8})
            CT.primary_key!(t, :k)
        end === nothing
        @test CT.insert_rows!(w2, :tags, [(k = UInt8[1],), (k = UInt8[],)]) === nothing
        @test CT.drop_table!(w2, :tags) === nothing
        @test isequal(w2.ops, Ops.Op[
            Update("samples", ["mass"], [Any[2, 2.5]]),
            Delete("samples", [Any[1]]),
            AddColumn("samples", Column("note", "text", true), missing),
            AddColumn("samples", Column("weight", "float64", false), 1.0),
            DropColumn("samples", "label"),
            CreateTable("tags", Shape([Column("k", "bytes", false)], ["k"])),
            Insert("tags", [Any[UInt8[]], Any[UInt8[1]]]),
            DropTable("tags"),
        ])
        # the content the builder was taken over is untouched: the state gate is commit!'s
        @test Model.nrows(c["samples"]) == 2 && c["samples"].shape == samples && collect(keys(c)) == ["samples"]
        for op in w2.ops
            Ops.apply!(c, op)
        end
        @test c["samples"].shape == Shape([Column("id", "int64", false), Column("mass", "float64", true),
                                           Column("note", "text", true), Column("weight", "float64", false)], ["id"])
        @test isequal(Model.getrow(c["samples"], (2,)), Any[2, 2.5, missing, 1.0])
        @test !haskey(c, "tags")

        # the builder tracks the shape its own ops leave: an insert after add_column
        # names the new column; after drop_table the table is unknown; a table
        # dropped and re-created in one builder is the new one
        w3 = WriteBuilder(c)
        CT.add_column!(w3, :samples, :n, Int64; fill = 0)
        @test_throws "insert_rows!(w, :samples): row set names no column \"n\"; an insert names every column" CT.insert_rows!(w3, :samples, [(id = 3, mass = 1.0, note = "x", weight = 1.0)])
        CT.insert_rows!(w3, :samples, [(id = 3, mass = 1.0, note = "x", weight = 1.0, n = 5)])
        CT.drop_table!(w3, :samples)
        @test_throws "insert_rows!(w, :samples): unknown table \"samples\"" CT.insert_rows!(w3, :samples, [(id = 3, mass = 1.0, note = "x", weight = 1.0, n = 5)])
        CT.create_table!(w3, :samples) do t
            CT.column!(t, :id, Int64)
            CT.primary_key!(t, :id)
        end
        CT.insert_rows!(w3, :samples, [(id = 1,)])
        @test length(w3.ops) == 5
        @test isequal(Model.getrow(applied(vcat(w.ops, w2.ops, w3.ops))["samples"], (1,)), Any[1])

        # the ops travel as a record: what the builder produced, a second client applies
        client = Client(nothing, nothing, "L", "J", 1)
        r = Record(UInt8.(0:15), 0, nothing, Model.state_fingerprint(applied(w.ops)), client, nothing, w.ops)
        back = Ops.decode_record(Ops.encode_record(r); slot = 0)
        @test isequal(back.ops, w.ops)
        @test Model.state_fingerprint(applied(back.ops)) == r.state_fingerprint

        # a builder over a content with tables sees their shapes
        w4 = seeded()
        @test_throws "update_rows!(w, :samples): unknown column \"colour\"" CT.update_rows!(w4, :samples, [(id = 1, colour = "red")])
        CT.update_rows!(w4, :samples, [(id = 1, label = "z", mass = missing)])
        @test isequal(w4.ops, Ops.Op[Update("samples", ["label", "mass"], [Any[1, "z", missing]])])
    end

    # ------------------------------------------------------------------------
    # Typed values (ADR-0019, ADR-0025): Int32/Float32 widen, NaN is canonicalised,
    # text is checked, missing is null and round-trips, anything else is refused
    # in the call naming the column and the type.
    # ------------------------------------------------------------------------
    @testset "typed values" begin
        w = fresh()
        declare!(w)
        CT.insert_rows!(w, :samples, [
            (id = Int32(1), label = SubString("xa", 2), mass = 1.5f0),
            (id = Int8(2), label = "b", mass = signbit_nan),
            (id = Int16(3), label = "c", mass = Float16(2)),
        ])
        rows = w.ops[end].rows
        @test isequal(rows, [Any[1, "a", 1.5], Any[2, "b", NaN], Any[3, "c", 2.0]])
        @test rows[1][1] isa Int64 && rows[1][2] isa String && rows[1][3] isa Float64
        @test reinterpret(UInt64, rows[2][3]) == 0x7ff8000000000000       # f97e00, widened
        # bytes: any AbstractVector{UInt8} becomes a Vector{UInt8}
        CT.create_table!(w, :blobs) do t
            CT.column!(t, :k, Vector{UInt8})
            CT.primary_key!(t, :k)
        end
        CT.insert_rows!(w, :blobs, [(k = view(UInt8[1, 2, 3], 2:3),), (k = codeunits("ab"),)])
        @test isequal(w.ops[end].rows, [Any[UInt8[2, 3]], Any[UInt8[0x61, 0x62]]])   # bytewise order
        @test all(r -> r[1] isa Vector{UInt8}, w.ops[end].rows)
        # missing round-trips: read from a view, handed to update_rows!, unchanged
        CT.update_rows!(w, :samples, [(id = 1, mass = missing)])
        @test isequal(w.ops[end], Update("samples", ["mass"], [Any[1, missing]]))
        # a row set is any iterable of rows with propertynames/getproperty, in any field order
        CT.insert_rows!(w, :samples, ((mass = missing, id = i, label = "g") for i in 10:11))
        @test isequal(w.ops[end].rows, [Any[10, "g", missing], Any[11, "g", missing]])
        CT.insert_rows!(w, :samples, [BuilderTestRow(Dict(:id => 20, :label => "r", :mass => 1.0))])
        @test isequal(w.ops[end].rows, [Any[20, "r", 1.0]])

        # refused values, in the call, naming the column and the type
        @test_throws WriteBuilderError CT.insert_rows!(w, :samples, [(id = 1.0, label = "a", mass = 1.0)])
        @test_throws "insert_rows!(w, :samples): column \"id\" is int64, got a value of type Float64" CT.insert_rows!(w, :samples, [(id = 1.0, label = "a", mass = 1.0)])
        @test_throws "column \"id\" is int64, got a value of type Bool" CT.insert_rows!(w, :samples, [(id = true, label = "a", mass = 1.0)])
        @test_throws "column \"id\" is int64, got a value of type UInt64" CT.insert_rows!(w, :samples, [(id = UInt64(1), label = "a", mass = 1.0)])
        @test_throws "column \"mass\" is float64, got a value of type Int64" CT.insert_rows!(w, :samples, [(id = 1, label = "a", mass = 1)])
        @test_throws "column \"label\" is text, got a value of type Symbol" CT.insert_rows!(w, :samples, [(id = 1, label = :a, mass = 1.0)])
        @test_throws "column \"label\" is text, got a value of type BuilderTestDateTime" CT.insert_rows!(w, :samples, [(id = 1, label = BuilderTestDateTime(2020), mass = 1.0)])
        @test_throws "column \"label\" is text and does not admit null" CT.insert_rows!(w, :samples, [(id = 1, label = missing, mass = 1.0)])
        @test_throws "column \"mass\": nothing is not a value; null is spelt missing" CT.insert_rows!(w, :samples, [(id = 1, label = "a", mass = nothing)])
        @test_throws "column \"label\" is not well-formed UTF-8" CT.insert_rows!(w, :samples, [(id = 1, label = "\xff", mass = 1.0)])
        @test_throws "column \"label\" contains U+0000" CT.insert_rows!(w, :samples, [(id = 1, label = "a\0", mass = 1.0)])
        @test_throws "update_rows!(w, :samples): column \"mass\" is float64, got a value of type String" CT.update_rows!(w, :samples, [(id = 1, mass = "x")])
        @test_throws "delete_rows!(w, :samples): column \"id\" is int64, got a value of type Float64" CT.delete_rows!(w, :samples, [(id = 1.0,)])
        @test_throws "add_column!(w, :samples, :w, Float64): column \"w\" is float64, got a value of type String" CT.add_column!(w, :samples, :w, Float64; fill = "x")
        @test_throws "add_column!(w, :samples, :w, Int64): column \"w\" is int64 and does not admit null" CT.add_column!(w, :samples, :w, Int64; fill = missing)
        @test_throws "add_column!(w, :samples, :w, Int64): column \"w\": nothing is not a value" CT.add_column!(w, :samples, :w, Int64; fill = nothing)
        # a fill widens like a cell
        CT.add_column!(w, :samples, :w, Int64; fill = Int32(7))
        @test w.ops[end].fill === Int64(7)
    end

    # ------------------------------------------------------------------------
    # Canonical form (ADR-0005, ADR-0025): rows in typed key order whatever the
    # caller's order, cells in declaration order whatever the row's field order,
    # update rows [key…, values…] with the key in key declaration order.
    # ------------------------------------------------------------------------
    @testset "canonical ops" begin
        w = fresh()
        CT.create_table!(w, :points) do t
            CT.column!(t, :label, String; nullable = true)
            CT.column!(t, :x, Float64)
            CT.primary_key!(t, :x)
        end
        CT.insert_rows!(w, :points, [(x = NaN, label = "nan"), (x = 0.0, label = "zero"), (x = Inf, label = missing),
                                     (x = -0.0, label = "negative zero"), (x = 1.5, label = "one and a half"), (x = -Inf, label = "-inf")])
        @test isequal(w.ops[end].rows, [Any["-inf", -Inf], Any["negative zero", -0.0], Any["zero", 0.0],
                                        Any["one and a half", 1.5], Any[missing, Inf], Any["nan", NaN]])
        # a composite key: key declaration order is primary_key!'s, not the columns'
        CT.create_table!(w, :grid) do t
            CT.column!(t, :a, Int64)
            CT.column!(t, :b, String)
            CT.column!(t, :v, Int64; nullable = true)
            CT.primary_key!(t, :b, :a)
        end
        @test w.ops[end].shape.key == ["b", "a"]
        CT.insert_rows!(w, :grid, [(a = 2, b = "x", v = 1), (a = 1, b = "y", v = 2), (a = 1, b = "x", v = 3)])
        @test isequal(w.ops[end].rows, [Any[1, "x", 3], Any[2, "x", 1], Any[1, "y", 2]])
        CT.update_rows!(w, :grid, [(v = 9, a = 2, b = "x"), (a = 1, b = "x", v = 8)])
        @test isequal(w.ops[end], Update("grid", ["v"], [Any["x", 1, 8], Any["x", 2, 9]]))
        CT.delete_rows!(w, :grid, [(a = 1, b = "y"), (b = "x", a = 1)])
        @test isequal(w.ops[end], Delete("grid", [Any["x", 1], Any["y", 1]]))
        # update columns come out in declaration order whatever the row's field order
        CT.create_table!(w, :wide) do t
            CT.column!(t, :k, Int64)
            CT.column!(t, :p, Int64)
            CT.column!(t, :q, Int64)
            CT.primary_key!(t, :k)
        end
        CT.insert_rows!(w, :wide, [(k = 1, p = 0, q = 0)])
        CT.update_rows!(w, :wide, [(q = 1, k = 1, p = 2)])
        @test isequal(w.ops[end], Update("wide", ["p", "q"], [Any[1, 2, 1]]))
        # everything the builder produced applies
        @test applied(w.ops) isa Content
    end

    # ------------------------------------------------------------------------
    # Every structural check raises WriteBuilderError in the call that is wrong
    # (ADR-0019), with the call at the front of the message so the fix is named
    # (ADR-0020: fix the call). A refused call leaves the builder as it was.
    # ------------------------------------------------------------------------
    @testset "structural checks" begin
        w = seeded()
        rows(; kw...) = [(; kw...)]
        # unknown table
        @test_throws "insert_rows!(w, :nope): unknown table \"nope\"" CT.insert_rows!(w, :nope, rows(id = 1))
        @test_throws "update_rows!(w, :nope): unknown table \"nope\"" CT.update_rows!(w, :nope, rows(id = 1))
        @test_throws "delete_rows!(w, :nope): unknown table \"nope\"" CT.delete_rows!(w, :nope, rows(id = 1))
        @test_throws "add_column!(w, :nope, :c, Int64): unknown table \"nope\"" CT.add_column!(w, :nope, :c, Int64; fill = 0)
        @test_throws "drop_column!(w, :nope, :c): unknown table \"nope\"" CT.drop_column!(w, :nope, :c)
        @test_throws "drop_table!(w, :nope): unknown table \"nope\"" CT.drop_table!(w, :nope)
        # unknown column
        @test_throws "insert_rows!(w, :samples): unknown column \"colour\"" CT.insert_rows!(w, :samples, rows(id = 3, label = "c", mass = 1.0, colour = "red"))
        @test_throws "update_rows!(w, :samples): unknown column \"colour\"" CT.update_rows!(w, :samples, rows(id = 1, colour = "red"))
        @test_throws "delete_rows!(w, :samples): unknown column \"colour\"" CT.delete_rows!(w, :samples, rows(id = 1, colour = "red"))
        @test_throws "drop_column!(w, :samples, :colour): unknown column \"colour\"" CT.drop_column!(w, :samples, :colour)
        # refused type tags: exactly the four, by identity
        bad_tag(T) = refused(() -> CT.create_table!(w, :t) do t; CT.column!(t, :c, T); CT.primary_key!(t, :c); end)
        @test bad_tag(Bool) == "column!(t, :c, Bool): type tag Bool for column \"c\" is not one of Int64, Float64, String, Vector{UInt8}"
        @test bad_tag(AbstractString) == "column!(t, :c, AbstractString): type tag AbstractString for column \"c\" is not one of Int64, Float64, String, Vector{UInt8}; a text column's tag is String"
        @test bad_tag(Int32) == "column!(t, :c, Int32): type tag Int32 for column \"c\" is not one of Int64, Float64, String, Vector{UInt8}; Int32 values widen at insert, the tag is Int64"
        @test bad_tag(Float32) == "column!(t, :c, Float32): type tag Float32 for column \"c\" is not one of Int64, Float64, String, Vector{UInt8}; Float32 values widen at insert, the tag is Float64"
        @test startswith(bad_tag(BuilderTestDateTime), "column!(t, :c, BuilderTestDateTime): type tag BuilderTestDateTime for column \"c\" is not one of")
        for T in (Any, Union{Missing,Int64}, Missing, Nothing, Vector{Int64}, SubString{String}, UInt8, Int128, Integer, Real, Symbol, Char)
            @test occursin("type tag $T for column \"c\" is not one of", bad_tag(T))
        end
        @test bad_tag("int64") == "column!(t, :c, \"int64\"): type tag \"int64\" for column \"c\" is not one of Int64, Float64, String, Vector{UInt8}"
        Int === Int64 || @test occursin("type tag Int32 for column", bad_tag(Int))   # Int is Int64 on 64-bit and is accepted as that
        @test_throws "add_column!(w, :samples, :c, Bool): type tag Bool for column \"c\" is not one of" CT.add_column!(w, :samples, :c, Bool; fill = true)
        # non-uniform columns within an op
        @test_throws "insert_rows!(w, :samples): row 2 names columns (:id, :label) but row 1 names (:id, :label, :mass); the columns of an op are uniform" CT.insert_rows!(w, :samples, [(id = 3, label = "c", mass = 1.0), (id = 4, label = "d")])
        @test_throws "update_rows!(w, :samples): row 2 names columns (:id, :label) but row 1 names (:id, :mass); the columns of an op are uniform" CT.update_rows!(w, :samples, [(id = 1, mass = 1.0), (id = 2, label = "d")])
        @test_throws "delete_rows!(w, :samples): row 3 names columns (:id, :label) but row 1 names (:id,); the columns of an op are uniform" CT.delete_rows!(w, :samples, [(id = 1,), (id = 2,), (id = 3, label = "x")])
        # duplicate key inside one op
        @test_throws "insert_rows!(w, :samples): duplicate key (3,) inside one op" CT.insert_rows!(w, :samples, [(id = 3, label = "c", mass = 1.0), (id = 3, label = "d", mass = 1.0)])
        @test_throws "update_rows!(w, :samples): duplicate key (1,) inside one op" CT.update_rows!(w, :samples, [(id = 1, mass = 1.0), (id = 1, mass = 2.0)])
        @test_throws "delete_rows!(w, :samples): duplicate key (1,) inside one op" CT.delete_rows!(w, :samples, [(id = 1,), (id = 1,)])
        # bad identifier
        @test_throws "create_table!(w, :Samples): table name \"Samples\" is not an identifier ([a-z_][a-z0-9_]*)" declare!(w, :Samples)
        @test_throws "create_table!(w, \"1x\"): table name \"1x\" is not an identifier" declare!(w, "1x")
        @test_throws "column!(t, :Id, Int64): column name \"Id\" is not an identifier ([a-z_][a-z0-9_]*)" CT.create_table!(t -> CT.column!(t, :Id, Int64), w, :t)
        @test_throws "column!(t, :é, Int64): column name \"é\" is not an identifier" CT.create_table!(t -> CT.column!(t, :é, Int64), w, :t)
        @test_throws "add_column!(w, :samples, :Colour, String): column name \"Colour\" is not an identifier" CT.add_column!(w, :samples, :Colour, String; fill = "")
        # missing primary key; nullable key column; the other key rules
        @test_throws "create_table!(w, :t): table has no primary key; every table needs an explicit key" CT.create_table!(t -> CT.column!(t, :c, Int64), w, :t)
        @test_throws "create_table!(w, :t): table has no columns" CT.create_table!(t -> nothing, w, :t)
        @test_throws "primary_key!(t, :mass): key column \"mass\" is nullable; key columns are non-nullable" CT.create_table!(w, :t) do t
            CT.column!(t, :mass, Float64; nullable = true)
            CT.primary_key!(t, :mass)
        end
        @test_throws "primary_key!(t, :zz): key column \"zz\" is not a column of the table" CT.create_table!(w, :t) do t
            CT.column!(t, :c, Int64)
            CT.primary_key!(t, :zz)
        end
        @test_throws "primary_key!(t, :c, :c): duplicate key column \"c\"" CT.create_table!(w, :t) do t
            CT.column!(t, :c, Int64)
            CT.primary_key!(t, :c, :c)
        end
        @test_throws "primary_key!(t, :c): primary_key! was already called; a table has one primary key" CT.create_table!(w, :t) do t
            CT.column!(t, :c, Int64)
            CT.primary_key!(t, :c)
            CT.primary_key!(t, :c)
        end
        @test_throws "column!(t, :c, String): duplicate column name \"c\"" CT.create_table!(w, :t) do t
            CT.column!(t, :c, Int64)
            CT.column!(t, :c, String)
        end
        @test_throws "create_table!(w, :samples): table \"samples\" already exists" declare!(w)
        # missing column on insert; the shapes of update and delete rows
        @test_throws "insert_rows!(w, :samples): row set names no column \"mass\"; an insert names every column" CT.insert_rows!(w, :samples, rows(id = 3, label = "c"))
        @test_throws "update_rows!(w, :samples): row set names no key column \"id\"; an update names the full key" CT.update_rows!(w, :samples, rows(mass = 1.0))
        @test_throws "update_rows!(w, :samples): update names no non-key column" CT.update_rows!(w, :samples, rows(id = 1))
        @test_throws "delete_rows!(w, :samples): row set names column \"label\"; a delete names the key columns only" CT.delete_rows!(w, :samples, rows(id = 1, label = "a"))
        @test_throws "delete_rows!(w, :samples): row set names no key column \"id\"; a delete names the full key" CT.delete_rows!(w, :samples, [NamedTuple()])
        # the column ops
        @test_throws "add_column!(w, :samples, :label, String): column \"label\" already exists" CT.add_column!(w, :samples, :label, String; fill = "")
        @test_throws "drop_column!(w, :samples, :id): column \"id\" is a key column and cannot be dropped" CT.drop_column!(w, :samples, :id)
        # a row set is a collection of rows, none of them empty
        @test_throws "insert_rows!(w, :samples): a row set is a collection of rows, got one NamedTuple; wrap the row in a vector" CT.insert_rows!(w, :samples, (id = 3, label = "c", mass = 1.0))
        @test_throws "insert_rows!(w, :samples): the row set is empty; an op carries at least one row" CT.insert_rows!(w, :samples, NamedTuple[])
        @test_throws "delete_rows!(w, :samples): the row set is empty; an op carries at least one row" CT.delete_rows!(w, :samples, ())
        @test_throws "insert_rows!(w, :samples): row 1 is not a row (a NamedTuple or a Tables.jl row), got a value of type Vector{Any}" CT.insert_rows!(w, :samples, [Any[3, "c", 1.0]])
        @test_throws "delete_rows!(w, :samples): row 2 is not a row (a NamedTuple or a Tables.jl row), got a value of type Int64" CT.delete_rows!(w, :samples, [(id = 1,), 2])
        # names are Symbols
        @test_throws "insert_rows!(w, 1): table name 1 is not a Symbol" CT.insert_rows!(w, 1, rows(id = 1))
        @test_throws "column!(t, 1, Int64): column name 1 is not a Symbol" CT.create_table!(t -> CT.column!(t, 1, Int64), w, :t)
        # every refusal is a WriteBuilderError under ChainTablesError, never the model's error
        @test_throws WriteBuilderError CT.drop_table!(w, :nope)
        @test WriteBuilderError <: ChainTablesError
        # and every refused call left the builder as it was: no op, no shape change
        @test isempty(w.ops)
        CT.insert_rows!(w, :samples, rows(id = 3, label = "c", mass = 1.0))
        @test length(w.ops) == 1
        # column!/primary_key! outside a create_table! block are refused by dispatch, not silently accepted
        @test_throws MethodError CT.column!(w, :c, Int64)
    end

    # ------------------------------------------------------------------------
    # A builder is a value used once (ADR-0019, ADR-0002): commit! spends it,
    # and a spent builder refuses every call.
    # ------------------------------------------------------------------------
    @testset "single use" begin
        w = seeded()
        @test CT.spend!(w) === nothing
        @test w.spent
        @test_throws "commit!(w): this builder is spent; a builder is used once, take a new one with write_builder(copy)" CT.spend!(w)
        @test_throws "insert_rows!(w, :samples): this builder is spent; commit! consumed it, take a new one with write_builder(copy)" CT.insert_rows!(w, :samples, [(id = 3, label = "c", mass = 1.0)])
        @test_throws "create_table!(w, :t): this builder is spent" declare!(w, :t)
        @test_throws "drop_table!(w, :samples): this builder is spent" CT.drop_table!(w, :samples)
        # the binding step 7 attaches rides along, typed
        w2 = WriteBuilder(Content(); copy = :the_copy, head = (; slot = 3))
        @test w2.copy === :the_copy && w2.head.slot == 3
        @test w2 isa WriteBuilder{Symbol,<:NamedTuple}
        # write_builder's one method is over a LocalCopy (chain.jl); a builder over bare content is the tests' own
        @test length(methods(CT.write_builder)) == 1
        @test_throws "commit!(w): this builder was not taken over a local copy" CT.commit!(WriteBuilder(Content()))
    end
end
