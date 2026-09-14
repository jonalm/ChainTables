# #34 step 2 — ADR-0022, ADR-0025, ADR-0007: typed key order, table_hash, fingerprint, the determinism vector.
using ChainTables: CBOR, Model
using ChainTables.Model: Column, Shape, Table, Content, ModelError
using SHA: sha256

@testset "model" begin
    sep_table = codeunits("chaintables/v1/fp-table")
    sep_fp = codeunits("chaintables/v1/fp")
    stream(t) = (io = IOBuffer(); Model.write_table(io, t); take!(io))
    hex(v) = bytes2hex(v)
    signbit_nan = reinterpret(Float64, 0xfff8000000000000)

    # ------------------------------------------------------------------------
    # Shape (ADR-0003, ADR-0025): columns in declaration order, an explicit
    # non-nullable key, wire form {"columns": [[name, type, nullable], …], "key": [name, …]}.
    # ------------------------------------------------------------------------
    @testset "shape" begin
        s = Shape([Column("id", "int64", false), Column("mass", "float64", true)], ["id"])
        @test s.key == ["id"]
        @test Model.column_index(s, "mass") == 2
        @test_throws "unknown column \"nope\"" Model.column_index(s, "nope")

        # the wire form, hand-encoded: "key" sorts before "columns" (bytewise on the
        # encoded key, so the shorter head byte 0x63 < 0x67 wins)
        @test hex(CBOR.encode(Model.wire(s))) == replace(
            "a2 63 6b6579 81 62 6964 67 636f6c756d6e73 82 83 62 6964 65 696e743634 f4 83 64 6d617373 67 666c6f61743634 f5",
            " " => "")
        # and back, strictly
        @test Shape(CBOR.decode(CBOR.encode(Model.wire(s)))) == s
        @test_throws "unknown shape field \"extra\"" Shape(Dict{String,Any}("columns" => Any[Any["id", "int64", false]], "key" => Any["id"], "extra" => 1))
        @test_throws "shape has no \"key\"" Shape(Dict{String,Any}("columns" => Any[Any["id", "int64", false]]))
        @test_throws "column entry" Shape(Dict{String,Any}("columns" => Any[Any["id", "int64"]], "key" => Any["id"]))
        @test_throws "column entry" Shape(Dict{String,Any}("columns" => Any[Any["id", "int64", 0]], "key" => Any["id"]))

        # structural rules, each in the constructor
        @test_throws "table has no columns" Shape(Column[], String[])
        @test_throws "column name \"Id\" is not an identifier" Shape([Column("Id", "int64", false)], ["Id"])
        @test_throws "column name \"1a\" is not an identifier" Shape([Column("1a", "int64", false)], ["1a"])
        @test_throws "column name \"\" is not an identifier" Shape([Column("", "int64", false)], [""])
        @test_throws "duplicate column name \"id\"" Shape([Column("id", "int64", false), Column("id", "text", false)], ["id"])
        @test_throws "unknown value type \"Int\"" Shape([Column("id", "Int", false)], ["id"])
        @test_throws "unknown value type \"Int64\"" Shape([Column("id", "Int64", false)], ["id"])
        @test_throws "table has no primary key" Shape([Column("id", "int64", false)], String[])
        @test_throws "key column \"x\" is not a column of the table" Shape([Column("id", "int64", false)], ["x"])
        @test_throws "key column \"id\" is nullable" Shape([Column("id", "int64", true)], ["id"])
        @test_throws "duplicate key column \"id\"" Shape([Column("id", "int64", false)], ["id", "id"])
        @test Model.is_identifier("a_b9") && Model.is_identifier("_")
        @test !Model.is_identifier("a-b") && !Model.is_identifier("é") && !Model.is_identifier("A")
    end

    # ------------------------------------------------------------------------
    # Typed values (ADR-0025): exactly the four carriers, null only where allowed,
    # never converted.
    # ------------------------------------------------------------------------
    @testset "typed values" begin
        s = Shape([Column("id", "int64", false), Column("x", "float64", true),
                   Column("s", "text", false), Column("b", "bytes", false)], ["id"])
        @test Model.check_row(s, Any[1, missing, "a", UInt8[]]) === nothing
        @test Model.check_row(s, Any[1, NaN, "a", UInt8[1]]) === nothing
        @test_throws "row has 3 cells; the shape has 4 columns" Model.check_row(s, Any[1, 2.0, "a"])
        @test_throws "column \"id\" is int64 and does not admit null" Model.check_row(s, Any[missing, 1.0, "a", UInt8[]])
        @test_throws "column \"id\" is int64, got a value of type Float64" Model.check_row(s, Any[1.0, 1.0, "a", UInt8[]])
        @test_throws "column \"id\" is int64, got a value of type Int32" Model.check_row(s, Any[Int32(1), 1.0, "a", UInt8[]])
        @test_throws "column \"id\" is int64, got a value of type Bool" Model.check_row(s, Any[true, 1.0, "a", UInt8[]])
        @test_throws "column \"x\" is float64, got a value of type Int64" Model.check_row(s, Any[1, 1, "a", UInt8[]])
        @test_throws "column \"s\" is text, got a value of type SubString{String}" Model.check_row(s, Any[1, 1.0, SubString("ab", 1, 1), UInt8[]])
        @test_throws "column \"b\" is bytes, got a value of type String" Model.check_row(s, Any[1, 1.0, "a", "b"])
        @test Model.value_type(1) == "int64" && Model.value_type(1.0) == "float64" &&
              Model.value_type("s") == "text" && Model.value_type(UInt8[]) == "bytes"
        @test Model.value_type(true) === nothing && Model.value_type(missing) === nothing
    end

    # ------------------------------------------------------------------------
    # Table (ADR-0022 "the model"): a shape plus a map from key to row; the
    # primitives the seven ops reduce to; the state gate.
    # ------------------------------------------------------------------------
    @testset "table primitives and the state gate" begin
        s = Shape([Column("id", "int64", false), Column("v", "text", true)], ["id"])
        t = Table(s)
        @test Model.nrows(t) == 0
        # the primitives take the canonical payload and never sort (#48): rows in
        # typed key order, update columns in declaration order
        @test_throws "rows are not in primary-key order: (1,) after (2,)" Model.insert_rows!(t, [Any[2, "b"], Any[1, missing]])
        @test Model.nrows(t) == 0
        Model.insert_rows!(t, [Any[1, missing], Any[2, "b"]])
        @test Model.nrows(t) == 2
        @test Model.haskey(t, (1,)) && !Model.haskey(t, (3,))
        @test isequal(Model.getrow(t, (2,)), Any[2, "b"])
        @test_throws "insert names a key that is present: (1,)" Model.insert_rows!(t, [Any[1, "x"]])
        @test_throws "duplicate key (5,) inside one op" Model.insert_rows!(t, [Any[5, "x"], Any[5, "y"]])
        @test Model.nrows(t) == 2          # a refused op changes nothing
        Model.update_rows!(t, ["v"], [Any[1, "one"]])
        @test isequal(Model.getrow(t, (1,)), Any[1, "one"])
        @test_throws "update names a key that is absent: (9,)" Model.update_rows!(t, ["v"], [Any[9, "x"]])
        @test_throws "update names key column \"id\"" Model.update_rows!(t, ["id"], [Any[1, 7]])
        @test_throws "update names no non-key column" Model.update_rows!(t, String[], [Any[1]])
        @test_throws "column \"v\" is text, got a value of type Int64" Model.update_rows!(t, ["v"], [Any[1, 7]])
        @test_throws "rows are not in primary-key order: (1,) after (2,)" Model.update_rows!(t, ["v"], [Any[2, "x"], Any[1, "y"]])
        @test_throws "duplicate key (1,) inside one op" Model.update_rows!(t, ["v"], [Any[1, "x"], Any[1, "y"]])
        @test_throws "rows are not in primary-key order: (1,) after (2,)" Model.delete_rows!(t, [(2,), (1,)])
        Model.delete_rows!(t, [(2,)])
        @test Model.nrows(t) == 1 && !Model.haskey(t, (2,))
        @test_throws "delete names a key that is absent: (2,)" Model.delete_rows!(t, [(2,)])
        @test_throws "duplicate key (1,) inside one op" Model.delete_rows!(t, [(1,), (1,)])

        # columns: add with a fill, drop a non-key column, refuse the rest
        Model.add_column!(t, Column("w", "float64", false), 2.0)
        @test isequal(Model.getrow(t, (1,)), Any[1, "one", 2.0])
        @test_throws "column \"w\" already exists" Model.add_column!(t, Column("w", "float64", false), 2.0)
        @test_throws "column \"n\" is int64 and does not admit null" Model.add_column!(t, Column("n", "int64", false), missing)
        Model.add_column!(t, Column("n", "int64", true), missing)
        @test isequal(Model.getrow(t, (1,)), Any[1, "one", 2.0, missing])
        # update columns in declaration order is a Model rule, with the contract message (#48)
        @test_throws "update columns are not in declaration order: [\"n\", \"w\"]" Model.update_rows!(t, ["n", "w"], [Any[1, 3, 3.0]])
        @test_throws "duplicate column \"w\" in one update" Model.update_rows!(t, ["w", "w"], [Any[1, 3.0, 3.0]])
        @test Model.check_update(t.shape, ["w", "n"], [Any[1, 3.0, 3]]) == [3, 4]
        @test isequal(Model.getrow(t, (1,)), Any[1, "one", 2.0, missing])      # refused ops changed nothing
        @test_throws "column \"id\" is a key column and cannot be dropped" Model.drop_column!(t, "id")
        @test_throws "unknown column \"zz\"" Model.drop_column!(t, "zz")
        Model.drop_column!(t, "v")
        @test isequal(Model.getrow(t, (1,)), Any[1, 2.0, missing])
        @test t.shape == Shape([Column("id", "int64", false), Column("w", "float64", false), Column("n", "int64", true)], ["id"])
        # a shape reached by ops equals the shape declared outright, so the
        # table file is byte-identical either way (ADR-0025 "one encoding")
        @test Model.table_hash(t) == Model.table_hash(Table(t.shape, [Any[1, 2.0, missing]]))

        # the constructor validates like insert does
        @test_throws "duplicate key (1,) inside one op" Table(s, [Any[1, "a"], Any[1, "b"]])
        @test_throws "column \"id\" is int64 and does not admit null" Table(s, [Any[missing, "a"]])

        # content: tables by name
        c = Content()
        Model.create_table!(c, "t", s)
        @test collect(keys(c)) == ["t"]
        @test_throws "table \"t\" already exists" Model.create_table!(c, "t", s)
        @test_throws "table name \"T\" is not an identifier" Model.create_table!(c, "T", s)
        @test_throws "unknown table \"u\"" Model.drop_table!(c, "u")
        @test_throws "unknown table \"u\"" Model.table(c, "u")
        @test Model.table(c, "t") isa Table
        Model.drop_table!(c, "t")
        @test isempty(c)
    end

    # ------------------------------------------------------------------------
    # Typed key order (ADR-0025): isless/isequal on the key tuple.
    # ------------------------------------------------------------------------
    @testset "NaN as a key matches itself and sorts after +Inf; -0.0 and 0.0 are two keys" begin
        s = Shape([Column("x", "float64", false), Column("l", "text", false)], ["x"])
        t = Table(s, [Any[-Inf, "neginf"], Any[-0.0, "negzero"], Any[0.0, "zero"], Any[1.0, "one"],
                      Any[Inf, "inf"], Any[NaN, "nan"]])
        @test_throws "rows are not in primary-key order: (Inf,) after (NaN,)" Table(s, [Any[NaN, "nan"], Any[Inf, "inf"]])
        @test_throws "rows are not in primary-key order: (-0.0,) after (0.0,)" Table(s, [Any[0.0, "zero"], Any[-0.0, "negzero"]])
        @test_throws "duplicate key (NaN,) inside one op" Table(s, [Any[NaN, "nan"], Any[signbit_nan, "nan again"]])
        @test Model.nrows(t) == 6
        @test Model.haskey(t, (NaN,)) && Model.haskey(t, (signbit_nan,))
        @test Model.getrow(t, (NaN,))[2] == "nan"
        @test Model.getrow(t, (-0.0,))[2] == "negzero" && Model.getrow(t, (0.0,))[2] == "zero"
        @test_throws "insert names a key that is present: (NaN,)" Model.insert_rows!(t, [Any[signbit_nan, "again"]])
        @test [r[2] for r in Model.rows_in_key_order(t)] == ["neginf", "negzero", "zero", "one", "inf", "nan"]
        Model.update_rows!(t, ["l"], [Any[NaN, "still nan"]])
        Model.delete_rows!(t, [(-0.0,)])
        @test !Model.haskey(t, (-0.0,)) && Model.haskey(t, (0.0,))
        @test [r[2] for r in Model.rows_in_key_order(t)] == ["neginf", "zero", "one", "inf", "still nan"]

        # composite keys: lexicographic in key declaration order, text by UTF-8 bytes,
        # bytes by bytes — and the key order is the declared key order, not column order
        s2 = Shape([Column("b", "bytes", false), Column("n", "int64", false), Column("s", "text", false)], ["s", "n"])
        t2 = Table(s2, [Any[UInt8[], 0, "a"], Any[UInt8[], -1, "z"], Any[UInt8[], 2, "z"], Any[UInt8[], 1, "é"]])
        @test [(r[3], r[2]) for r in Model.rows_in_key_order(t2)] == [("a", 0), ("z", -1), ("z", 2), ("é", 1)]
        @test_throws "rows are not in primary-key order: (\"z\", -1) after (\"z\", 2)" Table(s2, [Any[UInt8[], 2, "z"], Any[UInt8[], -1, "z"]])
        @test_throws "rows are not in primary-key order: (\"a\", 0) after (\"é\", 1)" Table(s2, [Any[UInt8[], 1, "é"], Any[UInt8[], 0, "a"]])
        @test Model.key_of(s2, Any[UInt8[], 1, "é"]) == ("é", 1)
        s3 = Shape([Column("k", "bytes", false)], ["k"])
        t3 = Table(s3, [Any[UInt8[]], Any[UInt8[1]], Any[UInt8[1, 2]], Any[UInt8[2]]])
        @test [r[1] for r in Model.rows_in_key_order(t3)] == [UInt8[], UInt8[1], UInt8[1, 2], UInt8[2]]
        @test_throws "rows are not in primary-key order: (UInt8[0x01],) after (UInt8[0x01, 0x02],)" Table(s3, [Any[UInt8[1, 2]], Any[UInt8[1]]])
        # the one key-order rule, over key tuples; the duplicate message names its context
        @test Model.check_key_order([(UInt8[1],), (UInt8[2],)]) === nothing
        @test Model.check_key_order(()) === nothing && Model.check_key_order([(1,)]) === nothing
        @test_throws "rows are not in primary-key order: (UInt8[0x01],) after (UInt8[0x02],)" Model.check_key_order([(UInt8[2],), (UInt8[1],)])
        @test_throws "duplicate key (UInt8[0x01],) inside one op" Model.check_key_order([(UInt8[1],), (UInt8[1],)])
        @test_throws "duplicate key (1,) in a table file" Model.check_key_order([(1,), (1,)]; context = "in a table file")
    end

    # ------------------------------------------------------------------------
    # table_hash and the byte stream (ADR-0007, ADR-0023): "…/fp-table" ‖ cbor([shape, rows]).
    # ------------------------------------------------------------------------
    @testset "table_hash and the table file stream" begin
        keyonly = Shape([Column("id", "int64", false)], ["id"])
        # a zero-row table's stream, by hand: separator, array(2), the shape map, array(0)
        shape_hex = "a2 63 6b6579 81 62 6964 67 636f6c756d6e73 81 83 62 6964 65 696e743634 f4"
        empty_hex = hex(sep_table) * replace("82 $shape_hex 80", " " => "")
        t0 = Table(keyonly)
        @test hex(stream(t0)) == empty_hex
        @test Model.table_hash(t0) == sha256(hex2bytes(empty_hex))
        # a key-only table's stream: rows are one-cell arrays in key order, whatever
        # order they arrived in (two inserts, 2 then 1)
        t1 = Table(keyonly)
        Model.insert_rows!(t1, [Any[2]])
        Model.insert_rows!(t1, [Any[1]])
        @test hex(stream(t1)) == hex(sep_table) * replace("82 $shape_hex 82 81 01 81 02", " " => "")
        @test Model.table_hash(t1) == sha256(stream(t1))
        # two identical tables have one table_hash; a different shape, another
        @test Model.table_hash(Table(keyonly, [Any[1], Any[2]])) == Model.table_hash(t1)
        @test Model.table_hash(Table(Shape([Column("id", "int64", true == false)], ["id"]))) == Model.table_hash(t0)
        @test Model.table_hash(Table(Shape([Column("k", "int64", false)], ["k"]))) != Model.table_hash(t0)
        # write_table returns the hash and writes the same bytes to any IO
        io = IOBuffer()
        @test Model.write_table(io, t1) == Model.table_hash(t1)
        @test take!(io) == stream(t1)
        @test length(Model.table_hash(t1)) == 32

        # an empty table contributes its shape and no rows, and null, NaN, -0.0
        # reach the encoder untransformed
        s = Shape([Column("id", "int64", false), Column("x", "float64", true), Column("b", "bytes", false)], ["id"])
        t = Table(s, [Any[1, -0.0, UInt8[]], Any[2, missing, UInt8[0xff]], Any[3, signbit_nan, UInt8[]]])
        rows_hex = replace("83 83 01 f98000 40 83 02 f6 41ff 83 03 f97e00 40", " " => "")
        @test endswith(hex(stream(t)), rows_hex)

        # read_table inverts write_table, strictly
        t_back = Model.read_table(IOBuffer(stream(t)))
        @test t_back.shape == s
        @test isequal(collect(Model.rows_in_key_order(t_back)), collect(Model.rows_in_key_order(t)))
        @test Model.getrow(t_back, (1,))[2] === -0.0
        @test Model.table_hash(t_back) == Model.table_hash(t)
        @test Model.read_table(IOBuffer(stream(t0))).shape == keyonly
        @test_throws "not a table file" Model.read_table(IOBuffer(vcat(b"chaintables/v1/fp-tabl", hex2bytes("82a0"))))
        @test_throws "not a table file" Model.read_table(IOBuffer(UInt8[]))
        @test_throws "shape is not a map, got a value of type Int64" Model.read_table(IOBuffer(vcat(sep_table, hex2bytes("820180"))))
        @test_throws "expected [shape, rows], got an array of 3" Model.read_table(IOBuffer(vcat(sep_table, hex2bytes("83"))))
        # rows out of order or duplicated are refused, not sorted: the same rule an
        # op is held to, worded for a table file (#48)
        body(rows) = vcat(sep_table, hex2bytes(replace("82 $shape_hex", " " => "")), CBOR.encode(rows))
        @test_throws "rows are not in primary-key order: (1,) after (2,)" Model.read_table(IOBuffer(body(Any[Any[2], Any[1]])))
        @test_throws "duplicate key (1,) in a table file" Model.read_table(IOBuffer(body(Any[Any[1], Any[1]])))
        @test_throws "column \"id\" is int64, got a value of type Float64" Model.read_table(IOBuffer(body(Any[Any[1.5]])))
        @test_throws "row has 2 cells; the shape has 1 columns" Model.read_table(IOBuffer(body(Any[Any[1, 2]])))
        @test_throws CBOR.DecodeError Model.read_table(IOBuffer(vcat(sep_table, hex2bytes("82a2"))))
    end

    # ------------------------------------------------------------------------
    # state_fingerprint (ADR-0007): "…/fp" ‖ cbor([[name, table_hash], …]) sorted by name.
    # ------------------------------------------------------------------------
    @testset "state_fingerprint" begin
        # a zero-table chain: the separator and an empty array
        @test Model.state_fingerprint(Pair{String,Vector{UInt8}}[]) == sha256(vcat(sep_fp, hex2bytes("80")))
        @test Model.state_fingerprint(Content()) == Model.state_fingerprint(Pair{String,Vector{UInt8}}[])
        ha = sha256(b"a"); hb = sha256(b"b")
        expected = sha256(vcat(sep_fp, CBOR.encode(Any[Any["a", ha], Any["b", hb]])))
        @test Model.state_fingerprint(["b" => hb, "a" => ha]) == expected      # sorted by name
        @test Model.state_fingerprint(["a" => ha, "b" => hb]) == expected
        @test Model.state_fingerprint(["a" => ha]) != expected
        @test_throws "duplicate table name \"a\"" Model.state_fingerprint(["a" => ha, "a" => hb])
        @test_throws "table_hash of \"a\" is 1 bytes" Model.state_fingerprint(["a" => UInt8[0]])
        # over a content: every table's hash, by name
        c = Content()
        Model.create_table!(c, "b", Shape([Column("k", "int64", false)], ["k"]))
        Model.create_table!(c, "a", Shape([Column("k", "text", false)], ["k"]))
        @test Model.state_fingerprint(c) ==
              Model.state_fingerprint(["a" => Model.table_hash(c["a"]), "b" => Model.table_hash(c["b"])])
        @test length(Model.state_fingerprint(c)) == 32
    end

    # ------------------------------------------------------------------------
    # The determinism vector (ADR-0022, #34 §4). One fixed op sequence, one literal
    # state_fingerprint, asserted identical on every CI cell. The literals were
    # minted from the first green run and are FROZEN: changing one is a chain break
    # and needs an ADR. The same sequence as one genesis record, with the frozen
    # transaction_hash literal, is in test/ops.jl. Covers -0.0, 2^63-1, typemin, a non-ASCII text key, a
    # sign-bit-set NaN, ±Inf, null, an empty table, a key-only table, a dropped
    # table, add/drop column, update and delete. Since #48 the primitives take
    # the canonical payload, so the rows below are written in typed key order;
    # the literals did not move.
    # ------------------------------------------------------------------------
    @testset "determinism vector" begin
        c = Content()
        Model.create_table!(c, "measurements", Shape([
            Column("sample", "text", false), Column("run", "int64", false),
            Column("value", "float64", true), Column("payload", "bytes", false)], ["sample", "run"]))
        Model.insert_rows!(c["measurements"], [           # text keys by UTF-8 bytes: a < z < ß < água < 水
            Any["a", typemin(Int64), -Inf, UInt8[0]],
            Any["z", -1, 0.1 + 0.2, UInt8[]],
            Any["z", 0, missing, UInt8[]],
            Any["ß", typemax(Int64), Inf, UInt8[1, 2, 3]],
            Any["água", 2, signbit_nan, UInt8[0x00, 0xff]],
            Any["水", 1, -0.0, UInt8[]],
        ])
        Model.create_table!(c, "points", Shape([Column("x", "float64", false), Column("label", "text", true)], ["x"]))
        Model.insert_rows!(c["points"], [
            Any[-Inf, "-inf"], Any[-0.0, "negative zero"], Any[0.0, "zero"], Any[5.0e-324, "denormal"], Any[1.5, "one and a half"],
            Any[2.0, missing], Any[1.0e300, "big"], Any[Inf, "inf"], Any[NaN, "nan"]])
        Model.add_column!(c["points"], Column("weight", "float64", false), 2.0)
        Model.add_column!(c["points"], Column("tag", "text", true), missing)
        Model.update_rows!(c["points"], ["label", "weight"], [Any[-0.0, missing, -1.0], Any[NaN, "not a number", 0.5]])
        Model.delete_rows!(c["points"], [(1.5,), (Inf,)])
        Model.drop_column!(c["points"], "tag")
        Model.create_table!(c, "empty", Shape([Column("k", "int64", false), Column("v", "text", true)], ["k"]))
        Model.create_table!(c, "set", Shape([Column("k", "bytes", false)], ["k"]))
        Model.insert_rows!(c["set"], [Any[UInt8[]], Any[UInt8[1]], Any[UInt8[1, 2]], Any[UInt8[2]]])
        Model.create_table!(c, "gone", Shape([Column("k", "int64", false)], ["k"]))
        Model.insert_rows!(c["gone"], [Any[1]])
        Model.drop_table!(c, "gone")

        @test sort(collect(keys(c))) == ["empty", "measurements", "points", "set"]
        # per-table literals first, so a mismatch names the table
        @test hex(Model.table_hash(c["empty"])) == "f78d134fe73b9403444695cf955c149e2e961f4ae02b7496162f557782d9b8d1"
        @test hex(Model.table_hash(c["measurements"])) == "78e28020a6c2a62b27f55785bca1d78836884eafe1e749bbee41188b89f61c5a"
        @test hex(Model.table_hash(c["points"])) == "6417d364f14eb51aabf03ccbef8b691b412e0a8a9385eaf3137a1ad8bd7e8eb9"
        @test hex(Model.table_hash(c["set"])) == "e79d917c8e8bf32fca6305d811146f2ba775155de7ffb907d20957abc1c049a3"
        @test hex(Model.state_fingerprint(c)) == "62bffad1f527b79663c487fe1e192be4617ccf4f29e466c7d8fbcfa92c505582"
        # and the same content reached from its table files
        c2 = Content(name => Model.read_table(IOBuffer(stream(t))) for (name, t) in c)
        @test Model.state_fingerprint(c2) == Model.state_fingerprint(c)
    end
end
