# #34 step 8 — ADR-0024: the read surface. A TableView is a Tables.jl table fixed at the
# head it was taken at, copied out of the model, cached per table per head; head, tables,
# shape, table. Tables.jl is loaded here only to prove the interface: the package itself
# never depends on it (ADR-0022).
using Tables
using ChainTables: Chain, LocalCopy, TableView, TransactionHash, StateFingerprint, Model
using ChainTables.Testing: InMemoryObjectStore

@testset "views" begin
    CT = ChainTables
    caught(f) = try; f(); nothing; catch e; e; end
    function fixture(dir)
        store = InMemoryObjectStore()
        chain = Chain("bkt", "p"; store, cache_dir = joinpath(dir, "cache"), record_host = false, record_user = false)
        CT.create_chain(chain)
        copy = CT.open(chain, joinpath(dir, "one"))
        CT.sync!(copy)
        w = CT.write_builder(copy)
        CT.create_table!(w, :samples) do t
            CT.column!(t, :id, Int64)
            CT.column!(t, :label, String)
            CT.column!(t, :mass, Float64; nullable = true)
            CT.primary_key!(t, :id)
        end
        CT.insert_rows!(w, :samples, [(id = 2, label = "b", mass = missing), (id = 1, label = "a", mass = 1.5)])
        CT.create_table!(w, :pairs) do t
            CT.column!(t, :n, Float64)
            CT.column!(t, :a, Int64)
            CT.column!(t, :b, String)
            CT.primary_key!(t, :a, :b)
        end
        CT.insert_rows!(w, :pairs, [(a = 2, b = "y", n = 0.5), (a = 1, b = "x", n = 0.25), (a = 1, b = "w", n = 0.0)])
        CT.create_table!(w, :blobs) do t
            CT.column!(t, :k, Vector{UInt8})
            CT.column!(t, :v, Vector{UInt8}; nullable = true)
            CT.primary_key!(t, :k)
        end
        CT.insert_rows!(w, :blobs, [(k = UInt8[1, 2], v = UInt8[9]), (k = UInt8[1], v = missing)])
        r = CT.commit!(w)
        return store, chain, copy, r
    end

    # ------------------------------------------------------------------------
    # The view: a Tables.jl table, rows in typed key order, the key lookup, the
    # head it was taken at, and the typed hashes on the surface (ADR-0019).
    # ------------------------------------------------------------------------
    @testset "table, the lookup, Tables.jl" begin
        mktempdir() do dir
            store, chain, copy, r = fixture(dir)
            h = CT.head(copy)
            @test h.transaction_hash isa TransactionHash && h.state_fingerprint isa StateFingerprint
            @test r.transaction_hash isa TransactionHash && r.state_fingerprint isa StateFingerprint
            @test h == (; slot = 1, transaction_hash = r.transaction_hash, state_fingerprint = r.state_fingerprint)
            v = CT.table(copy, :samples)
            @test v isa TableView
            @test (v.name, v.slot, v.chain_id) == ("samples", 1, copy.head.chain_id)
            @test v.transaction_hash == r.transaction_hash && v.transaction_hash isa TransactionHash
            @test length(v) == 2 && keys(v) == [1, 2]                       # key order, not insertion order
            @test isequal(collect(v), [(id = 1, label = "a", mass = 1.5), (id = 2, label = "b", mass = missing)])
            @test eltype(v) == NamedTuple{(:id, :label, :mass),Tuple{Int64,String,Union{Missing,Float64}}}
            @test isequal(v[2], (id = 2, label = "b", mass = missing)) && v[2] isa eltype(v)
            @test v[2].mass === missing                                      # null is missing
            @test isequal(v[(2,)], v[2])                                     # a one-column key as a tuple too
            @test haskey(v, 1) && !haskey(v, 9)
            @test get(v, 9, nothing) === nothing && isequal(get(v, 1, nothing), v[1])
            @test_throws KeyError v[9]
            @test_throws KeyError v[(9,)]
            @test_throws "table \"samples\" has a one-column key (id); a key of 2 cells does not address it" v[(1, 2)]
            # Tables.jl sees a row table with the declared column types
            @test Tables.istable(v)
            @test Tables.columns(v).label == ["a", "b"]
            @test Tables.columntable(v).mass isa Vector{Union{Missing,Float64}}
            @test isequal(Tables.columntable(v), (id = [1, 2], label = ["a", "b"], mass = Union{Missing,Float64}[1.5, missing]))
            @test isequal(Tables.rowtable(v), collect(v))
            @test Tables.schema(Tables.rows(v)).types == (Int64, String, Union{Missing,Float64})
            @test sprint(show, v) == "TableView(:samples at slot 1 of chain $(copy.head.chain_id); 2 rows, columns id, label, mass)"
            # a composite key is a tuple in key declaration order; the bare value is refused
            p = CT.table(copy, :pairs)
            @test keys(p) == [(1, "w"), (1, "x"), (2, "y")]
            @test p[(1, "x")] == (n = 0.25, a = 1, b = "x")                 # columns in declaration order
            @test_throws "table \"pairs\" has a composite key (a, b); look it up as a tuple in key declaration order, got 1" p[1]
            @test_throws KeyError p[(1, "z")]
            @test get(p, (1, "z"), :none) === :none && haskey(p, (2, "y"))
            # bytes: a bytes key, a nullable bytes column; a cell is the view's own copy
            b = CT.table(copy, :blobs)
            @test keys(b) == [UInt8[1], UInt8[1, 2]]
            @test isequal(b[UInt8[1]], (k = UInt8[1], v = missing)) && b[UInt8[1, 2]].v == UInt8[9]
            b[UInt8[1, 2]].v[1] = 0xff
            @test isequal(collect(Model.rows_in_key_order(CT.load_table!(copy, "blobs")))[2], Any[UInt8[1, 2], UInt8[9]])
            @test b[UInt8[1, 2]].v == UInt8[0xff]                            # the view's own value
            # the surface errors
            @test_throws "table(copy, :nope): unknown table \"nope\"" CT.table(copy, :nope)
            @test_throws "table(copy, 1): table name 1 is not a Symbol" CT.table(copy, 1)
            fresh = CT.open(chain, joinpath(dir, "fresh"))
            @test_throws "the local copy at $(fresh.path) has no head yet; sync!(copy) binds it" CT.table(fresh, :samples)
            close(fresh)
            close(copy)
            @test_throws "the local copy at $(copy.path) is closed" CT.table(copy, :samples)
            @test isequal(v[2], (id = 2, label = "b", mass = missing))    # a view outlives its copy
        end
    end

    # ------------------------------------------------------------------------
    # Fixed at its head (ADR-0024): a view taken before sync! or commit! is
    # unchanged after it; cached per table per head, dropped when the head moves.
    # ------------------------------------------------------------------------
    @testset "fixed at its head, cached per head" begin
        mktempdir() do dir
            store, chain, copy, r = fixture(dir)
            v = CT.table(copy, :samples)
            @test CT.table(copy, :samples) === v                              # the same object before the head moves
            @test CT.table(copy, :pairs) !== v
            two = CT.open(chain, joinpath(dir, "two"))
            CT.sync!(two)
            v2 = CT.table(two, :samples)
            @test isequal(collect(v2), collect(v))
            w = CT.write_builder(two)
            CT.update_rows!(w, :samples, [(id = 2, mass = 2.5)])
            r2 = CT.commit!(w)
            @test v2[2].mass === missing && v2.slot == 1                      # a commit! moves the copy, not the view
            v2b = CT.table(two, :samples)
            @test v2b !== v2 && v2b[2].mass == 2.5 && v2b.slot == 2 && v2b.transaction_hash == r2.transaction_hash
            @test CT.sync!(copy).slot == 2
            @test v[2].mass === missing && v.slot == 1                        # a sync! likewise
            vb = CT.table(copy, :samples)
            @test vb !== v && vb[2].mass == 2.5
            @test CT.table(copy, :samples) === vb
            # a failed commit! (the state gate) leaves the head, and the cached view with it
            w = CT.write_builder(copy)
            CT.insert_rows!(w, :samples, [(id = 2, label = "dup", mass = 0.0)])
            @test_throws "insert names a key that is present" CT.commit!(w)
            @test CT.table(copy, :samples) === vb
            # close drops the cache; the views held stay
            close(copy)
            @test isempty(copy.views) && vb[2].mass == 2.5
            close(two)
        end
    end

    # ------------------------------------------------------------------------
    # Mutating a view reaches nothing (ADR-0024): head(copy) and the next
    # commit!'s fingerprint are what a fresh replay computes.
    # ------------------------------------------------------------------------
    @testset "mutating a view damages only the view" begin
        mktempdir() do dir
            store, chain, copy, r = fixture(dir)
            v = CT.table(copy, :samples)
            before = CT.head(copy)
            Tables.columns(v).label[1] = "zzz"
            v.columns.label[2] = "yyy"
            v.columns.mass[1] = 99.0
            @test CT.head(copy) == before
            @test isequal(collect(Model.rows_in_key_order(CT.load_table!(copy, "samples"))), [Any[1, "a", 1.5], Any[2, "b", missing]])
            w = CT.write_builder(copy)
            CT.insert_rows!(w, :samples, [(id = 3, label = "c", mass = 3.0)])
            r2 = CT.commit!(w)
            fresh = CT.open(chain, joinpath(dir, "fresh"))
            @test CT.sync!(fresh).slot == 2
            @test CT.head(fresh) == CT.head(copy) && CT.head(fresh).state_fingerprint == r2.state_fingerprint
            @test CT.table(fresh, :samples)[1].label == "a"
            close(copy); close(fresh)
        end
    end

    # ------------------------------------------------------------------------
    # missing round-trips (ADR-0024, ADR-0025): a row read from a view goes into
    # the write builder with no conversion, and a view's rows are a row set.
    # ------------------------------------------------------------------------
    @testset "a view's rows are a row set" begin
        mktempdir() do dir
            store, chain, copy, r = fixture(dir)
            v = CT.table(copy, :samples)
            w = CT.write_builder(copy)
            CT.update_rows!(w, :samples, [v[2]])                              # the full row, mass = missing, unchanged
            CT.update_rows!(w, :samples, [(id = 1, mass = missing)])
            CT.create_table!(w, :again) do t
                CT.column!(t, :id, Int64)
                CT.column!(t, :label, String)
                CT.column!(t, :mass, Float64; nullable = true)
                CT.primary_key!(t, :id)
            end
            CT.insert_rows!(w, :again, Tables.rows(v))
            CT.commit!(w)
            @test CT.table(copy, :samples)[2].mass === missing && CT.table(copy, :samples)[1].mass === missing
            @test isequal(collect(CT.table(copy, :again)), collect(v))
            close(copy)
        end
    end

    # ------------------------------------------------------------------------
    # shape (ADR-0024, ADR-0025): the declaration, equal to what create_table!
    # plus the column ops carried, in the builder's vocabulary.
    # ------------------------------------------------------------------------
    @testset "shape and tables" begin
        mktempdir() do dir
            store, chain, copy, r = fixture(dir)
            @test CT.tables(copy) == ["blobs", "pairs", "samples"]
            declared = (; columns = [(name = :id, type = Int64, nullable = false), (name = :label, type = String, nullable = false),
                                     (name = :mass, type = Float64, nullable = true)], key = [:id])
            @test CT.shape(copy, :samples) == declared
            @test CT.shape(CT.table(copy, :samples)) == declared
            @test CT.shape(copy, :pairs) == (; columns = [(name = :n, type = Float64, nullable = false), (name = :a, type = Int64, nullable = false),
                                                          (name = :b, type = String, nullable = false)], key = [:a, :b])
            @test CT.shape(copy, :blobs).columns[1] == (name = :k, type = Vector{UInt8}, nullable = false)
            w = CT.write_builder(copy)
            CT.add_column!(w, :samples, :note, String; nullable = true, fill = missing)
            CT.drop_column!(w, :samples, :label)
            CT.commit!(w)
            @test CT.shape(copy, :samples) == (; columns = [(name = :id, type = Int64, nullable = false), (name = :mass, type = Float64, nullable = true),
                                                            (name = :note, type = String, nullable = true)], key = [:id])
            @test isequal(CT.table(copy, :samples)[1], (id = 1, mass = 1.5, note = missing))
            @test_throws "shape(copy, :nope): unknown table \"nope\"" CT.shape(copy, :nope)
            close(copy)
        end
    end
end
