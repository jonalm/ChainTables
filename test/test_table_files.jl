using Test
using SHA: sha256
# The table files and the head write are the local half of `sync!` and `commit!`. They
# have no API name of their own, so they are tested here, where they live.
using ChainTables: ChainTables, FingerprintMismatchError, LocalCopyInconsistentError,
    StateFingerprint, checkpoint!, discard!, head, load_table!, load_tables!, next_head,
    tables, write_head!, write_staged_tables
using ChainTables.Model: ModelError
using ChainTables.Ops: AddColumn, DropColumn

include("fixtures/internal_errors.jl")
include("fixtures/local_copies.jl")
include("fixtures/model_tables.jl")

const WRONG_FINGERPRINT = fill(0xdd, 32)

# A copy at slot 1, closed and opened again, so that no table is loaded.
function with_reopened_copy(f)
    mktempdir() do dir
        close(two_checkpoints!(ChainTables.open(NoChain(), dir)))
        with_copy_at(f, dir)
    end
    return nothing
end

function with_copy_at(f, dir)
    local_copy = ChainTables.open(NoChain(), dir)
    try
        f(local_copy)
    finally
        close(local_copy)
    end
    return nothing
end

# A copy at slot 1 with the table w loaded and one more row in it, ready to stage.
function with_touched_copy(f)
    with_reopened_copy() do local_copy
        load_table!(local_copy, "w")
        apply_all!(local_copy, 2, [Insert("w", [Any[8, "y"]])])
        f(local_copy)
    end
    return nothing
end

@testset "checkpoint! names each table file by the SHA-256 of its bytes" begin
    with_local_copy() do local_copy
        two_checkpoints!(local_copy)
        dir = local_copy.path
        @testset "$name" for name in table_names(dir)
            @test bytes2hex(sha256(read(joinpath(dir, "tables", name)))) == name
        end
    end
end

@testset "checkpoint! writes one file for two equal tables" begin
    with_local_copy() do local_copy
        two_checkpoints!(local_copy)
        hashes = map(last, local_copy.head.tables)
        @test hashes[1] == hashes[2]
        @test hashes[1] != hashes[3]
        @test table_names(local_copy.path) == sort(map(bytes2hex, hashes[2:3]))
    end
end

@testset "checkpoint! writes a file for a table with no rows" begin
    with_local_copy() do local_copy
        two_checkpoints!(local_copy)
        apply_all!(local_copy, 2, [CreateTable("empty", COPY_SHAPE)])
        checkpoint_at!(local_copy, 2)
        @test length(table_names(local_copy.path)) == 3
        @test tables(local_copy) == ["empty", "t", "u", "w"]
    end
end

@testset "checkpoint! writes the head of its record and sweeps the one before" begin
    with_local_copy() do local_copy
        two_checkpoints!(local_copy)
        h = local_copy.head
        @test head_names(local_copy.path) == ["000000000001"]
        @test h.chain_id == COPY_CHAIN_ID_TEXT
        @test h.slot == 1
        @test h.transaction_hash == hash_of(1)
        @test h.format_version == 1
        @test map(first, h.tables) == ["t", "u", "w"]
        @test h.state_fingerprint == content_fingerprint(local_copy)
        @test h.state_fingerprint == Model.state_fingerprint(h.tables)
        @test startswith(h.written_by.lib, "ChainTables ")
        @test h.written_by.julia == string(VERSION)
    end
end

@testset "checkpoint! writes the head file as the separator and one CBOR map" begin
    with_local_copy() do local_copy
        two_checkpoints!(local_copy)
        bytes = read(head_file_path(local_copy.path, 1))
        h = local_copy.head
        wire = head_wire(bytes)
        @test bytes[1:19] == codeunits("chaintables/v1/head")
        @test sort(collect(keys(wire))) == [
            "chain_id", "format_version", "layout_version", "slot", "state_fingerprint",
            "tables", "transaction_hash", "written_at_ms", "written_by",
        ]
        @test wire["layout_version"] == 1
        @test wire["chain_id"] == COPY_CHAIN_ID_TEXT
        @test wire["slot"] == 1
        @test wire["tables"] == Any[Any[name, hash] for (name, hash) in h.tables]
        @test wire["state_fingerprint"] == h.state_fingerprint
        @test sort(collect(keys(wire["written_by"]))) == ["julia", "lib"]
    end
end

@testset "checkpoint! refuses a state fingerprint that is not the record's" begin
    with_touched_copy() do local_copy
        dir = local_copy.path
        before = (head_names(dir), table_names(dir), head(local_copy))
        computed = content_fingerprint(local_copy)
        err = @test_throws(
            FingerprintMismatchError, "the local copy stays at slot 1, its last checkpoint",
            checkpoint!(local_copy, record_with(2, WRONG_FINGERPRINT), hash_of(2))
        )
        @test err.value.path == dir
        @test err.value.chain_id == COPY_CHAIN_ID_TEXT
        @test err.value.slot == 2
        @test err.value.expected == StateFingerprint(WRONG_FINGERPRINT)
        @test err.value.computed == StateFingerprint(computed)
        @test err.value.record_client == (; lib = "ChainTables 9.9.9", julia = "1.99.0")
        @test err.value.this_client.julia == string(VERSION)
        @test (head_names(dir), table_names(dir), head(local_copy)) == before
        @test isempty(local_copy.content)
        @test isempty(local_copy.loaded)
        @test rows_in_key_order(load_table!(local_copy, "w")) == [Any[7, "z"]]
    end
