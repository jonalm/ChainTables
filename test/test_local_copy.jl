using Test
using ChainTables: ChainTables, Chain, LayoutVersionError, LocalCopy,
    LocalCopyInconsistentError, NotALocalCopyError, WrongChainError, column!, commit!,
    create_chain, create_table!, decode_head, encode_head, head, insert_rows!, is_pinned,
    pin!, primary_key!, sync!, table, tables, unpin!, update_rows!, write_builder
using ChainTables.Testing: InMemoryObjectStore

function with_chain(f)
    return mktempdir() do dir
        store = InMemoryObjectStore()
        chain = Chain("bkt", "p"; store, cache_dir = joinpath(dir, "cache"))
        create_chain(chain)
        f(chain, store, dir)
    end
end

function synced_copy(chain, path)
    copy = ChainTables.open(chain, path)
    sync!(copy)
    return copy
end

function declare!(w, name)
    create_table!(w, name) do t
        column!(t, :id, Int64)
        column!(t, :v, String; nullable = true)
        primary_key!(t, :id)
    end
    return nothing
end

# Slot 1: tables t and u with the same rows, so one shared file, and w.
function commit_three_tables!(copy)
    w = write_builder(copy)
    foreach(name -> declare!(w, name), (:t, :u, :w))
    insert_rows!(w, :t, [(id = 1, v = "a"), (id = 2, v = missing)])
    insert_rows!(w, :u, [(id = 1, v = "a"), (id = 2, v = missing)])
    insert_rows!(w, :w, [(id = 7, v = "z")])
    commit!(w)
    return nothing
end

listing(path, sub) = sort(readdir(joinpath(path, sub)))
head_file(path, slot) = joinpath(path, "heads", lpad(string(slot), 12, '0'))

function caught(f)
    try
        f()
    catch e
        return e
    end
    return nothing
end

@testset "open makes a fresh, unbound copy at an absent path" begin
    with_chain() do chain, store, dir
        path = joinpath(dir, "fresh")
        n_calls = length(store.calls)
        copy = ChainTables.open(chain, path)
        @test length(store.calls) == n_calls
        @test listing(path, "") == ["heads", "tables"]
        @test tables(copy) == String[]
        @test !is_pinned(copy)
        no_head = "the local copy at $path has no head yet; sync!(copy) binds it"
        @test_throws ArgumentError no_head head(copy)
        close(copy)
    end
end

@testset "open makes a fresh copy in an empty directory, and keeps a pin file" begin
    with_chain() do chain, store, dir
        empty = mkdir(joinpath(dir, "empty"))
        close(ChainTables.open(chain, empty))
        @test listing(empty, "") == ["heads", "tables"]
        touch(joinpath(empty, "pin"))
        copy = ChainTables.open(chain, empty)
        @test is_pinned(copy)
        close(copy)
    end
end

@testset "open refuses a path that is a file" begin
    with_chain() do chain, store, dir
        file = joinpath(dir, "file")
        write(file, "x")
        detail = "it exists and is not a directory"
        @test_throws NotALocalCopyError detail ChainTables.open(chain, file)
    end
end

@testset "open refuses a non-empty directory without heads/ and tables/" begin
    with_chain() do chain, store, dir
        other = mkdir(joinpath(dir, "other"))
        write(joinpath(other, "notes.txt"), "x")
        detail = "a non-empty directory without heads/ and tables/"
        @test_throws NotALocalCopyError detail ChainTables.open(chain, other)
        mkdir(joinpath(other, "heads"))
        @test_throws NotALocalCopyError detail ChainTables.open(chain, other)
        @test isfile(joinpath(other, "notes.txt"))
    end
end

@testset "a closed copy refuses every call" begin
    with_chain() do chain, store, dir
        copy = synced_copy(chain, joinpath(dir, "copy"))
        close(copy)
        closed = "the local copy at $(copy.path) is closed"
        @test_throws ArgumentError closed tables(copy)
        @test_throws ArgumentError closed head(copy)
        @test_throws ArgumentError closed table(copy, :t)
        @test close(copy) === nothing
    end
end

@testset "a chain's slot 0 binds a copy with no table file" begin
    with_chain() do chain, store, dir
        path = joinpath(dir, "copy")
        copy = synced_copy(chain, path)
        bound = head(copy)
        @test bound.slot == 0
        @test listing(path, "heads") == ["000000000000"]
        @test listing(path, "tables") == String[]
        close(copy)
        again = ChainTables.open(chain, path)
        @test head(again) == bound
        @test tables(again) == String[]
        close(again)
    end
