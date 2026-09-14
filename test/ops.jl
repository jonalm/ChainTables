# #34 step 3 — ADR-0025, ADR-0006: ops and their wire forms, the record envelope,
# transaction_hash, the 64 MiB cap, apply with re-validation and MalformedRecordError.
using ChainTables: CBOR, Model, Ops, MalformedRecordError, WriteBuilderError
using ChainTables.Model: Column, Shape, Table, Content
using ChainTables.Ops: CreateTable, AddColumn, DropColumn, DropTable, Insert, Update, Delete, Client, Record
using SHA: sha256

@testset "ops" begin
    hex(v) = bytes2hex(v)
    roundtrip(op) = Ops.op_from_wire(CBOR.decode(CBOR.encode(Ops.wire(op))))
    shape = Shape([Column("id", "int64", false), Column("v", "text", true)], ["id"])

    # ------------------------------------------------------------------------
    # The seven ops and their wire forms (ADR-0025): a map with "op" and "table",
    # rows as arrays of typed values, through the frozen encoder.
    # ------------------------------------------------------------------------
    @testset "op wire forms" begin
        ops = [
            CreateTable("t", shape),
            AddColumn("t", Column("w", "float64", false), 2.0),
            AddColumn("t", Column("n", "int64", true), missing),
            DropColumn("t", "v"),
            DropTable("t"),
            Insert("t", [Any[1, "a"], Any[2, missing]]),
            Update("t", ["v"], [Any[1, "b"]]),
            Delete("t", [Any[1], Any[2]]),
        ]
        for op in ops
            @test isequal(roundtrip(op), op)
        end
        # the wire form by hand: keys sort bytewise on their encoding, so "op"
        # (2 chars) comes before "table" (5), and the discriminator is the op's name
        @test hex(CBOR.encode(Ops.wire(DropTable("t")))) ==
              replace("a2 62 6f70 6a 64726f705f7461626c65 65 7461626c65 61 74", " " => "")
        @test hex(CBOR.encode(Ops.wire(DropColumn("t", "v")))) ==
              replace("a3 62 6f70 6b 64726f705f636f6c756d6e 65 7461626c65 61 74 66 636f6c756d6e 61 76", " " => "")
        # add_column: "fill" is always present, null spelt as CBOR null
        w = Ops.wire(AddColumn("t", Column("n", "int64", true), missing))
        @test haskey(w, "fill") && w["fill"] === missing
        @test w["column"] == Any["n", "int64", true]
        # create_table carries the shape in its one encoding (ADR-0025)
        @test Ops.wire(CreateTable("t", shape))["shape"] == Model.wire(shape)
        # insert rows are arrays in declaration order; update rows are [key…, values…]
        @test Ops.wire(Insert("t", [Any[1, "a"]]))["rows"] == Any[Any[1, "a"]]
        @test Ops.wire(Update("t", ["v"], [Any[1, "b"]]))["columns"] == Any["v"]
        @test Ops.wire(Delete("t", [Any[1]]))["keys"] == Any[Any[1]]

        # reading a wire op is strict: unknown tag, unknown field, missing field,
        # a field of the wrong shape
        @test_throws "unknown op \"rename_table\"" Ops.op_from_wire(Dict{String,Any}("op" => "rename_table", "table" => "t"))
        @test_throws "op has no \"op\" field" Ops.op_from_wire(Dict{String,Any}("table" => "t"))
        @test_throws "op has no \"table\" field" Ops.op_from_wire(Dict{String,Any}("op" => "drop_table"))
        @test_throws "unknown field \"extra\" on a drop_table op" Ops.op_from_wire(Dict{String,Any}("op" => "drop_table", "table" => "t", "extra" => 1))
        @test_throws "insert op has no \"rows\" field" Ops.op_from_wire(Dict{String,Any}("op" => "insert", "table" => "t"))
        @test_throws "\"table\" of an insert op is not text" Ops.op_from_wire(Dict{String,Any}("op" => "insert", "table" => 1, "rows" => Any[]))
        @test_throws "\"rows\" of an insert op is not an array of arrays" Ops.op_from_wire(Dict{String,Any}("op" => "insert", "table" => "t", "rows" => Any[1]))
        @test_throws "\"keys\" of a delete op is not an array of arrays" Ops.op_from_wire(Dict{String,Any}("op" => "delete", "table" => "t", "keys" => 1))
        @test_throws "\"columns\" of an update op is not an array of names" Ops.op_from_wire(Dict{String,Any}("op" => "update", "table" => "t", "columns" => Any[1], "rows" => Any[]))
        @test_throws "\"column\" of a drop_column op is not text" Ops.op_from_wire(Dict{String,Any}("op" => "drop_column", "table" => "t", "column" => 1))
        @test_throws "column entry" Ops.op_from_wire(Dict{String,Any}("op" => "add_column", "table" => "t", "column" => Any["n", "int64"], "fill" => 1))
        @test_throws "add_column op has no \"fill\" field" Ops.op_from_wire(Dict{String,Any}("op" => "add_column", "table" => "t", "column" => Any["n", "int64", true]))
        @test_throws "shape is not a map" Ops.op_from_wire(Dict{String,Any}("op" => "create_table", "table" => "t", "shape" => 1))
        @test_throws "op is not a map" Ops.op_from_wire(1)
        # the op names on the wire are exactly the seven
        @test Ops.op_name(CreateTable("t", shape)) == "create_table"
        @test Ops.op_name(Insert("t", Vector{Any}[])) == "insert"
    end

    # ------------------------------------------------------------------------
    # The record envelope (ADR-0006 as amended by ADR-0022): one CBOR map, hashed
    # as stored bytes under "chaintables/v1/txn" (ADR-0026); unknown is fatal in
    # both directions; the 64 MiB cap at build time.
    # ------------------------------------------------------------------------
    chain_id = UInt8.(0:15)
    fp = fill(0xaa, 32)
    prev = fill(0xbb, 32)
    client = Client(nothing, nothing, "L", "J", 1)
    genesis = Record(chain_id, 0, nothing, fp, client, nothing, [DropTable("t")])

    @testset "record envelope" begin
        # the bytes by hand: keys sort bytewise on their encoded form, so by length
        # first — ops, slot, client, chain_id, format_version, state_fingerprint —
        # and inside client: lib, julia, time_ms. prev_hash and comment absent.
        op_hex = "a2 62 6f70 6a 64726f705f7461626c65 65 7461626c65 61 74"
        genesis_hex = replace(
            "a6 63 6f7073 81 $op_hex 64 736c6f74 00 66 636c69656e74 a3 63 6c6962 61 4c 65 6a756c6961 61 4a 67 74696d655f6d73 01" *
            " 68 636861696e5f6964 50 000102030405060708090a0b0c0d0e0f 6e 666f726d61745f76657273696f6e 01" *
            " 71 73746174655f66696e6765727072696e74 5820 " * "aa"^32, " " => "")
        bytes = Ops.encode_record(genesis)
        @test hex(bytes) == genesis_hex
        @test Ops.transaction_hash(bytes) == sha256(vcat(codeunits("chaintables/v1/txn"), bytes))
        @test length(Ops.transaction_hash(bytes)) == 32
        @test isequal(Ops.decode_record(bytes), genesis)
        @test isequal(Ops.decode_record(bytes; slot = 0), genesis)

        # every optional field present: prev_hash at slot 1, host, user, comment
        full = Record(chain_id, 1, prev, fp, Client("h", "u", "L", "J", 2), "why", [DropTable("t"), DropTable("u")])
        back = Ops.decode_record(Ops.encode_record(full); slot = 1)
        @test isequal(back, full)
        @test back.prev_hash == prev && back.client.host == "h" && back.comment == "why"
        w = Ops.wire(full)
        @test w["format_version"] == 1 && w["client"]["time_ms"] == 2
        @test sort(collect(keys(Ops.wire(genesis)))) == ["chain_id", "client", "format_version", "ops", "slot", "state_fingerprint"]

        # the constructor holds the envelope rules, so the builder and the decoder
        # share them
        @test_throws "chain_id is 15 bytes; a chain id is 16" Record(chain_id[1:15], 0, nothing, fp, client, nothing, [DropTable("t")])
        @test_throws "state_fingerprint is 31 bytes; a SHA-256 is 32" Record(chain_id, 0, nothing, fp[1:31], client, nothing, [DropTable("t")])
        @test_throws "prev_hash is 1 bytes; a SHA-256 is 32" Record(chain_id, 1, UInt8[0], fp, client, nothing, [DropTable("t")])
        @test_throws "slot 0 carries a prev_hash; genesis has no parent" Record(chain_id, 0, prev, fp, client, nothing, [DropTable("t")])
        @test_throws "slot 1 has no prev_hash; every slot after genesis names its parent" Record(chain_id, 1, nothing, fp, client, nothing, [DropTable("t")])
        @test_throws "slot -1 is negative" Record(chain_id, -1, nothing, fp, client, nothing, [DropTable("t")])
        # zero ops is legal at slot 0 — the genesis create_chain writes — and nowhere else (ADR-0019)
        @test isempty(Record(chain_id, 0, nothing, fp, client, nothing, Ops.Op[]).ops)
        @test_throws "record has no ops; a record after genesis carries at least one" Record(chain_id, 1, prev, fp, client, nothing, Ops.Op[])
        @test_throws "comment contains U+0000" Record(chain_id, 0, nothing, fp, client, "a\0b", [DropTable("t")])
        @test_throws "comment is not well-formed UTF-8" Record(chain_id, 0, nothing, fp, client, "\xff", [DropTable("t")])
        @test_throws "client.host contains U+0000" Client("\0", nothing, "L", "J", 1)

        # reading is strict: every envelope violation is a malformed record naming the slot
        bad(w; slot = nothing) = Ops.decode_record(CBOR.encode(w); slot)
        w0 = Ops.wire(genesis)
        with(w; kw...) = (d = copy(w); for (k, v) in kw; v === nothing ? delete!(d, string(k)) : (d[string(k)] = v); end; d)
        @test_throws MalformedRecordError bad(with(w0; extra = 1))
        @test_throws "malformed record at slot 0" bad(with(w0; extra = 1))
        @test_throws "unknown envelope field \"extra\"" bad(with(w0; extra = 1))
        @test_throws "format_version 2 is above this client's maximum, 1; a newer client wrote it: upgrade ChainTables" bad(with(w0; format_version = 2))
        @test_throws "format_version 0 is not a version this client reads" bad(with(w0; format_version = 0))
        @test_throws "format_version is not an integer" bad(with(w0; format_version = "1"))
        @test_throws "record has no \"format_version\"" bad(with(w0; format_version = nothing))
        @test_throws "record has no \"client\"" bad(with(w0; client = nothing))
        @test_throws "chain_id is not bytes" bad(with(w0; chain_id = "x"))
        @test_throws "chain_id is 2 bytes; a chain id is 16" bad(with(w0; chain_id = UInt8[1, 2]))
        @test_throws "slot is not an integer" bad(with(w0; slot = 1.0))
        @test_throws "slot 0 carries a prev_hash" bad(with(w0; prev_hash = prev))
        @test_throws "comment is not text" bad(with(w0; comment = 1))
        @test_throws "ops is not an array" bad(with(w0; ops = 1))
        @test isempty(bad(with(w0; ops = Any[])).ops)
        @test_throws "record has no ops" bad(with(w0; slot = 1, prev_hash = prev, ops = Any[]); slot = 1)
        @test_throws "op 1: op is not a map" bad(with(w0; ops = Any[1]))
        @test_throws "op 2: unknown op \"nope\"" bad(with(w0; ops = Any[w0["ops"][1], Dict{String,Any}("op" => "nope", "table" => "t")]))
        @test_throws "client is not a map" bad(with(w0; client = 1))
        @test_throws "unknown client field \"pid\"" bad(with(w0; client = Dict{String,Any}("lib" => "L", "julia" => "J", "time_ms" => 1, "pid" => 1)))
        @test_throws "client has no \"lib\"" bad(with(w0; client = Dict{String,Any}("julia" => "J", "time_ms" => 1)))
        @test_throws "client.time_ms is not an integer" bad(with(w0; client = Dict{String,Any}("lib" => "L", "julia" => "J", "time_ms" => 1.0)))
        @test_throws "client.host is not text" bad(with(w0; client = Dict{String,Any}("lib" => "L", "julia" => "J", "time_ms" => 1, "host" => 1)))
        # the slot the record was fetched from must be the slot it names (ADR-0002)
        @test_throws "malformed record at slot 3: the record names slot 0" bad(w0; slot = 3)
        # not the format's CBOR at all: the decoder's rejection, folded
        @test_throws "malformed record at slot 5: not deterministic CBOR (byte 0: " Ops.decode_record(UInt8[0xff]; slot = 5)
        @test_throws MalformedRecordError Ops.decode_record(vcat(bytes, 0x00))
        @test_throws "trailing bytes" Ops.decode_record(vcat(bytes, 0x00))
        @test_throws "record is not a map" Ops.decode_record(CBOR.encode(1))
        # the message ends with the one next move ADR-0020 allows
        @test_throws "the chain is dead beyond this slot; a new chain is the recovery" bad(with(w0; extra = 1))

        # the 64 MiB cap, at build time, with the byte count (ADR-0006)
        big = Record(chain_id, 0, nothing, fp, client, nothing,
                     [Insert("t", [Any[1, zeros(UInt8, 64 * 1024 * 1024)]])])
        @test_throws WriteBuilderError Ops.encode_record(big)
        @test_throws "record is 67109033 bytes; the cap is 67108864 bytes (64 MiB): split the write" Ops.encode_record(big)
        @test_throws "malformed record at slot 0: record is 67108865 bytes; the cap is 67108864" Ops.decode_record(zeros(UInt8, 64 * 1024 * 1024 + 1); slot = 0)
    end

    # ------------------------------------------------------------------------
    # The client map (ADR-0006): host and user individually suppressible; lib and
    # julia advisory; time_ms int64 milliseconds since the epoch.
    # ------------------------------------------------------------------------
    @testset "local client" begin
        c = Ops.local_client(; user = "carol")
        @test startswith(c.lib, "ChainTables 0.")
        @test c.julia == string(VERSION)
        @test c.host isa String && !isempty(c.host)
        @test c.user == "carol"                       # the resolved author, never read from ENV here (ADR-0028)
        @test abs(c.time_ms - round(Int64, time() * 1000)) < 60_000
        @test Ops.local_client(; user = "").user === nothing
        c2 = Ops.local_client(; record_host = false)
        @test c2.host === nothing && c2.user === nothing
        @test !haskey(Ops.wire(Record(chain_id, 0, nothing, fp, c2, nothing, [DropTable("t")]))["client"], "host")
    end

    # ------------------------------------------------------------------------
    # Apply re-validates every op (ADR-0025): a record that fails any structural
    # check is a malformed record, and apply names the slot, the op index and
    # the rule. The checks are the model's own — one code path with the builder.
    # ------------------------------------------------------------------------
    record(slot, ops; prev = slot == 0 ? nothing : prev) = Record(chain_id, slot, prev, fp, client, nothing, ops)
    # a record as a second client meets it: through the bytes
    second(slot, ops) = Ops.decode_record(Ops.encode_record(record(slot, ops)); slot)
    fresh() = (c = Content(); Ops.apply!(c, second(0, [CreateTable("t", shape), Insert("t", [Any[1, "a"], Any[2, missing]])])); c)

    @testset "apply" begin
        c = fresh()
        @test collect(keys(c)) == ["t"]
        @test isequal(Model.getrow(c["t"], (2,)), Any[2, missing])
        @test Model.state_fingerprint(c) == Model.state_fingerprint(Content("t" => Table(shape, [Any[1, "a"], Any[2, missing]])))
        # every op kind, applied in order within one record
        Ops.apply!(c, second(1, [
            Update("t", ["v"], [Any[2, "b"]]),
            Delete("t", [Any[1]]),
            AddColumn("t", Column("w", "float64", false), 0.5),       # a non-nullable float64 is addable
            AddColumn("t", Column("n", "int64", true), missing),
            DropColumn("t", "v"),
            CreateTable("u", Shape([Column("k", "bytes", false)], ["k"])),
            Insert("u", [Any[UInt8[]], Any[UInt8[1]]]),
            DropTable("u"),
        ]))
        @test collect(keys(c)) == ["t"]
        @test isequal(Model.getrow(c["t"], (2,)), Any[2, 0.5, missing])
        @test c["t"].shape == Shape([Column("id", "int64", false), Column("w", "float64", false), Column("n", "int64", true)], ["id"])
        @test Ops.apply!(c, second(2, [DropTable("t")])) === nothing
        @test isempty(c)

        # the named test: a float64 in an int64 column raises MalformedRecordError
        # at apply on a second client, naming slot, op index and rule
        c = fresh()
        bad = second(1, [DropColumn("t", "v"), Insert("t", [Any[3.0]])])
        @test_throws MalformedRecordError Ops.apply!(c, bad)
        @test_throws "malformed record at slot 1: op 2 (insert on \"t\"): column \"id\" is int64, got a value of type Float64" Ops.apply!(fresh(), bad)
        @test_throws "(chain AAAQEAYEAUDAOCAJBIFQYDIOB4)" Ops.apply!(fresh(), bad)      # the chain id as humans read it (ADR-0019)
        err = try; Ops.apply!(fresh(), bad); nothing; catch e; e; end
        @test (err.chain_id, err.slot, err.op) == ("AAAQEAYEAUDAOCAJBIFQYDIOB4", 1, 2)
        @test_throws "the chain is dead beyond this slot; a new chain is the recovery" Ops.apply!(fresh(), bad)

        # each structural check of ADR-0025, refused at the op that breaks it
        rule(ops) = try Ops.apply!(fresh(), second(1, ops)); "applied" catch e; e isa MalformedRecordError ? e.msg : rethrow() end
        @test occursin("op 1 (insert on \"t\"): column \"id\" is int64 and does not admit null", rule([Insert("t", [Any[missing, "x"]])]))
        @test occursin("op 1 (insert on \"t\"): row has 1 cells; the shape has 2 columns", rule([Insert("t", [Any[3]])]))        # every column named
        @test occursin("op 1 (insert on \"nope\"): unknown table \"nope\"", rule([Insert("nope", [Any[3, "x"]])]))
        @test occursin("op 1 (update on \"t\"): unknown column \"zz\"", rule([Update("t", ["zz"], [Any[1, "x"]])]))
        @test occursin("op 1 (drop_column on \"t\"): column \"id\" is a key column and cannot be dropped", rule([DropColumn("t", "id")]))
        @test occursin("op 1 (add_column on \"t\"): column \"n\" is int64 and does not admit null", rule([AddColumn("t", Column("n", "int64", false), missing)]))
        @test occursin("op 1 (add_column on \"t\"): column \"v\" already exists", rule([AddColumn("t", Column("v", "text", true), missing)]))
        @test occursin("op 1 (insert on \"t\"): duplicate key (3,) inside one op", rule([Insert("t", [Any[3, "x"], Any[3, "y"]])]))
        @test occursin("op 1 (delete on \"t\"): duplicate key (1,) inside one op", rule([Delete("t", [Any[1], Any[1]])]))
        @test occursin("op 1 (insert on \"t\"): rows are not in primary-key order: (3,) after (4,)", rule([Insert("t", [Any[4, "x"], Any[3, "y"]])]))
        @test occursin("op 1 (update on \"t\"): rows are not in primary-key order: (1,) after (2,)", rule([Update("t", ["v"], [Any[2, "x"], Any[1, "y"]])]))
        @test occursin("op 1 (delete on \"t\"): rows are not in primary-key order: (1,) after (2,)", rule([Delete("t", [Any[2], Any[1]])]))
        # the state gate: insert on a present key, update or delete on an absent key
        @test occursin("op 1 (insert on \"t\"): insert names a key that is present: (1,)", rule([Insert("t", [Any[1, "x"]])]))
        @test occursin("op 1 (update on \"t\"): update names a key that is absent: (9,)", rule([Update("t", ["v"], [Any[9, "x"]])]))
        @test occursin("op 1 (delete on \"t\"): delete names a key that is absent: (9,)", rule([Delete("t", [Any[9]])]))
        # update's columns are non-key, distinct, in declaration order; its rows are [key…, values…]
        @test occursin("op 1 (update on \"t\"): update names key column \"id\"", rule([Update("t", ["id"], [Any[1, 5]])]))
        @test occursin("op 1 (update on \"t\"): update row has 1 cells; expected 1 key cells and 1 values", rule([Update("t", ["v"], [Any[1]])]))
        @test occursin("op 1 (update on \"t\"): update names no non-key column", rule([Update("t", String[], [Any[1]])]))
        @test occursin("op 2 (update on \"t\"): update columns are not in declaration order: [\"w\", \"v\"]",
                       rule([AddColumn("t", Column("w", "float64", true), missing), Update("t", ["w", "v"], [Any[1, 1.0, "x"]])]))
        @test occursin("op 1 (delete on \"t\"): key (1, 2) has 2 cells; the key has 1", rule([Delete("t", [Any[1, 2]])]))
        # tables: a known name, the identifier rule, no double creation
        @test occursin("op 1 (create_table on \"t\"): table \"t\" already exists", rule([CreateTable("t", shape)]))
        @test occursin("op 1 (create_table on \"T\"): table name \"T\" is not an identifier", rule([CreateTable("T", shape)]))
        @test occursin("op 1 (drop_table on \"nope\"): unknown table \"nope\"", rule([DropTable("nope")]))
        @test occursin("op 1 (drop_column on \"nope\"): unknown table \"nope\"", rule([DropColumn("nope", "v")]))
        # ops after the failing one are not applied, and the ops before it are
        c = fresh()
        @test_throws MalformedRecordError Ops.apply!(c, second(1, [DropColumn("t", "v"), Insert("t", [Any[1]]), CreateTable("u", shape)]))
        @test collect(keys(c)) == ["t"] && Model.ncols(c["t"].shape) == 1

        # one op at a time, for the builder: the model's error, unfolded
        c = fresh()
        @test Ops.apply!(c, Delete("t", [Any[1]])) === nothing
        @test_throws Model.ModelError Ops.apply!(c, Delete("t", [Any[1]]))
        @test_throws "delete names a key that is absent: (1,)" Ops.apply!(c, Delete("t", [Any[1]]))

        # sorting rows into the canonical order is the builder's job; apply never
        # sorts, but the helper that does is here so the two agree
        rows = [Any[2, "b"], Any[1, "a"], Any[NaN, "n"]]
        @test isequal(Ops.sort_rows(rows, r -> (r[1],)), [Any[1, "a"], Any[2, "b"], Any[NaN, "n"]])
        @test isequal(Ops.sort_rows([Any[0.0, 1], Any[-0.0, 2], Any[Inf, 3], Any[NaN, 4]], r -> (r[1],)),
                      [Any[-0.0, 2], Any[0.0, 1], Any[Inf, 3], Any[NaN, 4]])
    end

    # ------------------------------------------------------------------------
    # The determinism vector (ADR-0022, #34 §4): the model vector of test/model.jl
    # as one genesis record. Its state_fingerprint is the literal frozen there;
    # its transaction_hash is minted here from the first green run and FROZEN:
    # changing either literal is a chain break and needs an ADR. The client
    # fields are literals, not this machine's.
    # ------------------------------------------------------------------------
    @testset "determinism vector: transaction_hash" begin
        signbit_nan = reinterpret(Float64, 0xfff8000000000000)
        by_key(shape) = r -> Model.key_of(shape, r)
        measurements = Shape([Column("sample", "text", false), Column("run", "int64", false),
                              Column("value", "float64", true), Column("payload", "bytes", false)], ["sample", "run"])
        points = Shape([Column("x", "float64", false), Column("label", "text", true)], ["x"])
        ops = Ops.Op[
            CreateTable("measurements", measurements),
            Insert("measurements", Ops.sort_rows([
                Any["水", 1, -0.0, UInt8[]],
                Any["água", 2, signbit_nan, UInt8[0x00, 0xff]],
                Any["ß", typemax(Int64), Inf, UInt8[1, 2, 3]],
                Any["a", typemin(Int64), -Inf, UInt8[0]],
                Any["z", 0, missing, UInt8[]],
                Any["z", -1, 0.1 + 0.2, UInt8[]],
            ], by_key(measurements))),
            CreateTable("points", points),
            Insert("points", Ops.sort_rows([
                Any[-0.0, "negative zero"], Any[0.0, "zero"], Any[NaN, "nan"], Any[Inf, "inf"], Any[-Inf, "-inf"],
                Any[1.5, "one and a half"], Any[1.0e300, "big"], Any[5.0e-324, "denormal"], Any[2.0, missing]], by_key(points))),
            AddColumn("points", Column("weight", "float64", false), 2.0),
            AddColumn("points", Column("tag", "text", true), missing),
            Update("points", ["label", "weight"], Ops.sort_rows([Any[NaN, "not a number", 0.5], Any[-0.0, missing, -1.0]], r -> (r[1],))),
            Delete("points", Ops.sort_rows([Any[1.5], Any[Inf]], r -> (r[1],))),
            DropColumn("points", "tag"),
            CreateTable("empty", Shape([Column("k", "int64", false), Column("v", "text", true)], ["k"])),
            CreateTable("set", Shape([Column("k", "bytes", false)], ["k"])),
            Insert("set", Ops.sort_rows([Any[UInt8[2]], Any[UInt8[1, 2]], Any[UInt8[1]], Any[UInt8[]]], r -> (r[1],))),
            CreateTable("gone", Shape([Column("k", "int64", false)], ["k"])),
            Insert("gone", [Any[1]]),
            DropTable("gone"),
        ]
        frozen_fp = hex2bytes("62bffad1f527b79663c487fe1e192be4617ccf4f29e466c7d8fbcfa92c505582")
        vector = Record(UInt8.(0:15), 0, nothing, frozen_fp,
                        Client("ci", "ci", "ChainTables 0.1.0", "1.10.0", 1_700_000_000_000),
                        "determinism vector", ops)
        # the ops reproduce the model vector's frozen fingerprint
        c = Content()
        Ops.apply!(c, vector)
        @test Model.state_fingerprint(c) == frozen_fp
        # the bytes, and their hash, are the same on every cell
        bytes = Ops.encode_record(vector)
        @test length(bytes) == 1226
        @test hex(Ops.transaction_hash(bytes)) == "4529901d4b7bd95f56c6fd7cd32dec21baffdab666956f5dda37bd93791fa206"
        # and the second client reads exactly what the first wrote
        back = Ops.decode_record(bytes; slot = 0)
        @test isequal(back, vector)
        @test Ops.encode_record(back) == bytes
        c2 = Content()
        Ops.apply!(c2, back)
        @test Model.state_fingerprint(c2) == frozen_fp
    end
end
