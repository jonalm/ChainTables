using Test
using ChainTables: ChainTables, LocalCopy, Model, NotALocalCopyError, StateFingerprint,
    TransactionHash, head, is_pinned, ispinned, tables, unpin!

include("fixtures/local_copies.jl")

const EMPTY_FINGERPRINT = Model.state_fingerprint(Model.Content())

@testset "open makes a fresh copy of an absent path" begin
    mktempdir() do dir
        path = joinpath(dir, "fresh")
        local_copy = ChainTables.open(NoChain(), path)
        @test sort(readdir(path)) == ["heads", "tables"]
        @test tables(local_copy) == String[]
        @test !is_pinned(local_copy)
        close(local_copy)
    end
end

@testset "open gives a LocalCopy of the chain's type" begin
    mktempdir() do dir
        @test @inferred(ChainTables.open(NoChain(), dir)) isa LocalCopy{NoChain}
    end
end

@testset "open makes the layout in an empty directory" begin
    mktempdir() do dir
        close(ChainTables.open(NoChain(), dir))
        @test sort(readdir(dir)) == ["heads", "tables"]
    end
end

@testset "open holds the absolute path" begin
    mktempdir() do dir
        cd(dir) do
            local_copy = ChainTables.open(NoChain(), "relative")
            @test local_copy.path == joinpath(pwd(), "relative")
            @test isabspath(local_copy.path)
            close(local_copy)
        end
    end
end

@testset "open refuses a file" begin
    mktempdir() do dir
        file = joinpath(dir, "file")
        write(file, "x")
        err = @test_throws(
            NotALocalCopyError, "The path is a file. Open a directory path.",
            ChainTables.open(NoChain(), file)
        )
        @test err.value.path == file
        @test err.value.reason === :not_a_directory
    end
end

@testset "open refuses a directory with other content and no layout" begin
    mktempdir() do dir
        write(joinpath(dir, "notes.txt"), "x")
        err = @test_throws(
            NotALocalCopyError, "The directory is not empty and has no `heads/` and",
            ChainTables.open(NoChain(), dir)
        )
        @test err.value.path == dir
        @test err.value.reason === :no_layout
        @test readdir(dir) == ["notes.txt"]
    end
end

@testset "open refuses a directory with only one of heads and tables" begin
    mktempdir() do dir
        mkdir(joinpath(dir, "heads"))
        @test_throws(
            NotALocalCopyError, "reason = no_layout", ChainTables.open(NoChain(), dir)
        )
    end
end

@testset "open reopens a copy at its head" begin
    mktempdir() do dir
        first_open = ChainTables.open(NoChain(), dir)
        checkpoint_at!(first_open, 0)
        close(first_open)
        again = ChainTables.open(NoChain(), dir)
        @test head(again).slot == 0
        @test again.head.chain_id == COPY_CHAIN_ID_TEXT
        @test tables(again) == String[]
        close(again)
    end
end

@testset "open reads no table file" begin
    mktempdir() do dir
        close(two_checkpoints!(ChainTables.open(NoChain(), dir)))
        again = ChainTables.open(NoChain(), dir)
        @test isempty(again.content)
        @test isempty(again.loaded)
        @test tables(again) == ["t", "u", "w"]
        close(again)
    end
end

@testset "open sweeps orphans and .tmp files" begin
    mktempdir() do dir
        close(two_checkpoints!(ChainTables.open(NoChain(), dir)))
        named = table_names(dir)
        touch(joinpath(dir, "tables", "0"^64))
        touch(joinpath(dir, "tables", "abc.tmp"))
        touch(joinpath(dir, "heads", "000000000099.tmp"))
        close(ChainTables.open(NoChain(), dir))
        @test table_names(dir) == named
        @test head_names(dir) == ["000000000001"]
    end
end

@testset "open sweeps every table file of a copy with no head" begin
    mktempdir() do dir
        mkdir(joinpath(dir, "heads"))
        mkdir(joinpath(dir, "tables"))
        touch(joinpath(dir, "tables", "0"^64))
        close(ChainTables.open(NoChain(), dir))
        @test table_names(dir) == String[]
    end
end