end

@testset "open reopens a copy at its head" begin
    with_chain() do chain, store, dir
        path = joinpath(dir, "copy")
        copy = synced_copy(chain, path)
        commit_three_tables!(copy)
        at = head(copy)
        close(copy)
        again = ChainTables.open(chain, path)
        @test head(again) == at
        @test tables(again) == ["t", "u", "w"]
        @test collect(table(again, :w)) == [(id = 7, v = "z")]
        close(again)
    end
end

@testset "open sweeps stale heads, unnamed table files and .tmp files" begin
    with_chain() do chain, store, dir
        path = joinpath(dir, "copy")
        orphan = "0"^64
        mkpath(joinpath(path, "heads"))
        mkpath(joinpath(path, "tables"))
        litter = [
            joinpath(path, "tables", orphan), joinpath(path, "tables", "abc.tmp"),
            joinpath(path, "heads", "000000000099.tmp"),
        ]
        foreach(touch, litter)
        copy = synced_copy(chain, path)
        commit_three_tables!(copy)
        named = listing(path, "tables")
        foreach(touch, litter)
        close(copy)
        close(ChainTables.open(chain, path))
        @test listing(path, "tables") == named
        @test listing(path, "heads") == ["000000000001"]
    end
end

@testset "a commit sweeps the old head and the replaced table file" begin
    with_chain() do chain, store, dir
        path = joinpath(dir, "copy")
        copy = synced_copy(chain, path)
        commit_three_tables!(copy)
        before = listing(path, "tables")
        w = write_builder(copy)
        insert_rows!(w, :w, [(id = 8, v = "y")])
        commit!(w)
        @test listing(path, "heads") == ["000000000002"]
        @test length(listing(path, "tables")) == 2
        @test count(in(before), listing(path, "tables")) == 1
        close(copy)
    end
end

# Windows refuses a file name with a newline.
@testset "open neither reads nor sweeps a name with a trailing newline" begin
    Sys.iswindows() || with_chain() do chain, store, dir
        path = joinpath(dir, "copy")
        copy = synced_copy(chain, path)
        commit_three_tables!(copy)
        close(copy)
        write(joinpath(path, "heads", "000000000009\n"), "not a head")
        touch(joinpath(path, "tables", "0"^64 * "\n"))
        again = ChainTables.open(chain, path)
        @test head(again).slot == 1
        @test listing(path, "heads") == ["000000000001", "000000000009\n"]
        @test "0"^64 * "\n" in listing(path, "tables")
        close(again)
    end
end

# Slots 1 and 2 committed; returns the slot-1 head and table files, to put back as a
# crash between the slot-2 head write and the sweep would leave them.
function with_two_heads(f)
    return with_chain() do chain, store, dir
        path = joinpath(dir, "copy")
        copy = synced_copy(chain, path)
        commit_three_tables!(copy)
        head1 = read(head_file(path, 1))
        tables_dir = joinpath(path, "tables")
        files1 = Dict(f => read(joinpath(tables_dir, f)) for f in readdir(tables_dir))
        w = write_builder(copy)
        update_rows!(w, :w, [(id = 7, v = "changed")])
        commit!(w)
        close(copy)
        f(chain, path, () -> restore_slot_one(path, head1, files1))
    end
end

function restore_slot_one(path, head1, files1)
    write(head_file(path, 1), head1)
    foreach(f -> write(joinpath(path, "tables", f), files1[f]), collect(keys(files1)))
    return nothing
end

@testset "open chooses the higher of two usable heads" begin
    with_two_heads() do chain, path, restore
        restore()
        copy = ChainTables.open(chain, path)
        @test head(copy).slot == 2
        @test listing(path, "heads") == ["000000000002"]
        close(copy)
    end
end

@testset "open falls back to the lower head when a table file is missing" begin
    with_two_heads() do chain, path, restore
        head2 = decode_head(read(head_file(path, 2)))
        w_file = bytes2hex(last(head2.tables[3]))
        rm(joinpath(path, "tables", w_file))
        restore()
        copy = @test_logs ChainTables.open(chain, path)
        @test head(copy).slot == 1
        @test listing(path, "heads") == ["000000000001"]
        @test collect(table(copy, :w)) == [(id = 7, v = "z")]
        close(copy)
    end
end

