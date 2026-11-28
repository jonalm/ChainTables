using Test
using ChainTables: ChainTables, CBOR, LayoutVersionError, LocalCopyInconsistentError,
    NotALocalCopyError, WrongChainError, head
using ChainTables.Ops: Update

include("fixtures/local_copies.jl")

tables_of(bytes) = head_wire(bytes)["tables"]

# Each case rewrites the one head file of a copy at slot 1. `fragment` is the fault that
# `open` names for it.
const DAMAGED_HEADS = [
    (
        name = "a state fingerprint that is not the one of its tables",
        damage = bytes -> rewritten_head(bytes; state_fingerprint = hash_of(0xee)),
        fragment = "heads/000000000001 is not self-consistent: its state_fingerprint " *
            "is $("ee"^32), the fingerprint of its tables list is ",
    ),
    (
        name = "tables out of name order",
        damage = bytes -> rewritten_head(bytes; tables = reverse(tables_of(bytes))),
        fragment =
            "is not self-consistent: tables are not sorted by name: [\"w\", \"u\", \"t\"]",
    ),
    (
        name = "a table named twice",
        damage = bytes -> rewritten_head(bytes; tables = tables_of(bytes)[[1, 1]]),
        fragment = "is not self-consistent: duplicate table name \"t\"",
    ),
    (
        name = "another slot than its name",
        damage = bytes -> rewritten_head(bytes; slot = 3),
        fragment = "heads/000000000001 is named for slot 1 but says slot 3",
    ),
    (
        name = "a negative slot",
        damage = bytes -> rewritten_head(bytes; slot = -1),
        fragment = "is not self-consistent: slot -1 is negative",
    ),
    (
        name = "an unknown field",
        damage = bytes -> rewritten_head(bytes; extra = 1),
        fragment = "heads/000000000001 has the unknown field \"extra\"",
    ),
    (
        name = "a transaction hash of one byte",
        damage = bytes -> rewritten_head(bytes; transaction_hash = UInt8[1]),
        fragment = "is not self-consistent: transaction_hash is 1 bytes; a SHA-256 is 32",
    ),
    (
        name = "a chain id that is not one",
        damage = bytes -> rewritten_head(bytes; chain_id = "ABC"),
        fragment =
            "is not self-consistent: a chain id is 26 base32 characters, got \"ABC\"",
    ),
    (
        name = "no written_by",
        damage = bytes -> rewritten_head(bytes; written_by = nothing),
        fragment = "heads/000000000001 has no \"written_by\"",
    ),
    (
        name = "a written_by that is no map",
        damage = bytes -> rewritten_head(bytes; written_by = 1),
        fragment = "heads/000000000001 written_by is not a map",
    ),
    (
        name = "an unknown field in written_by",
        damage = bytes -> rewritten_head(bytes; written_by = Dict("os" => "x")),
        fragment = "heads/000000000001 has the unknown written_by field \"os\"",
    ),
    (
        name = "a slot that is text",
        damage = bytes -> rewritten_head(bytes; slot = "1"),
        fragment = "heads/000000000001 slot is not an integer",
    ),
    (
        name = "a state fingerprint that is text",
        damage = bytes -> rewritten_head(bytes; state_fingerprint = "ee"),
        fragment = "heads/000000000001 state_fingerprint is not bytes",
    ),
    (
        name = "a chain id that is no text",
        damage = bytes -> rewritten_head(bytes; chain_id = 1),
        fragment = "heads/000000000001 chain_id is not text",
    ),
    (
        name = "tables that are no array",
        damage = bytes -> rewritten_head(bytes; tables = 1),
        fragment = "heads/000000000001 tables is not an array",
    ),
    (
        name = "a tables entry without a hash",
        damage = bytes -> rewritten_head(bytes; tables = Any[Any["t"]]),
        fragment = "heads/000000000001 tables entry Any[\"t\"] is not [name, hash]",
    ),
    (
        name = "format version 0",
        damage = bytes -> rewritten_head(bytes; format_version = 0),
        fragment = "has format version 0, which is not a version this client reads",
    ),
    (
        name = "CBOR that ends early",
        damage = bytes -> bytes[1:(end - 3)],
        fragment = "heads/000000000001 cannot be decoded: ",
    ),
    (
        name = "CBOR that is no map",
        damage = bytes -> vcat(codeunits(HEAD_MAGIC), CBOR.encode(1)),
        fragment = "heads/000000000001 is not a map",
    ),
]

# Each case is a head file under another layout version or a newer format version.
const OTHER_LAYOUTS = [
    (
        name = "layout version 2",
        damage = bytes -> rewritten_head(bytes; layout_version = 2),
        detail = "the head file has layout version 2; this client's is 1",
    ),
    (
        name = "the separator of layout version 2",
        damage = bytes -> vcat(codeunits("chaintables/v2/head"), bytes[20:end]),
        detail =
            "the head file begins \"chaintables/v2/head\", not \"chaintables/v1/head\"",
    ),
    (
        name = "format version 2",
        damage = bytes -> rewritten_head(bytes; format_version = 2),
        detail = "the head file has format version 2, above this client's maximum, 1",
    ),
]

const FOREIGN_FILES = [
    (name = "another program's file", bytes = Vector{UInt8}("SQLite format 3\0")),
    (name = "an empty file", bytes = UInt8[]),
    (name = "a separator with no version", bytes = Vector{UInt8}("chaintables/v/head")),
    (name = "a separator that ends early", bytes = Vector{UInt8}("chaintables/v12")),
]

# A copy at slot 1, closed, whose one head file is then replaced by `damage` of it.
function with_damaged_head(f, damage)
    mktempdir() do dir
        close(two_checkpoints!(ChainTables.open(NoChain(), dir)))
        file = head_file_path(dir, 1)
        write(file, damage(read(file)))
        f(dir)
    end
    return nothing
