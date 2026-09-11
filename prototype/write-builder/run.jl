"""
PROTOTYPE — throwaway. Issue #7: what should the write-builder API feel like?

Run it:

    julia --project prototype/write-builder/run.jl

It builds the *same* two records three ways (shape A: plain functions; shape B:
do-blocks; shape C: a macro DSL), checks all three produce identical op data,
prints the ops as data and the SQL they render to, and then pushes the guard at
the places it is supposed to break.
"""

using SQLite
using Dates

include(joinpath(@__DIR__, "ops.jl"))
using .Ops
include(joinpath(@__DIR__, "shape_a.jl"))
include(joinpath(@__DIR__, "shape_b.jl"))
include(joinpath(@__DIR__, "shape_c.jl"))

# ---------------------------------------------------------------------------

fresh_db() = SQLite.DB()

"Apply record 1 to a fresh in-memory database, so record 2 has local state to query."
function seeded_db(shape)
    db = fresh_db()
    Ops.apply!(db, shape.record_one())
    return db
end

function header(io, title)
    println(io)
    println(io, "=" ^ 78)
    println(io, title)
    println(io, "=" ^ 78)
    println(io)
end

function attempt(io, title, f)
    print(io, "  ", rpad(title, 46), " → ")
    try
        f()
        println(io, "ACCEPTED")
    catch err
        msg = sprint(showerror, err)
        msg = replace(first(split(msg, "\nStacktrace")), "\n" => " ")
        println(io, length(msg) > 400 ? msg[1:400] * "…" : msg)
    end
    return nothing
end

# Deferred so the macro expands at run time, not while this file loads.
const MACRO_WITH_RAND = quote
    ShapeC.@record begin
        @transaction "oops" begin
            @insert measurement (sample_id = 9, metric = "ph", value = rand())
        end
    end
end

noise() = rand()

const MACRO_WITH_LAUNDERED_RAND = quote
    ShapeC.@record begin
        @transaction "oops" begin
            @insert measurement (sample_id = 9, metric = "ph", value = noise())
        end
    end
end

# ---------------------------------------------------------------------------

