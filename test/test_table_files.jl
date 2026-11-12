using Test
using ChainTables: ChainTables, Chain, FingerprintMismatchError, Head, WriteBuilderError,
    LocalCopyInconsistentError, StateFingerprint, chain_id_bytes, checkpoint!, column!,
    commit!, create_chain, create_table!, decode_head, delete_rows!, drop_table!,
    encode_head, head, insert_rows!, load_tables!, primary_key!, state_fingerprint, sync!,
    table, tables, write_builder
using ChainTables.Testing: InMemoryObjectStore
using SHA: sha256

function with_chain(f)
    return mktempdir() do dir
        store = InMemoryObjectStore()
        chain = Chain("bkt", "p"; store, cache_dir = joinpath(dir, "cache"))
        create_chain(chain)
        f(chain, dir)
    end
end

function declare!(w, name)
    create_table!(w, name) do t
        column!(t, :id, Int64)
        column!(t, :v, String; nullable = true)
        primary_key!(t, :id)
    end
    return nothing
end

function committed(f, copy)
    w = write_builder(copy)
    f(w)
    commit!(w)
    return nothing
end

# A copy at slot 1: tables t and u with the same rows, so one shared file, and w.
function with_three_tables(f)
    return with_chain() do chain, dir
        path = joinpath(dir, "copy")
        copy = ChainTables.open(chain, path)
        sync!(copy)
        committed(copy) do w
            foreach(name -> declare!(w, name), (:t, :u, :w))
            insert_rows!(w, :t, [(id = 1, v = "a"), (id = 2, v = missing)])
            insert_rows!(w, :u, [(id = 1, v = "a"), (id = 2, v = missing)])
            insert_rows!(w, :w, [(id = 7, v = "z")])
        end
        try
            f(chain, copy, path)
        finally
            close(copy)
        end
    end
end

listing(path, sub) = sort(readdir(joinpath(path, sub)))
head_file(path, slot) = joinpath(path, "heads", lpad(string(slot), 12, '0'))
read_head(path, slot) = decode_head(read(head_file(path, slot)))

function caught(f)
    try
        f()
    catch e
        return e
    end
    return nothing
end

# The slot-1 head file rewritten to name `entries`, its fingerprint recomputed.
function write_head_naming!(path, entries)
    h = read_head(path, 1)
    forged = Head(
        h.chain_id, h.format_version, h.slot, h.transaction_hash,
        state_fingerprint(entries), entries, h.written_at_ms, h.written_by,
    )
    write(head_file(path, 1), encode_head(forged))
    return nothing
end

@testset "a table file is named by the SHA-256 of its bytes" begin
    with_three_tables() do chain, copy, path
        files = listing(path, "tables")
        @test length(files) == 2
        @testset "$f" for f in files
            @test bytes2hex(sha256(read(joinpath(path, "tables", f)))) == f
        end
        h = read_head(path, 1)
        @test first.(h.tables) == ["t", "u", "w"]
        @test last(h.tables[1]) == last(h.tables[2])
        @test Set(bytes2hex.(last.(h.tables))) == Set(files)
        @test StateFingerprint(h.state_fingerprint) == head(copy).state_fingerprint
    end
end

@testset "a table with no rows has a table file" begin
    with_three_tables() do chain, copy, path
        committed(w -> declare!(w, :empty), copy)
        @test length(listing(path, "tables")) == 3
        @test tables(copy) == ["empty", "t", "u", "w"]
    end
end

@testset "a damaged table file throws at first read, not at open" begin
    with_three_tables() do chain, copy, path
        close(copy)
        f = bytes2hex(last(read_head(path, 1).tables[3]))
        bad = read(joinpath(path, "tables", f))
        bad[end] ⊻= 0x01
        write(joinpath(path, "tables", f), bad)
        damaged = ChainTables.open(chain, path)
        @test tables(damaged) == ["t", "u", "w"]
        e = caught(() -> table(damaged, :w))
        @test e isa LocalCopyInconsistentError
        @test e.file == "tables/$f"
        @test e.slot == 1
        @test e.table == "w"
        @test e.detail == "hashes to $(bytes2hex(sha256(bad)))"
        @test occursin("repair!(copy)", sprint(showerror, e))
        @test isempty(damaged.content)
        close(damaged)
    end
end

@testset "a table file the head names but that is missing throws at open" begin
    with_three_tables() do chain, copy, path
        close(copy)
        f = bytes2hex(last(read_head(path, 1).tables[3]))
        rm(joinpath(path, "tables", f))
        detail = "names table file tables/$f (table \"w\"), which is missing"
        @test_throws LocalCopyInconsistentError detail ChainTables.open(chain, path)
    end
