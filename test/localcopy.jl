# #34 step 5 — ADR-0023, ADR-0009, ADR-0013, ADR-0019, ADR-0020: table files, head
# file, open checks, sweep, lazy load with hash-before-use, checkpoints. Steps 7
# and 8 add commit/sync/recovery and views below.
using ChainTables: CBOR, Model, Ops, LocalCopy, Head, NotALocalCopyError, LayoutVersionError,
    WrongChainError, LocalCopyInconsistentError, FingerprintMismatchError
using ChainTables.Model: Column, Shape, Table, Content
using ChainTables.Ops: CreateTable, AddColumn, DropColumn, Insert, Update, Client, Record
using SHA: sha256

# Stand-ins for `Chain` (#34 step 7). `open` does no network I/O and must not
# reach into the chain at all: every property read on the first one is counted.
mutable struct LocalCopyTestChain
    reads::Int
    store::Nothing
end
LocalCopyTestChain() = LocalCopyTestChain(0, nothing)
function Base.getproperty(c::LocalCopyTestChain, f::Symbol)
    setfield!(c, :reads, getfield(c, :reads) + 1)
    return getfield(c, f)
end
# A chain that knows its chain id, so `open` can check the head against it.
struct LocalCopyTestBoundChain
    chain_id::String
end
ChainTables.expected_chain_id(c::LocalCopyTestBoundChain) = c.chain_id