end

@testset "checkpoint! refuses a mismatch on a copy with no head" begin
    with_local_copy() do local_copy
        err = @test_throws(
            FingerprintMismatchError, "the local copy stays with no head",
            checkpoint!(local_copy, record_with(0, WRONG_FINGERPRINT), hash_of(0))
        )
        @test err.value.slot == 0
        @test local_copy.head === nothing
    end
end

@testset "checkpoint! refuses a slot that is not above the head's" begin
    with_reopened_copy() do local_copy
        @test_throws(
            ArgumentError, "slot 1 is not above the head's slot 1",
            checkpoint_at!(local_copy, 1)
        )
    end
end

@testset "checkpoint! refuses a record of another chain" begin
    with_reopened_copy() do local_copy
        fingerprint = Model.state_fingerprint(local_copy.head.tables)
        other = Record(
            fill(0x11, 16), 2, hash_of(1), fingerprint, COPY_CLIENT, nothing,
            [DropTable("unread")]
        )
        @test_throws(
            ArgumentError, "is bound to chain $COPY_CHAIN_ID_TEXT; a head for chain",
            checkpoint!(local_copy, other, hash_of(2))
        )
    end
end

@testset "load_table! reads a table whole, with the shape its ops left" begin
    mktempdir() do dir
        local_copy = ChainTables.open(NoChain(), dir)
        ops = [
            CreateTable("t", COPY_SHAPE),
            AddColumn("t", Column("mass", "float64", true), missing),
            DropColumn("t", "v"), Insert("t", [Any[1, 1.5], Any[2, missing]]),
        ]
        apply_all!(local_copy, 1, ops)
        checkpoint_at!(local_copy, 1)
        close(local_copy)
        with_copy_at(dir) do again
            t = load_table!(again, "t")
            columns = [Column("id", "int64", false), Column("mass", "float64", true)]
            @test t.shape == Shape(columns, ["id"])
            @test isequal(rows_in_key_order(t), [Any[1, 1.5], Any[2, missing]])
        end
    end
end

@testset "load_table! keeps a table loaded" begin
    with_reopened_copy() do local_copy
        t = load_table!(local_copy, "t")
        @test load_table!(local_copy, "t") === t
        @test local_copy.loaded == Set(["t"])
    end
end

@testset "load_table! refuses an unknown name" begin
    with_reopened_copy() do local_copy
        @test_throws(
            ModelError, as_shown("unknown table \"nope\""), load_table!(local_copy, "nope")
        )
    end
end

@testset "load_table! refuses a file whose bytes do not hash to its name" begin
    with_reopened_copy() do local_copy
        hash = bytes2hex(local_copy.tables["w"])
        file = joinpath(local_copy.path, "tables", hash)
        changed = read(file)
        changed[end] ⊻= 0x01
        write(file, changed)
        err = @test_throws(
            LocalCopyInconsistentError,
            "table \"w\": the file hashes to $(bytes2hex(sha256(changed)))",
            load_table!(local_copy, "w")
        )
        @test err.value.reason === :table_file_hash
        @test err.value.path == local_copy.path
        @test err.value.chain_id == COPY_CHAIN_ID_TEXT
        @test err.value.slot == 1
        @test err.value.file == "tables/$hash"
        @test isempty(local_copy.content)
        @test isempty(local_copy.loaded)
    end
end

@testset "load_table! refuses a file that went missing after open" begin
    with_reopened_copy() do local_copy
        hash = bytes2hex(local_copy.tables["w"])
        rm(joinpath(local_copy.path, "tables", hash))
        err = @test_throws(
            LocalCopyInconsistentError, "table \"w\": the file is missing",
            load_table!(local_copy, "w")
        )
        @test err.value.reason === :table_file_missing
        @test err.value.file == "tables/$hash"
    end
end

# The file hashes to its name and the head's state fingerprint holds, so only a head
# written wrongly gets here: the row is applied at slot 2 and the checkpoint is at 1.
@testset "load_table! refuses a row slot above the head's slot" begin
    mktempdir() do dir
        local_copy = ChainTables.open(NoChain(), dir)
        apply_all!(local_copy, 1, [CreateTable("t", COPY_SHAPE)])
        apply_all!(local_copy, 2, [Insert("t", [Any[2, "b"]])])
        checkpoint_at!(local_copy, 1)
        close(local_copy)
        with_copy_at(dir) do again
            err = @test_throws(
                LocalCopyInconsistentError,
                "table \"t\": the file holds a row slot 2, above the head's slot 1",
                load_table!(again, "t")
            )
            @test err.value.reason === :row_slot_above_head
            @test isempty(again.content)
        end
    end
