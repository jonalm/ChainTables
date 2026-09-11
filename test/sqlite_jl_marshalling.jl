# ---------------------------------------------------------------------------
# Characterization tests for SQLite.jl's value marshalling.
#
# These pin behaviour of the *dependency*, not of S3SQLite — there is nothing
# of ours to test yet. They exist because the design depends on two facts that
# are nowhere in SQLite.jl's documentation and would change silently:
#
#   1. SQLite.jl's row API is not byte-faithful for BLOBs. It runs every BLOB
#      whose first 18 bytes match a Julia serialization header through
#      `Serialization.deserialize`, so bytes come back as a decoded object, or
#      as a thrown `SQLite.SerializeError`. Reading through
#      `sqlite3_column_blob` is byte-faithful; that is why ADR-0007 mandates
#      the C API for the state fingerprint, and why every internal read of the
#      local copy must take the same path.
#
#   2. Binding a value is not type-preserving either: an integer that is not
#      `Int32`/`Int64`/`Bool` is silently stored as a serialized BLOB, and a
#      `Float64` bound into a `TEXT` column of a `STRICT` table is rendered to
#      text by SQLite itself — `vdbeMemRenderNum`, the one path ADR-0017
#      forbids, reached with no SQL text and no `CAST`.
#
# If any of these start failing, the dependency's behaviour changed and the
# decisions resting on it (#21) must be re-examined — a failure here is news,
# not a bug.
# ---------------------------------------------------------------------------

using SQLite
using Serialization
const DBI = SQLite.DBInterface
const C = SQLite.C

"Read column `col` (0-based) of every row of `sql`, byte-faithfully."
function raw_column(db::SQLite.DB, sql::AbstractString, col::Int = 0)
    stmt = SQLite.Stmt(db, sql)
    h = SQLite._get_stmt_handle(stmt)
    out = Any[]
    try
        while C.sqlite3_step(h) == C.SQLITE_ROW
            t = C.sqlite3_column_type(h, col)
            if t == C.SQLITE_INTEGER
                push!(out, C.sqlite3_column_int64(h, col))
            elseif t == C.SQLITE_FLOAT
                push!(out, C.sqlite3_column_double(h, col))
            elseif t == C.SQLITE_TEXT
                p = C.sqlite3_column_text(h, col)
                n = C.sqlite3_column_bytes(h, col)
                push!(out, unsafe_string(Ptr{UInt8}(p), n))
            elseif t == C.SQLITE_BLOB
                p = C.sqlite3_column_blob(h, col)
                n = C.sqlite3_column_bytes(h, col)
                b = Vector{UInt8}(undef, n)
                n > 0 && unsafe_copyto!(pointer(b), Ptr{UInt8}(p), n)
                push!(out, b)
            else
                push!(out, missing)
            end
        end
    finally
        SQLite.finalize(stmt)
    end
    return out
end

row_api_column(db, sql, name::Symbol) = [r[name] for r in DBI.execute(db, sql)]

@testset "SQLite.jl marshalling" begin

    @testset "BLOB reads are not byte-faithful through the row API" begin
        db = SQLite.DB()
        DBI.execute(
            db,
            "CREATE TABLE t(k INTEGER PRIMARY KEY NOT NULL, b BLOB NOT NULL) STRICT, WITHOUT ROWID",
        )

        # Bytes SQLite.jl itself writes when it hits its serializing fallback,
        # and which a chain may legitimately carry as opaque BLOB content.
        decodable = SQLite.sqlserialize([1, 2, 3])
        # Bytes that merely start with the same 18-byte prefix.
        undecodable = vcat(SQLite.SERIALIZATION, fill(0xAB, 16))
        # Bytes an ordinary `Serialization.serialize` writes: these do *not*
        # match, because SQLite.jl's marker includes its own wrapper type.
        plain = let io = IOBuffer()
            serialize(io, [1, 2, 3])
            take!(io)
        end

        for (k, b) in enumerate((decodable, undecodable, plain))
            DBI.execute(db, "INSERT INTO t VALUES(?,?)", (k, b))
        end

        # The hazard, in both its forms.
        @test row_api_column(db, "SELECT b FROM t WHERE k = 1", :b)[1] == [1, 2, 3]
        @test_throws SQLite.SerializeError row_api_column(
            db, "SELECT b FROM t WHERE k = 2", :b,
        )
        @test_throws "Error deserializing non-primitive value" row_api_column(
            db, "SELECT b FROM t WHERE k = 2", :b,
        )
        # ...and its limit: an ordinary serialization is not affected.
        @test row_api_column(db, "SELECT b FROM t WHERE k = 3", :b)[1] == plain

        # The case nothing downstream can catch: right Julia type, wrong bytes,
        # in a column still declared BLOB. ADR-0005's schema-aware type check
        # convicts a BLOB that decodes to a String or an Int64; it cannot
        # convict one that decodes to a shorter Vector{UInt8}.
        DBI.execute(db, "INSERT INTO t VALUES(?,?)", (4, SQLite.sqlserialize(UInt8[9, 9])))
        @test row_api_column(db, "SELECT b FROM t WHERE k = 4", :b)[1] == UInt8[9, 9]
        @test raw_column(db, "SELECT b FROM t WHERE k = 4")[1] ==
              SQLite.sqlserialize(UInt8[9, 9])

        # Neither knob helps.
        @test [r[:b] for r in DBI.execute(db, "SELECT b FROM t WHERE k = 1"; strict = true)][1] ==
              [1, 2, 3]

        # The C API is byte-faithful for all four. This is the fix.
        @test raw_column(db, "SELECT b FROM t ORDER BY k") ==
              [decodable, undecodable, plain, SQLite.sqlserialize(UInt8[9, 9])]
    end

    @testset "binds are not type-preserving" begin
        db = SQLite.DB()
        DBI.execute(
            db,
            "CREATE TABLE w(k INTEGER PRIMARY KEY NOT NULL, v ANY) STRICT, WITHOUT ROWID",
        )
        stored(k, v) = begin
            DBI.execute(db, "INSERT INTO w VALUES(?,?)", (k, v))
            row_api_column(db, "SELECT typeof(v) AS t FROM w WHERE k = $k", :t)[1]
        end

        # The four storage classes S3SQLite admits, reached by exactly four
        # Julia types.
        @test stored(1, Int64(7)) == "integer"
        @test stored(2, Float64(1.5)) == "real"
        @test stored(3, "s") == "text"
        @test stored(4, UInt8[0x01, 0x02]) == "blob"

        # Everything else lands in the serializing fallback without a word.
        @test stored(5, Int16(7)) == "blob"
        @test stored(6, UInt8(7)) == "blob"
        @test stored(7, Int128(7)) == "blob"
        @test stored(8, :sym) == "blob"
    end

    @testset "STRICT renders a bound Float64 into a TEXT column" begin
        db = SQLite.DB()
        DBI.execute(
            db,
            "CREATE TABLE s(k INTEGER PRIMARY KEY NOT NULL, x TEXT NOT NULL) STRICT, WITHOUT ROWID",
        )
        DBI.execute(db, "INSERT INTO s VALUES(?,?)", (1, 0.1 + 0.2))

        # Not refused, and not stored as a REAL: SQLite rendered the number to
        # text on the way in. The digits are version-dependent (3.51 and 3.53
        # disagree), so this is ADR-0017's forbidden path reached by a bind
        # alone — the builder's own type check, not STRICT, is what closes it.
        @test row_api_column(db, "SELECT typeof(x) AS t FROM s", :t)[1] == "text"
        @test raw_column(db, "SELECT x FROM s")[1] isa String
    end
end