end

# A directory with usable heads at slots 1 and 2, as a crash between the head write and
# the sweep leaves it. `only_in_2` is the table file that only the head at slot 2 names.
function with_two_heads(f)
    mktempdir() do dir
        local_copy = two_checkpoints!(ChainTables.open(NoChain(), dir))
        head_1 = read(head_file_path(dir, 1))
        tables_dir = joinpath(dir, "tables")
        names_1 = table_names(dir)
        files_1 = Dict(name => read(joinpath(tables_dir, name)) for name in names_1)
        apply_all!(local_copy, 2, [Update("w", ["v"], [Any[7, "changed"]])])
        checkpoint_at!(local_copy, 2)
        close(local_copy)
        write(head_file_path(dir, 1), head_1)
        foreach(name -> write(joinpath(tables_dir, name), files_1[name]), names_1)
        f(dir, only(setdiff(table_names(dir), names_1)))
    end
    return nothing
end

@testset "open refuses a copy whose only head file is damaged" begin
    @testset "$(case.name)" for case in DAMAGED_HEADS
        with_damaged_head(case.damage) do dir
            err = @test_throws(
                LocalCopyInconsistentError, case.fragment, ChainTables.open(NoChain(), dir)
            )
            @test err.value.reason === :no_usable_head
        end
    end
end

@testset "open names the path and the head file of a damaged copy" begin
    with_damaged_head(bytes -> rewritten_head(bytes; slot = 3)) do dir
        err = @test_throws(
            LocalCopyInconsistentError, "Delete the directory and sync a fresh local copy.",
            ChainTables.open(NoChain(), dir)
        )
        @test err.value.path == dir
        @test err.value.file == "heads/000000000001"
        @test err.value.slot === nothing
        @test err.value.chain_id === nothing
    end
end

@testset "open refuses a head that names a missing table file" begin
    mktempdir() do dir
        local_copy = two_checkpoints!(ChainTables.open(NoChain(), dir))
        hash = bytes2hex(last(local_copy.head.tables[3]))
        close(local_copy)
        rm(joinpath(dir, "tables", hash))
        @test_throws(
            LocalCopyInconsistentError,
            "heads/000000000001 names table file tables/$hash (table \"w\"), which is missing",
            ChainTables.open(NoChain(), dir)
        )
    end
end

@testset "open refuses a copy that another version wrote" begin
    @testset "$(case.name)" for case in OTHER_LAYOUTS
        with_damaged_head(case.damage) do dir
            err = @test_throws(
                LayoutVersionError, "Delete the directory and sync a fresh local copy, or",
                ChainTables.open(NoChain(), dir)
            )
            @test err.value.detail == case.detail
            @test err.value.path == dir
            @test err.value.file == "heads/000000000001"
        end
    end
end

@testset "open refuses a head file that ChainTables did not write" begin
    @testset "$(case.name)" for case in FOREIGN_FILES
        with_damaged_head(Returns(case.bytes)) do dir
            err = @test_throws(
                NotALocalCopyError, "ChainTables did not write the head file.",
                ChainTables.open(NoChain(), dir)
            )
            @test err.value.reason === :foreign_head
            @test err.value.path == dir
            @test err.value.file == "heads/000000000001"
        end
    end
end

@testset "open refuses a copy that is bound to another chain" begin
    with_damaged_head(identity) do dir
        err = @test_throws(
            WrongChainError, "Open a different path for this chain.",
            ChainTables.open(BoundChain(OTHER_CHAIN_ID_TEXT), dir)
        )
        @test err.value.path == dir
        @test err.value.bound == COPY_CHAIN_ID_TEXT
        @test err.value.opened == OTHER_CHAIN_ID_TEXT
        @test err.value.detail == "the head is at slot 1"
    end
end

@testset "open takes a copy that is bound to the chain being opened" begin
    with_damaged_head(identity) do dir
        local_copy = ChainTables.open(BoundChain(COPY_CHAIN_ID_TEXT), dir)
        @test head(local_copy).slot == 1
        close(local_copy)
    end
end

@testset "open chooses the higher of two usable heads and sweeps the lower" begin
    with_two_heads() do dir, only_in_2
        local_copy = ChainTables.open(NoChain(), dir)
        @test head(local_copy).slot == 2
        @test head_names(dir) == ["000000000002"]
        @test only_in_2 in table_names(dir)
        close(local_copy)
    end
end

@testset "open chooses the lower head when the higher names a missing file" begin
    with_two_heads() do dir, only_in_2
        rm(joinpath(dir, "tables", only_in_2))
        local_copy = @test_logs ChainTables.open(NoChain(), dir)
        @test head(local_copy).slot == 1
        @test head_names(dir) == ["000000000001"]
        close(local_copy)
    end
end

@testset "open leaves a debug record when it chooses a lower head" begin
    with_two_heads() do dir, only_in_2
        rm(joinpath(dir, "tables", only_in_2))
        @test_logs(
            (:debug, "open chose a lower head"), min_level = Base.CoreLogging.Debug,
            ChainTables.open(NoChain(), dir)
        )
    end
end

@testset "open names every head when none is usable" begin
    with_two_heads() do dir, only_in_2
        foreach(name -> rm(joinpath(dir, "tables", name)), table_names(dir))
        err = @test_throws(
            LocalCopyInconsistentError, "heads/000000000002 names table file",
            ChainTables.open(NoChain(), dir)
        )
        @test occursin("; heads/000000000001 names table file", err.value.detail)
        @test err.value.file == "heads/000000000002"
    end
end