# Windows refuses a file name that ends in a newline.
if !Sys.iswindows()
    @testset "open leaves a name that is no head and no table file" begin
        mktempdir() do dir
            close(two_checkpoints!(ChainTables.open(NoChain(), dir)))
            write(joinpath(dir, "heads", "000000000009\n"), "not a head")
            touch(joinpath(dir, "tables", "0"^64 * "\n"))
            again = ChainTables.open(NoChain(), dir)
            @test head(again).slot == 1
            @test head_names(dir) == ["000000000001", "000000000009\n"]
            @test "0"^64 * "\n" in table_names(dir)
            close(again)
        end
    end
end

@testset "head gives the slot and the typed hashes" begin
    with_local_copy() do local_copy
        checkpoint_at!(local_copy, 0)
        @test @inferred(head(local_copy)).slot == 0
        at_head = head(local_copy)
        @test at_head.transaction_hash == TransactionHash(hash_of(0))
        @test at_head.state_fingerprint == StateFingerprint(EMPTY_FINGERPRINT)
    end
end

@testset "head refuses a copy with no head" begin
    with_local_copy() do local_copy
        @test_throws(
            ArgumentError, "has no head yet; sync!(copy) binds it", head(local_copy)
        )
    end
end

@testset "tables lists the head's tables and those created since, sorted" begin
    with_local_copy() do local_copy
        two_checkpoints!(local_copy)
        Ops.apply!(local_copy.content, CreateTable("a", COPY_SHAPE), 2)
        @test @inferred(tables(local_copy)) == ["a", "t", "u", "w"]
    end
end

@testset "tables leaves out a table dropped since the head" begin
    with_local_copy() do local_copy
        two_checkpoints!(local_copy)
        Ops.apply!(local_copy.content, DropTable("u"), 2)
        @test tables(local_copy) == ["t", "w"]
    end
end

@testset "close makes every later call throw" begin
    mktempdir() do dir
        local_copy = ChainTables.open(NoChain(), dir)
        @test close(local_copy) === nothing
        @test_throws ArgumentError "the local copy at $dir is closed" tables(local_copy)
        @test_throws ArgumentError "the local copy at $dir is closed" head(local_copy)
        @test_throws ArgumentError "the local copy at $dir is closed" unpin!(local_copy)
    end
end

@testset "close drops the loaded tables" begin
    mktempdir() do dir
        local_copy = two_checkpoints!(ChainTables.open(NoChain(), dir))
        close(local_copy)
        @test isempty(local_copy.content)
        @test isempty(local_copy.loaded)
        @test isdir(dir)
    end
end

@testset "close twice does nothing" begin
    mktempdir() do dir
        local_copy = ChainTables.open(NoChain(), dir)
        close(local_copy)
        @test close(local_copy) === nothing
    end
end

@testset "close deletes the directory of a temporary copy" begin
    mktempdir() do dir
        local_copy = ChainTables.open(NoChain(), joinpath(dir, "temporary"))
        local_copy.temporary = true
        close(local_copy)
        @test !ispath(joinpath(dir, "temporary"))
    end
end

@testset "is_pinned sees the pin file" begin
    with_local_copy() do local_copy
        @test !is_pinned(local_copy)
        touch(joinpath(local_copy.path, "pin"))
        @test @inferred is_pinned(local_copy)
    end
end

@testset "is_pinned holds across a reopen" begin
    mktempdir() do dir
        close(ChainTables.open(NoChain(), dir))
        touch(joinpath(dir, "pin"))
        again = ChainTables.open(NoChain(), dir)
        @test is_pinned(again)
        close(again)
    end
end

@testset "ispinned is deprecated" begin
    with_local_copy() do local_copy
        @test_deprecated ispinned(local_copy)
    end
end

@testset "unpin! deletes the pin file" begin
    with_local_copy() do local_copy
        touch(joinpath(local_copy.path, "pin"))
        @test @inferred(unpin!(local_copy)) === nothing
        @test !is_pinned(local_copy)
    end
end

@testset "unpin! refuses a copy that is not pinned" begin
    with_local_copy() do local_copy
        @test_throws ArgumentError "is not pinned; it is live already" unpin!(local_copy)
    end
end

@testset "expected_chain_id is nothing for a chain that does not know its id" begin
    @test ChainTables.expected_chain_id(NoChain()) === nothing
end