@testset "localcopy" begin
    CT = ChainTables
    hex = bytes2hex
    chain_id = UInt8.(0:15)
    cid = CT.chain_id_string(chain_id)
    txn(n) = fill(UInt8(n), 32)
    shape = Shape([Column("id", "int64", false), Column("v", "text", true)], ["id"])
    rows = [Any[1, "a"], Any[2, missing]]
    heads(dir) = sort(readdir(joinpath(dir, "heads")))
    tabs(dir) = sort(readdir(joinpath(dir, "tables")))
    headfile(dir, slot) = joinpath(dir, "heads", CT.head_filename(slot))
    # a copy bound at slot 0 with zero tables, then slot 1 with tables t, u (identical) and w
    function two_checkpoints!(copy)
        CT.checkpoint!(copy, chain_id, 0, txn(0), Model.state_fingerprint(copy.content))
        for name in ("t", "u")
            Ops.apply!(copy.content, CreateTable(name, shape))
            Ops.apply!(copy.content, Insert(name, rows))
        end
        Ops.apply!(copy.content, CreateTable("w", shape))
        Ops.apply!(copy.content, Insert("w", [Any[7, "z"]]))
        CT.checkpoint!(copy, chain_id, 1, txn(1), Model.state_fingerprint(copy.content))
        return copy
    end
    # a head file's bytes with fields overridden: for manufacturing damage
    function head_bytes(bytes; kw...)
        sep = codeunits(CT.HEAD_SEPARATOR)
        w = CBOR.decode(bytes[length(sep)+1:end])
        for (k, v) in kw
            v === nothing ? delete!(w, string(k)) : (w[string(k)] = v)
        end
        return vcat(sep, CBOR.encode(w))
    end

    # ------------------------------------------------------------------------
    # The chain id as humans read it (ADR-0011, ADR-0023): 16 bytes, 26 base32
    # characters, no padding.
    # ------------------------------------------------------------------------
    @testset "chain id" begin
        @test cid == "AAAQEAYEAUDAOCAJBIFQYDIOB4"
        @test length(cid) == 26 && occursin(r"^[A-Z2-7]{26}$", cid)
        @test CT.chain_id_string(zeros(UInt8, 16)) == "A"^26
        @test CT.chain_id_string(fill(0xff, 16)) == "7"^25 * "4"
        @test CT.chain_id_bytes(cid) == chain_id
        for _ in 1:20
            b = rand(UInt8, 16)
            @test CT.chain_id_bytes(CT.chain_id_string(b)) == b
        end
        @test_throws "a chain id is 16 bytes" CT.chain_id_string(UInt8[1, 2])
        @test_throws "a chain id is 26 base32 characters" CT.chain_id_bytes("ABC")
        @test_throws "not a base32 character" CT.chain_id_bytes("1" * "A"^25)
        @test_throws "trailing bits" CT.chain_id_bytes("A"^25 * "B")
    end

    # ------------------------------------------------------------------------
    # Open states (ADR-0023, ADR-0019): absent or empty is fresh and unbound;
    # a non-empty directory without heads/ and tables/ is not a local copy;
    # open touches no network — and no field of the chain.
    # ------------------------------------------------------------------------
    @testset "open: fresh, not a local copy, no network" begin
        mktempdir() do dir
            path = joinpath(dir, "fresh")
            chain = LocalCopyTestChain()
            copy = CT.open(chain, path)
            @test copy isa LocalCopy
            @test getfield(chain, :reads) == 0
            @test isdir(joinpath(path, "heads")) && isdir(joinpath(path, "tables"))
            @test copy.head === nothing
            @test CT.tables(copy) == String[]
            @test !CT.ispinned(copy)
            @test_throws "the local copy at $(path) has no head yet; sync!(copy) binds it" CT.head(copy)
            close(copy)
            @test_throws "the local copy at $(path) is closed" CT.tables(copy)
            # an empty existing directory is fresh too, and the layout is created in it
            empty = mkdir(joinpath(dir, "empty"))
            close(CT.open(chain, empty))
            @test sort(readdir(empty)) == ["heads", "tables"]
            # a pin file is layout, not head
            touch(joinpath(empty, "pin"))
            c2 = CT.open(chain, empty)
            @test CT.ispinned(c2)
            close(c2)
            # not a local copy: a file, or a non-empty directory without the layout
            file = joinpath(dir, "file")
            write(file, "x")
            @test_throws NotALocalCopyError CT.open(chain, file)
            @test_throws "not a local copy: $(file) exists and is not a directory" CT.open(chain, file)
            other = mkdir(joinpath(dir, "other"))
            write(joinpath(other, "notes.txt"), "x")
            @test_throws "not a local copy: $(other) is a non-empty directory without heads/ and tables/" CT.open(chain, other)
            mkdir(joinpath(other, "heads"))   # one of the two is still not a local copy
            @test_throws NotALocalCopyError CT.open(chain, other)
            @test isfile(joinpath(other, "notes.txt"))   # nothing was touched
        end
    end

    # ------------------------------------------------------------------------
    # A zero-table chain's head (ADR-0023): slot 0 binds the copy, names no file,
    # and reopens to the same head.
    # ------------------------------------------------------------------------
    @testset "zero-table head" begin
        mktempdir() do path
            copy = CT.open(LocalCopyTestChain(), path)
            fp0 = Model.state_fingerprint(Content())
            CT.checkpoint!(copy, chain_id, 0, txn(0), fp0)
            @test heads(path) == ["000000000000"]
            @test tabs(path) == String[]
            @test CT.head(copy) == (; slot = 0, transaction_hash = txn(0), state_fingerprint = fp0)
            close(copy)
            again = CT.open(LocalCopyTestChain(), path)
            @test CT.head(again) == (; slot = 0, transaction_hash = txn(0), state_fingerprint = fp0)
            @test CT.tables(again) == String[]
            @test again.head.chain_id == cid
            close(again)
        end
    end

    # ------------------------------------------------------------------------
    # Table files (ADR-0023, ADR-0007): sha256sum of a file is its name; two
    # identical tables share one file; a zero-row table has a file; the head
    # lists tables sorted by name; the head is written after the files it names.
    # ------------------------------------------------------------------------
    @testset "table files and the head file" begin
        mktempdir() do path
            copy = two_checkpoints!(CT.open(LocalCopyTestChain(), path))
            @test heads(path) == ["000000000001"]         # slot 0's head swept
            files = tabs(path)
            @test length(files) == 2                       # t and u share one file
            for f in files
                @test occursin(r"^[0-9a-f]{64}$", f)
                @test hex(sha256(read(joinpath(path, "tables", f)))) == f
            end
            h = copy.head
            @test h isa Head
            @test first.(h.tables) == ["t", "u", "w"]
            @test h.tables[1].second == h.tables[2].second != h.tables[3].second
            @test Set(hex.(last.(h.tables))) == Set(files)
            @test h.state_fingerprint == Model.state_fingerprint(h.tables) == Model.state_fingerprint(copy.content)
            @test h.slot == 1 && h.transaction_hash == txn(1) && h.chain_id == cid
            @test h.format_version == Ops.FORMAT_VERSION
            @test startswith(h.written_by.lib, "ChainTables ") && h.written_by.julia == string(VERSION)
            @test h.written_at_ms > 1_700_000_000_000

            # the file on disk: the head magic, then one CBOR map with exactly the
            # ADR's fields, chain_id as base32 text, tables as [name, hash] pairs
            bytes = read(headfile(path, 1))
            sep = codeunits(CT.HEAD_SEPARATOR)
            @test bytes[1:length(sep)] == sep
            w = CBOR.decode(bytes[length(sep)+1:end])
            @test sort(collect(keys(w))) == sort(collect(CT.HEAD_FIELDS))
            @test w["layout_version"] == 1 && w["chain_id"] == cid && w["slot"] == 1
            @test w["tables"] == Any[Any[n, hh] for (n, hh) in h.tables]
            @test w["state_fingerprint"] == h.state_fingerprint
            @test isequal(CT.decode_head(bytes), h)
            @test CT.encode_head(h) == bytes
            # a zero-row table still has a file, since its shape is hashed
            Ops.apply!(copy.content, CreateTable("empty", shape))
            CT.checkpoint!(copy, chain_id, 2, txn(2), Model.state_fingerprint(copy.content))
            @test length(tabs(path)) == 3
            @test CT.tables(copy) == ["empty", "t", "u", "w"]
            close(copy)
        end
    end

    # ------------------------------------------------------------------------
    # Lazy load with hash-before-use (ADR-0023, ADR-0013): open hashes nothing;
    # a table is read whole on first touch, hashed against its name first; a
    # shape read from a file equals what create_table plus column ops carry.
    # ------------------------------------------------------------------------
    @testset "lazy load" begin
        mktempdir() do path
            copy = CT.open(LocalCopyTestChain(), path)
            Ops.apply!(copy.content, CreateTable("t", shape))
            Ops.apply!(copy.content, AddColumn("t", Column("mass", "float64", true), missing))
            Ops.apply!(copy.content, DropColumn("t", "v"))
            Ops.apply!(copy.content, Insert("t", [Any[1, 1.5], Any[2, missing]]))
            CT.checkpoint!(copy, chain_id, 0, txn(0), Model.state_fingerprint(copy.content))
            close(copy)

            again = CT.open(LocalCopyTestChain(), path)
            @test isempty(again.content) && isempty(again.loaded)     # nothing read at open
            @test CT.tables(again) == ["t"]
            t = CT.load_table!(again, "t")
            @test t.shape == Shape([Column("id", "int64", false), Column("mass", "float64", true)], ["id"])
            @test isequal(collect(Model.rows_in_key_order(t)), [Any[1, 1.5], Any[2, missing]])
            @test CT.load_table!(again, "t") === t                       # resident until close
            @test again.loaded == Set(["t"])
            @test_throws "unknown table \"nope\"" CT.load_table!(again, "nope")
            # load_tables! over a record loads every table its ops name, so apply
            # sees the real state (create_table on a name the head already has fails)
            close(again)
            again = CT.open(LocalCopyTestChain(), path)
            rec = Record(chain_id, 1, txn(0), txn(9), Client(nothing, nothing, "L", "J", 1), nothing,
                         [CreateTable("t", shape)])
            CT.load_tables!(again, rec)
            @test haskey(again.content, "t")
            @test_throws "table \"t\" already exists" Ops.apply!(again.content, rec)
            close(again)

            # a damaged file: the same name, other bytes. open does not notice
            # (it hashes nothing); the load does, before any byte reaches the model.
            f = only(tabs(path))
            good = read(joinpath(path, "tables", f))
            bad = Base.copy(good)
            bad[end] ⊻= 0x01
            write(joinpath(path, "tables", f), bad)
            damaged = CT.open(LocalCopyTestChain(), path)
            @test CT.tables(damaged) == ["t"]
            err = try
                CT.load_table!(damaged, "t")
                nothing
            catch e
                e
            end
            @test err isa LocalCopyInconsistentError
            @test occursin("damaged copy: table file tables/$f (table \"t\" at slot 0, chain $cid) hashes to $(hex(sha256(bad)))", sprint(showerror, err))
            @test occursin("repair!(copy)", sprint(showerror, err))
            @test isempty(damaged.content)
            close(damaged)
            # a named file that is missing is caught at open, not at load
            rm(joinpath(path, "tables", f))
            @test_throws LocalCopyInconsistentError CT.open(LocalCopyTestChain(), path)
            @test_throws "names table file tables/$f (table \"t\"), which is missing" CT.open(LocalCopyTestChain(), path)
            @test_throws "delete the directory and sync!(copy) again" CT.open(LocalCopyTestChain(), path)
            write(joinpath(path, "tables", f), good)
            close(CT.open(LocalCopyTestChain(), path))
        end
    end

    # ------------------------------------------------------------------------
    # Sweep (ADR-0023): at open after the head is chosen and after every head
    # write — every head but the chosen one, every table file not named, every .tmp.
    # ------------------------------------------------------------------------
    @testset "sweep" begin
        mktempdir() do path
            orphan = "0"^64
            litter(path) = (touch(joinpath(path, "tables", orphan)); touch(joinpath(path, "tables", "abc.tmp"));
                            touch(joinpath(path, "heads", "000000000099.tmp")))
            mkdir(joinpath(path, "heads"))
            mkdir(joinpath(path, "tables"))
            litter(path)
            copy = CT.open(LocalCopyTestChain(), path)       # no head: every table file is an orphan
            @test tabs(path) == String[] && heads(path) == String[]
            two_checkpoints!(copy)
            litter(path)
            named = tabs(path)
            Ops.apply!(copy.content, Insert("w", [Any[8, "y"]]))
            CT.checkpoint!(copy, chain_id, 2, txn(2), Model.state_fingerprint(copy.content))
            @test heads(path) == ["000000000002"]
            @test !any(endswith(".tmp"), tabs(path)) && !(orphan in tabs(path))
            @test length(tabs(path)) == 2                    # w's old file swept, t/u's kept
            @test count(in(named), tabs(path)) == 1
            close(copy)
            litter(path)
            again = CT.open(LocalCopyTestChain(), path)
            @test length(tabs(path)) == 2 && heads(path) == ["000000000002"]
            close(again)
        end
    end

    # ------------------------------------------------------------------------
    # Choosing the head at open (ADR-0023): the highest self-consistent head
    # whose files all exist, else the next lower one, else a hard error.
    # ------------------------------------------------------------------------
    @testset "two heads after a crash" begin
        mktempdir() do path
            copy = two_checkpoints!(CT.open(LocalCopyTestChain(), path))
            head1 = read(headfile(path, 1))
            files1 = Dict(f => read(joinpath(path, "tables", f)) for f in tabs(path))
            Ops.apply!(copy.content, Update("w", ["v"], [Any[7, "changed"]]))
            CT.checkpoint!(copy, chain_id, 2, txn(2), Model.state_fingerprint(copy.content))
            close(copy)
            # both heads present, all files present: the higher wins, the lower is swept
            write(headfile(path, 1), head1)
            for (f, b) in files1; write(joinpath(path, "tables", f), b); end
            c = CT.open(LocalCopyTestChain(), path)
            @test CT.head(c).slot == 2 && heads(path) == ["000000000002"]
            close(c)
            # the higher head names a file that is missing: the lower is chosen,
            # with a warning, and the higher is swept
            head2 = read(headfile(path, 2))
            wfile = hex(last(c.head.tables[3]))
            rm(joinpath(path, "tables", wfile))
            write(headfile(path, 1), head1)
            for (f, b) in files1; write(joinpath(path, "tables", f), b); end
            warning = "head heads/000000000002 names table file tables/$(wfile) (table \"w\"), which is missing; " *
                      "opening the local copy at $path at slot 1 and sweeping heads/000000000002"
            c = @test_logs (:warn, warning) CT.open(LocalCopyTestChain(), path)
            @test CT.head(c).slot == 1 && heads(path) == ["000000000001"]
            @test collect(Model.rows_in_key_order(CT.load_table!(c, "w"))) == [Any[7, "z"]]
            close(c)
            # neither head usable: a hard error naming both
            write(headfile(path, 2), head2)
            rm(joinpath(path, "tables", hex(last(c.head.tables[1]))))   # t/u's shared file: both heads name it
            err = try
                CT.open(LocalCopyTestChain(), path)
                nothing
            catch e
                e
            end
            @test err isa LocalCopyInconsistentError
            msg = sprint(showerror, err)
            @test occursin("damaged copy: no head of the local copy at $path can be opened", msg)
            @test occursin("heads/000000000002", msg) && occursin("heads/000000000001", msg)
            @test occursin("delete the directory and sync!(copy) again", msg)
        end
    end

    # ------------------------------------------------------------------------
    # The four open-time errors (ADR-0020, ADR-0023): a head not self-consistent,
    # a foreign chain_id, a higher layout_version, not a local copy (above).
    # ------------------------------------------------------------------------
    @testset "open-time errors" begin
        mktempdir() do path
            copy = two_checkpoints!(CT.open(LocalCopyTestChain(), path))
            close(copy)
            good = read(headfile(path, 1))
            reopen() = CT.open(LocalCopyTestChain(), path)
            # a head not self-consistent: its state_fingerprint is not the hash of its tables list
            write(headfile(path, 1), head_bytes(good; state_fingerprint = txn(0xee)))
            @test_throws LocalCopyInconsistentError reopen()
            @test_throws "head heads/000000000001 is not self-consistent: its state_fingerprint is $(hex(txn(0xee))), the fingerprint of its tables list is" reopen()
            # tables out of name order, a wrong slot, an unknown field, a bad hash length, truncated bytes
            w = CBOR.decode(good[length(CT.HEAD_SEPARATOR)+1:end])
            write(headfile(path, 1), head_bytes(good; tables = reverse(w["tables"])))
            @test_throws "tables are not sorted by name" reopen()
            write(headfile(path, 1), head_bytes(good; slot = 3))
            @test_throws "is named for slot 1 but says slot 3" reopen()
            write(headfile(path, 1), head_bytes(good; extra = 1))
            @test_throws "unknown head field \"extra\"" reopen()
            write(headfile(path, 1), head_bytes(good; transaction_hash = UInt8[1]))
            @test_throws "transaction_hash is 1 bytes; a SHA-256 is 32" reopen()
            write(headfile(path, 1), head_bytes(good; written_by = nothing))
            @test_throws "heads/000000000001 has no \"written_by\"" reopen()
            write(headfile(path, 1), good[1:end-3])
            @test_throws LocalCopyInconsistentError reopen()
            @test_throws "cannot be decoded" reopen()
            # a foreign chain id, checked when the chain knows its id; unchecked otherwise
            write(headfile(path, 1), good)
            other = CT.chain_id_string(fill(0x11, 16))
            @test_throws WrongChainError CT.open(LocalCopyTestBoundChain(other), path)
            @test_throws "wrong chain: the local copy at $path is bound to chain $cid (head slot 1), the chain being opened is $other" CT.open(LocalCopyTestBoundChain(other), path)
            @test_throws "open a different path for this chain" CT.open(LocalCopyTestBoundChain(other), path)
            close(CT.open(LocalCopyTestBoundChain(cid), path))
            @test CT.expected_chain_id(LocalCopyTestChain()) === nothing
            # a higher layout version, in the field and in the magic
            write(headfile(path, 1), head_bytes(good; layout_version = 2))
            @test_throws LayoutVersionError reopen()
            @test_throws "layout version 2 of head heads/000000000001 is not this client's, 1: a newer client wrote the local copy at $path. Delete the directory and sync!(copy) again, or upgrade ChainTables" reopen()
            write(headfile(path, 1), vcat(codeunits("chaintables/v2/head"), good[length(CT.HEAD_SEPARATOR)+1:end]))
            @test_throws LayoutVersionError reopen()
            @test_throws "head heads/000000000001 begins \"chaintables/v2/head\", not \"chaintables/v1/head\"" reopen()
            # a record format version above this client's: also a newer client
            write(headfile(path, 1), head_bytes(good; format_version = 2))
            @test_throws LayoutVersionError reopen()
            @test_throws "format_version 2 of head heads/000000000001 is above this client's maximum, 1" reopen()
            # not our file at all
            write(headfile(path, 1), "SQLite format 3\0")
            @test_throws NotALocalCopyError reopen()
            @test_throws "head heads/000000000001 of $path is not a ChainTables head file" reopen()
            write(headfile(path, 1), good)
            close(reopen())
        end
    end

    # ------------------------------------------------------------------------
    # Checkpoints (ADR-0013, ADR-0023, ADR-0009): every checkpoint's fingerprint
    # is compared to its record's; a mismatch writes no head, drops the model,
    # sweeps the orphans and names repair!; stage/write_head/discard is the
    # commit sequence's split around the conditional PUT.
    # ------------------------------------------------------------------------
    @testset "checkpoint" begin
        mktempdir() do path
            copy = two_checkpoints!(CT.open(LocalCopyTestChain(), path))
            before = (heads(path), tabs(path), CT.head(copy))
            Ops.apply!(copy.content, Insert("w", [Any[8, "y"]]))
            wrong = txn(0xdd)
            err = try
                CT.checkpoint!(copy, chain_id, 2, txn(2), wrong; client = Client(nothing, nothing, "ChainTables 9.9.9", "1.99.0", 1))
                nothing
            catch e
                e
            end
            @test err isa FingerprintMismatchError
            msg = sprint(showerror, err)
            @test occursin("state fingerprint mismatch at slot 2 (chain $cid): the record's state_fingerprint is $(hex(wrong)), this client computed", msg)
            @test occursin("written by ChainTables 9.9.9 on Julia 1.99.0; this client is ChainTables", msg)
            @test occursin("The local copy stays at slot 1", msg)
            @test occursin("repair!(copy)", msg)
            @test (heads(path), tabs(path), CT.head(copy)) == before      # head untouched, orphan swept
            @test isempty(copy.content) && isempty(copy.loaded)            # model dropped
            @test collect(Model.rows_in_key_order(CT.load_table!(copy, "w"))) == [Any[7, "z"]]
            # a mismatch without a client still names both fingerprints
            CT.load_tables!(copy, ["t", "u", "w"])
            Ops.apply!(copy.content, Insert("w", [Any[8, "y"]]))
            computed = hex(Model.state_fingerprint(copy.content))   # before checkpoint! drops the model
            @test_throws "this client computed $computed" CT.checkpoint!(copy, chain_id, 2, txn(2), wrong)

            # stage!, then discard! (a 412 or a crash before the head): the old head
            # and its files stay, the staged file is swept, the model reloads
            CT.load_tables!(copy, ["t", "u", "w"])
            Ops.apply!(copy.content, Insert("w", [Any[8, "y"]]))
            staged = CT.stage!(copy)
            @test staged.state_fingerprint == Model.state_fingerprint(copy.content)
            @test first.(staged.tables) == ["t", "u", "w"]
            @test length(tabs(path)) == 3                                  # the new w file, an orphan until a head names it
            @test heads(path) == ["000000000001"]
            CT.discard!(copy)
            @test (heads(path), tabs(path), CT.head(copy)) == before
            @test isempty(copy.content)
            # stage!, then write_head! (after rc = 0): the head is the local commit point
            CT.load_tables!(copy, ["t", "u", "w"])
            Ops.apply!(copy.content, Insert("w", [Any[8, "y"]]))
            staged = CT.stage!(copy)
            CT.write_head!(copy, chain_id, 2, txn(2), staged)
            @test heads(path) == ["000000000002"] && length(tabs(path)) == 2
            @test CT.head(copy) == (; slot = 2, transaction_hash = txn(2), state_fingerprint = staged.state_fingerprint)
            @test copy.loaded == Set(["t", "u", "w"])
            # an untouched table keeps the head's hash without being read: the file
            # for t/u is never opened here (its damage would go unnoticed, as ADR-0023 says)
            close(copy)
            again = CT.open(LocalCopyTestChain(), path)
            CT.load_table!(again, "w")
            Ops.apply!(again.content, Insert("w", [Any[9, "x"]]))
            staged = CT.stage!(again)
            @test staged.tables[1].second == again.head.tables[1].second
            @test !haskey(again.content, "t")
            # a dropped table leaves the list; a created one joins it
            CT.load_tables!(again, ["t", "u"])
            Ops.apply!(again.content, Ops.DropTable("u"))
            Ops.apply!(again.content, CreateTable("new", shape))
            CT.checkpoint!(again, chain_id, 3, txn(3), Model.state_fingerprint(again.content))
            @test first.(again.head.tables) == ["new", "t", "w"]
            @test CT.tables(again) == ["new", "t", "w"]
            @test again.head.state_fingerprint == Model.state_fingerprint(again.head.tables)
            # the slot must advance, and the chain id must not change
            @test_throws "slot 3 is not above the head's slot 3" CT.checkpoint!(again, chain_id, 3, txn(3), again.head.state_fingerprint)
            @test_throws "is bound to chain $cid" CT.checkpoint!(again, fill(0x11, 16), 4, txn(4), again.head.state_fingerprint)
            close(again)
        end
    end
end