end

@testset "a row slot above the head's slot is a damaged copy" begin
    with_three_tables() do chain, copy, path
        slot_one = read(head_file(path, 1))
        committed(w -> insert_rows!(w, :w, [(id = 8, v = "y")]), copy)
        slot_two_w = last(read_head(path, 2).tables[3])
        close(copy)
        rm(head_file(path, 2))
        write(head_file(path, 1), slot_one)
        write_head_naming!(path, ["w" => slot_two_w])
        again = ChainTables.open(chain, path)
        detail = "holds a row slot 2, above the head's slot 1"
        @test_throws LocalCopyInconsistentError detail table(again, :w)
        @test isempty(again.content)
        close(again)
    end
end

@testset "a table file that is no canonical table file is a damaged copy" begin
    with_three_tables() do chain, copy, path
        close(copy)
        junk = Vector{UInt8}("not a table")
        write(joinpath(path, "tables", bytes2hex(sha256(junk))), junk)
        write_head_naming!(path, ["t" => sha256(junk)])
        again = ChainTables.open(chain, path)
        detail = "hashes to its name but is not a canonical table file"
        @test_throws LocalCopyInconsistentError detail table(again, :t)
        close(again)
    end
end

@testset "load_tables! loads the head's tables among the names, and skips others" begin
    with_three_tables() do chain, copy, path
        close(copy)
        again = ChainTables.open(chain, path)
        @test isempty(again.content)
        load_tables!(again, ["t", "nope"])
        @test collect(keys(again.content)) == ["t"]
        close(again)
    end
end

@testset "checkpoint! refuses a fingerprint mismatch and keeps the head" begin
    with_three_tables() do chain, copy, path
        before = (listing(path, "heads"), listing(path, "tables"), head(copy))
        chain_id = chain_id_bytes(read_head(path, 1).chain_id)
        wrong = fill(0xdd, 32)
        client = (lib = "ChainTables 9.9.9", julia = "1.99.0")
        table(copy, :w)
        e = caught(() -> checkpoint!(copy, chain_id, 2, fill(0x02, 32), wrong; client))
        @test e isa FingerprintMismatchError
        @test e.slot == 2
        @test e.expected == StateFingerprint(wrong)
        @test e.record_client == client
        @test e.detail == "the local copy stays at slot 1"
        @test (listing(path, "heads"), listing(path, "tables"), head(copy)) == before
        @test isempty(copy.content)
        @test collect(table(copy, :w)) == [(id = 7, v = "z")]
    end
end

@testset "checkpoint! refuses a slot that does not advance and another chain" begin
    with_three_tables() do chain, copy, path
        h = read_head(path, 1)
        chain_id = chain_id_bytes(h.chain_id)
        fp, txn = h.state_fingerprint, fill(0x01, 32)
        not_above = "slot 1 is not above the head's slot 1"
        @test_throws ArgumentError not_above checkpoint!(copy, chain_id, 1, txn, fp)
        other = "is bound to chain $(h.chain_id)"
        @test_throws ArgumentError other checkpoint!(copy, fill(0x11, 16), 2, txn, fp)
    end
end

@testset "a refused commit leaves the head and its files" begin
    with_three_tables() do chain, copy, path
        before = (listing(path, "heads"), listing(path, "tables"), head(copy))
        w = write_builder(copy)
        insert_rows!(w, :w, [(id = 8, v = "y")])
        delete_rows!(w, :t, [(id = 9,)])
        @test_throws WriteBuilderError "absent" commit!(w)
        @test (listing(path, "heads"), listing(path, "tables"), head(copy)) == before
    end
end

@testset "a commit keeps an untouched table's hash without reading its file" begin
    with_three_tables() do chain, copy, path
        close(copy)
        t_file = joinpath(path, "tables", bytes2hex(last(read_head(path, 1).tables[1])))
        good = read(t_file)
        write(t_file, reverse(good))
        again = ChainTables.open(chain, path)
        committed(w -> insert_rows!(w, :w, [(id = 9, v = "x")]), again)
        @test last(read_head(path, 2).tables[1]) == last(read_head(path, 2).tables[2])
        write(t_file, good)
        @test length(table(again, :t)) == 2
        close(again)
    end
end

@testset "a commit drops a dropped table from the head and adds a created one" begin
    with_three_tables() do chain, copy, path
        committed(copy) do w
            drop_table!(w, :u)
            declare!(w, :new)
        end
        @test first.(read_head(path, 2).tables) == ["new", "t", "w"]
        @test tables(copy) == ["new", "t", "w"]
    end
end