end

# Only a head that names bytes that no checkpoint wrote gets here.
@testset "load_table! refuses a file that is no canonical table file" begin
    mktempdir() do dir
        close(two_checkpoints!(ChainTables.open(NoChain(), dir)))
        junk = Vector{UInt8}("not a table")
        hash = sha256(junk)
        write(joinpath(dir, "tables", bytes2hex(hash)), junk)
        fingerprint = Model.state_fingerprint(["t" => hash])
        file = head_file_path(dir, 1)
        named = rewritten_head(
            read(file); tables = Any[Any["t", hash]], state_fingerprint = fingerprint
        )
        write(file, named)
        with_copy_at(dir) do again
            err = @test_throws(
                LocalCopyInconsistentError, "table \"t\": not a table file: expected the",
                load_table!(again, "t")
            )
            @test err.value.reason === :table_file_not_canonical
            @test isempty(again.loaded)
        end
    end
end

@testset "load_tables! loads the tables that the head has among the names" begin
    with_reopened_copy() do local_copy
        @test load_tables!(local_copy, ["t", "nope", "w"]) === nothing
        @test local_copy.loaded == Set(["t", "w"])
    end
end

# Apply sees only what is loaded, so the table that a `create_table` names is loaded
# first, and the op is refused as it should be.
@testset "load_tables! loads the tables that a record's ops name" begin
    with_reopened_copy() do local_copy
        fingerprint = Model.state_fingerprint(local_copy.head.tables)
        record = Record(
            COPY_CHAIN_ID, 2, hash_of(1), fingerprint, COPY_CLIENT, nothing,
            [CreateTable("t", COPY_SHAPE)]
        )
        load_tables!(local_copy, record)
        @test local_copy.loaded == Set(["t"])
    end
end

@testset "write_staged_tables writes the touched tables and keeps the head" begin
    with_touched_copy() do local_copy
        dir = local_copy.path
        staged = write_staged_tables(local_copy)
        @test staged.state_fingerprint == Model.state_fingerprint(staged.tables)
        @test map(first, staged.tables) == ["t", "u", "w"]
        @test length(table_names(dir)) == 3
        @test head_names(dir) == ["000000000001"]
        @test head(local_copy).slot == 1
    end
end

@testset "write_staged_tables keeps the hash of a table that is not loaded" begin
    with_touched_copy() do local_copy
        staged = write_staged_tables(local_copy)
        @test staged.tables[1] == local_copy.head.tables[1]
        @test !haskey(local_copy.content, "t")
    end
end

@testset "write_staged_tables leaves out a dropped table and lists a created one" begin
    with_reopened_copy() do local_copy
        load_tables!(local_copy, ["t", "u"])
        apply_all!(local_copy, 2, [DropTable("u"), CreateTable("new", COPY_SHAPE)])
        @test map(first, write_staged_tables(local_copy).tables) == ["new", "t", "w"]
    end
end

@testset "discard! leaves the copy at its head, without the staged files" begin
    with_touched_copy() do local_copy
        dir = local_copy.path
        before = (head_names(dir), table_names(dir), head(local_copy))
        write_staged_tables(local_copy)
        @test discard!(local_copy) === nothing
        @test (head_names(dir), table_names(dir), head(local_copy)) == before
        @test isempty(local_copy.content)
        @test isempty(local_copy.loaded)
    end
end

@testset "write_head! moves the copy to the staged tables" begin
    with_touched_copy() do local_copy
        dir = local_copy.path
        staged = write_staged_tables(local_copy)
        moved = next_head(COPY_CHAIN_ID_TEXT, 2, hash_of(2), staged)
        @test write_head!(local_copy, moved) === nothing
        @test head_names(dir) == ["000000000002"]
        @test length(table_names(dir)) == 2
        @test head(local_copy).slot == 2
        @test head(local_copy).state_fingerprint == staged.state_fingerprint
        @test local_copy.loaded == Set(["w"])
        @test rows_in_key_order(load_table!(local_copy, "w")) == [Any[7, "z"], Any[8, "y"]]
    end
end

@testset "write_head! sweeps orphans and .tmp files" begin
    with_touched_copy() do local_copy
        dir = local_copy.path
        touch(joinpath(dir, "tables", "0"^64))
        touch(joinpath(dir, "tables", "abc.tmp"))
        touch(joinpath(dir, "heads", "000000000099.tmp"))
        checkpoint_at!(local_copy, 2)
        @test head_names(dir) == ["000000000002"]
        @test table_names(dir) == sort(unique(map(bytes2hex, values(local_copy.tables))))
    end
end

@testset "next_head takes its time from the clock" begin
    with_touched_copy() do local_copy
        staged = write_staged_tables(local_copy)
        moved = next_head(COPY_CHAIN_ID_TEXT, 2, hash_of(2), staged; at = 1.5)
        @test moved.written_at_ms == 1500
    end
end