@testset "open refuses a copy with no usable head" begin
    with_two_heads() do chain, path, restore
        restore()
        shared = bytes2hex(last(decode_head(read(head_file(path, 1))).tables[1]))
        rm(joinpath(path, "tables", shared))
        e = caught(() -> ChainTables.open(chain, path))
        @test e isa LocalCopyInconsistentError
        @test e.file == "heads/000000000002"
        @test occursin("head heads/000000000002 names table file tables/$shared", e.detail)
        @test occursin("head heads/000000000001 names table file tables/$shared", e.detail)
        @test occursin("delete the directory and sync again", sprint(showerror, e))
    end
end

# A copy committed at slot 1, its head file replaced by `bytes(good)`.
function with_replaced_head(f, bytes)
    return with_chain() do chain, store, dir
        path = joinpath(dir, "copy")
        copy = synced_copy(chain, path)
        commit_three_tables!(copy)
        close(copy)
        write(head_file(path, 1), bytes(read(head_file(path, 1))))
        f(chain, path)
    end
end

function with_fields(good; fields...)
    h = decode_head(good)
    names = fieldnames(typeof(h))
    values = merge(NamedTuple{names}(getfield.(Ref(h), names)), (; fields...))
    return encode_head(typeof(h)(values...))
end

@testset "open refuses a head that is not self-consistent" begin
    damaged = good -> with_fields(good; state_fingerprint = fill(0xee, 32))
    with_replaced_head(damaged) do chain, path
        e = caught(() -> ChainTables.open(chain, path))
        @test e isa LocalCopyInconsistentError
        detail = "head heads/000000000001 is not self-consistent: its state_fingerprint " *
            "is $("ee"^32)"
        @test startswith(e.detail, detail)
    end
end

@testset "open refuses a head whose name and slot disagree" begin
    with_replaced_head(good -> with_fields(good; slot = 3)) do chain, path
        detail = "head heads/000000000001 is named for slot 1 but says slot 3"
        @test_throws LocalCopyInconsistentError detail ChainTables.open(chain, path)
    end
end

@testset "open refuses a head of a newer layout" begin
    newer = good -> vcat(codeunits("chaintables/v2/head"), good[20:end])
    with_replaced_head(newer) do chain, path
        e = caught(() -> ChainTables.open(chain, path))
        @test e isa LayoutVersionError
        @test e.file == "heads/000000000001"
        @test e.detail == "begins \"chaintables/v2/head\", not \"chaintables/v1/head\""
    end
end

@testset "open refuses a head file that is not ChainTables'" begin
    with_replaced_head(good -> Vector{UInt8}("SQLite format 3\0")) do chain, path
        detail = "head heads/000000000001 is not a ChainTables head file"
        @test_throws NotALocalCopyError detail ChainTables.open(chain, path)
    end
end

@testset "open refuses a copy bound to another chain" begin
    with_chain() do chain, store, dir
        path = joinpath(dir, "copy")
        close(synced_copy(chain, path))
        other = Chain("bkt", "q"; store, cache_dir = joinpath(dir, "cache"))
        create_chain(other)
        close(synced_copy(other, joinpath(dir, "other")))
        e = caught(() -> ChainTables.open(other, path))
        @test e isa WrongChainError
        @test e.bound == decode_head(read(head_file(path, 0))).chain_id
        @test e.bound != e.opened
        close(ChainTables.open(chain, path))
    end
end

@testset "expected_chain_id knows no chain id of a chain that is not a Chain" begin
    @test ChainTables.expected_chain_id(nothing) === nothing
end

@testset "unpin! makes a pinned copy live" begin
    with_chain() do chain, store, dir
        copy = synced_copy(chain, joinpath(dir, "copy"))
        @test_throws ArgumentError "is not pinned; it is live already" unpin!(copy)
        pin!(copy)
        @test is_pinned(copy)
        unpin!(copy)
        @test !is_pinned(copy)
        close(copy)
    end
end

@testset "close drops the cached views and keeps the views taken" begin
    with_chain() do chain, store, dir
        copy = synced_copy(chain, joinpath(dir, "copy"))
        commit_three_tables!(copy)
        v = table(copy, :w)
        close(copy)
        @test isempty(copy.views)
        @test collect(v) == [(id = 7, v = "z")]
    end
end

@testset "local copy functions infer" begin
    with_chain() do chain, store, dir
        copy = @inferred ChainTables.open(chain, joinpath(dir, "copy"))
        @test copy isa LocalCopy
        sync!(copy)
        @test @inferred(head(copy)).slot == 0
        @test @inferred(tables(copy)) == String[]
        @test @inferred(is_pinned(copy)) === false
        @test @inferred(pin!(copy)) === nothing
        @test @inferred(unpin!(copy)) === nothing
        close(copy)
    end
end