function report()
    io = IOBuffer()

    header(io, "THE QUESTION (issue #7)")
    println(io, """
    The builder is the determinism guarantee. Three spellings of the same two
    records are in shape_a.jl (plain functions + NamedTuples), shape_b.jl
    (do-blocks) and shape_c.jl (a macro DSL). Read those three files side by
    side — that is the actual artifact. This output is the evidence that they
    are the same thing underneath, and the record of where the guard holds and
    where it does not.""")

    # ---------------------------------------------------------------- agreement
    header(io, "1. DO THE THREE SHAPES AGREE?")
    a1, b1, c1 = ShapeA.record_one(), ShapeB.record_one(), ShapeC.record_one()
    println(io, "  record 1   A == B: ", to_data(a1) == to_data(b1),
        "   A == C: ", to_data(a1) == to_data(c1))
    a2 = ShapeA.record_two(seeded_db(ShapeA))
    b2 = ShapeB.record_two(seeded_db(ShapeB))
    c2 = ShapeC.record_two(seeded_db(ShapeC))
    println(io, "  record 2   A == B: ", to_data(a2) == to_data(b2),
        "   A == C: ", to_data(a2) == to_data(c2))
    println(io, """
      So the shape is purely a front-end question: the same bytes come out
      either way, and the choice can be made on how the source reads.""")

    # -------------------------------------------------------------- ops as data
    header(io, "2. THE OPS AS DATA  (record 1 — what would go to the CBOR encoder)")
    print(io, format_data(to_data(a1)))

    header(io, "3. THE OPS AS DATA  (record 2 — predicate evaluated locally, row set materialized)")
    print(io, format_data(to_data(a2)))
    println(io, """
      Note what is NOT in there: `value > 100`. The record carries the two rows
      that matched on this client at this head, not the question that found
      them.""")

    # --------------------------------------------------------------------- SQL
    header(io, "4. WHAT EACH OP RENDERS TO LOCALLY")
    for rec in (a1, a2), tx in rec.transactions, op in tx.ops
        println(io, "  ", sql(op))
    end
    println(io, """
      Values are always bound parameters, never interpolated, and identifiers
      are never quoted — with SQLITE_DQS=3 compiled in (#18) a quoted identifier
      that fails to resolve silently becomes a string literal.""")

    # ------------------------------------------------------------ value guard
    header(io, "5. WHERE THE VALUE GUARD BITES")
    attempt(io, "a Bool", () -> Insert(:measurement, (sample_id = 1, metric = "x", value = true, raw = nothing)))
    attempt(io, "a DateTime", () -> Insert(:sample, (id = 4, label = "Z", collected_on = DateTime(2026, 1, 4), note = nothing)))
    attempt(io, "NaN", () -> Insert(:measurement, (sample_id = 1, metric = "x", value = NaN, raw = nothing)))
    attempt(io, "TEXT containing U+0000", () -> Insert(:sample, (id = 4, label = "a\0b", collected_on = nothing, note = nothing)))
    attempt(io, "a column named \"order\"", () -> Insert(:sample, (order = 1,)))
    attempt(io, "a column named \"drop table\"", () -> Insert(:sample, (; Symbol("drop table") => 1)))
    attempt(io, "a table with no PRIMARY KEY", () -> CreateTable(:x, [(name = :a, type = :INTEGER)]; primary_key = Symbol[]))
    attempt(io, "ADD COLUMN NOT NULL, no default", () -> AddColumn(:sample, (name = :site, type = :TEXT, notnull = true)))
    attempt(io, "rows naming different columns", () -> Insert(:sample, [(id = 1, label = "a"), (label = "b", id = 2)]))
    attempt(io, "rand() — plain function shape", () -> Insert(:measurement, (sample_id = 9, metric = "ph", value = rand(), raw = nothing)))
    attempt(io, "rand() — macro shape", () -> Core.eval(Main, MACRO_WITH_RAND))
    attempt(io, "noise() = rand() — macro shape", () -> Core.eval(Main, MACRO_WITH_LAUNDERED_RAND))
    println(io, """
      The last three are the finding. Value-level validation cannot see a
      non-deterministic *source*, because rand() returns a perfectly canonical
      Float64. Only the macro can — and only until someone wraps it in a
      function, which is one keystroke away and is also what any real caller
      does, since the row sets come from a query in the first place.""")

    # ------------------------------------------------- local state disagreement
    header(io, "6. WHEN THE RECORD DISAGREES WITH LOCAL STATE")
    db = seeded_db(ShapeA)
    stale = Record([Transaction("delete a row that isn't there",
        Op[Delete(:measurement, (sample_id = 7, metric = "ph"))])])
    attempt(io, "DELETE of a row not present", () -> Ops.apply!(db, stale))
    println(io, """
      Matching zero rows is an error, not a no-op: the caller materialized a row
      set that this database does not have, so the two clients do not agree about
      what the record means.""")

    # ------------------------------------------- invalid tx inside a good record
    header(io, "7. ONE BAD TRANSACTION IN A RECORD OF SEVERAL")
    db = seeded_db(ShapeA)
    before = length(collect(DBInterface.execute(db, "SELECT id FROM sample")))
    bad = Record([
        Transaction("this one is fine", Op[Insert(:sample,
            (id = 4, label = "CX-1", collected_on = "2026-02-01", note = nothing))]),
        Transaction("this one duplicates a key", Op[Insert(:sample,
            (id = 1, label = "clash", collected_on = nothing, note = nothing))]),
    ])
    attempt(io, "record with a losing second transaction", () -> Ops.apply!(db, bad))
    after = length(collect(DBInterface.execute(db, "SELECT id FROM sample")))
    println(io, "  sample rows before: $before   after: $after")
    println(io, """
      The record is the atom: transaction 1 is discarded with transaction 2, and
      nothing is uploaded. Which raises the open question — if a record is
      atomic anyway, what is a transaction inside it FOR? Right now it is a
      label and nothing else.""")

    return String(take!(io))
end

if abspath(PROGRAM_FILE) == @__FILE__
    print(report())
end
