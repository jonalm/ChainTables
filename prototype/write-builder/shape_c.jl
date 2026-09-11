"""
PROTOTYPE — shape C: a macro DSL.

The one shape that can inspect the *source* of a write rather than only its
values, so it is the only one that can reject `rand()` at all. See
`forbidden_call_demo` in run.jl for how much that is actually worth.
"""
module ShapeC

using ..Ops
using SQLite

export @record

# Calls whose result differs between two clients, or between two runs on one
# client. Lexical, therefore trivially defeated by one level of indirection —
# which is the point being tested.
const FORBIDDEN = Set([
    :rand, :randn, :randstring, :shuffle,
    :now, :today, :time, :time_ns,
    :uuid1, :uuid4, :gensym, :objectid, :hash, :pointer,
    :getpid, :gethostname, :tempname, :read, :readline, :readlines,
])

function scan_forbidden(ex)
    ex isa Expr || return nothing
    if ex.head === :call
        f = ex.args[1]
        nm = f isa Symbol ? f :
             (Meta.isexpr(f, :.) && f.args[2] isa QuoteNode ? f.args[2].value : nothing)
        nm in FORBIDDEN && error(
            "@record refuses $nm(...): its value differs between clients or between runs, " *
            "so the record would not describe a reproducible write")
    end
    foreach(scan_forbidden, ex.args)
    return nothing
end

function column_expr(ex, notnull::Bool)
    decl, default = ex, nothing
    if Meta.isexpr(ex, :(=))
        decl, default = ex.args[1], ex.args[2]
    end
    Meta.isexpr(decl, :(::)) || error("a column is written name::TYPE, got: $decl")
    nm, ty = QuoteNode(decl.args[1]), QuoteNode(decl.args[2])
    return default === nothing ?
           :(Column($nm, $ty; notnull = $notnull)) :
           :(Column($nm, $ty; notnull = $notnull, default = $(esc(default))))
end

function transform_column!(cols, pk, c)
    if Meta.isexpr(c, :macrocall)
        n = c.args[1]
        if n === Symbol("@required")
            push!(cols, column_expr(c.args[3], true))
        elseif n === Symbol("@primary_key")
            for k in c.args[3:end]
                push!(pk, QuoteNode(k))
            end
        else
            error("unknown column directive $n")
        end
    else
        push!(cols, column_expr(c, false))
    end
    return nothing
end

function transform_op(ex)
    Meta.isexpr(ex, :macrocall) || error("expected an op, got: $ex")
    name = ex.args[1]
    a = ex.args[3:end]
    if name === Symbol("@create_table")
        cols, pk = Any[], Any[]
        for c in a[2].args
            c isa LineNumberNode && continue
            transform_column!(cols, pk, c)
        end
        return :(CreateTable($(QuoteNode(a[1])), Column[$(cols...)]; primary_key = Symbol[$(pk...)]))
    elseif name === Symbol("@add_column")
        return :(AddColumn($(QuoteNode(a[1])), $(column_expr(a[2], false))))
    elseif name === Symbol("@insert")
        return :(Insert($(QuoteNode(a[1])), $(esc(a[2]))))
    elseif name === Symbol("@delete")
        return :(Delete($(QuoteNode(a[1])), $(esc(a[2]))))
    elseif name === Symbol("@update")
        ks = Meta.isexpr(a[2], :tuple) ? a[2].args : [a[2]]
        return :(Update($(QuoteNode(a[1])), $(esc(a[3])); by = Symbol[$(map(QuoteNode, ks)...)]))
    else
        error("unknown op $name")
    end
end

macro record(body)
    Meta.isexpr(body, :block) || error("@record takes a begin ... end block")
    scan_forbidden(body)
    txs = Any[]
    for ex in body.args
        ex isa LineNumberNode && continue
        (Meta.isexpr(ex, :macrocall) && ex.args[1] === Symbol("@transaction")) ||
            error("@record may only contain @transaction blocks, got: $ex")
        ops = Any[transform_op(o) for o in ex.args[4].args if !(o isa LineNumberNode)]
        push!(txs, :(Transaction($(esc(ex.args[3])), Op[$(ops...)])))
    end
    return :(Record(Transaction[$(txs...)]))
end

record_one() = @record begin
    @transaction "create the sample schema" begin
        @create_table sample begin
            @required id::INTEGER
            @required label::TEXT
            collected_on::TEXT
            note::TEXT
            @primary_key id
        end
        @create_table measurement begin
            @required sample_id::INTEGER
            @required metric::TEXT
            value::REAL
            raw::BLOB
            @primary_key sample_id metric
        end
    end

    @transaction "load the january batch" begin
        @insert sample [
            (id = 1, label = "AX-1", collected_on = "2026-01-04", note = "duplicate run"),
            (id = 2, label = "AX-2", collected_on = "2026-01-04", note = nothing),
            (id = 3, label = "BX-7", collected_on = "2026-01-11", note = nothing),
        ]
        @insert measurement [
            (sample_id = 1, metric = "ph", value = 7.21, raw = nothing),
            (sample_id = 1, metric = "od600", value = 145.0, raw = UInt8[0xde, 0xad, 0xbe, 0xef]),
            (sample_id = 2, metric = "od600", value = 220.5, raw = nothing),
            (sample_id = 2, metric = "ph", value = 6.98, raw = nothing),
            (sample_id = 3, metric = "ph", value = nothing, raw = nothing),
        ]
    end
end

# The query cannot happen inside @record — the DSL has no place to put ordinary
# Julia — so the row set is computed first and spliced in as a variable.
function record_two(db)
    doomed = [(sample_id = r.sample_id, metric = r.metric) for r in DBInterface.execute(db,
        "SELECT sample_id, metric FROM measurement WHERE value > 100 ORDER BY sample_id, metric")]
    retired = [(id = i, note = "reading retired 2026-01-20") for i in unique(d.sample_id for d in doomed)]

    return @record begin
        @transaction "add the provenance column" begin
            @add_column sample instrument::TEXT
        end
        @transaction "retire the out-of-range readings" begin
            @delete measurement doomed
            @update sample (id,) retired
        end
    end
end


end # module ShapeC
