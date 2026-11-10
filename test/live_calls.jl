# The live suite (test/live/, ADR-0030) is never loaded by this one, so a change to an internal
# it calls went unnoticed until a live run: aafd425 gave `upload_minted` a `size` argument and
# test/live/attachments.jl kept calling it without (#92). This reads every `GWT.f(...)` call in
# test/live/*.jl and checks that `ChainTables.f` exists and has a method that takes that many
# positional arguments and those keyword names. Argument types are not checked.

# The calls `GWT.f(args...; kws...)` in `ex`, as (name, positional count or nothing when a call
# splats, keyword names, line).
function live_gwt_calls(ex, line = 0, found = Tuple{Symbol,Union{Int,Nothing},Vector{Symbol},Int}[]; extra = 0)
    ex isa LineNumberNode && return found
    ex isa Expr || return found
    if ex.head === :do  # `GWT.f(x) do t … end` is GWT.f(function, x)
        live_gwt_calls(ex.args[1], line, found; extra = 1)
        return live_gwt_calls(ex.args[2], line, found)
    end
    if ex.head === :call && ex.args[1] isa Expr && ex.args[1].head === :. && ex.args[1].args[1] === :GWT
        name = ex.args[1].args[2].value
        positional, keywords = fill(1, extra), Symbol[]
        splats = false
        for a in ex.args[2:end]
            if a isa Expr && a.head === :parameters
                for p in a.args
                    p isa Expr && p.head === :... ? (splats = true) :
                        push!(keywords, p isa Symbol ? p : p.args[1])  # `k`, `k = v`
                end
            elseif a isa Expr && a.head === :kw
                push!(keywords, a.args[1])
            elseif a isa Expr && a.head === :...
                splats = true
            else
                push!(positional, 1)
            end
        end
        push!(found, (name, splats ? nothing : length(positional), keywords, line))
    end
    for a in ex.args
        a isa LineNumberNode && (line = a.line)
        live_gwt_calls(a, line, found)
    end
    return found
end

function accepts(f, n, keywords)
    any(methods(f)) do m
        nargs = m.nargs - 1
        fits = n === nothing || (m.isva ? n >= nargs - 1 : n == nargs)
        declared = Base.kwarg_decl(m)
        fits && (any(endswith("..."), string.(declared)) || keywords ⊆ declared)
    end
end

@testset "the live suite's calls into ChainTables resolve" begin
    files = filter(endswith(".jl"), readdir(joinpath(@__DIR__, "live"); join = true))
    calls = 0
    for file in files
        for (name, n, keywords, line) in live_gwt_calls(Meta.parseall(read(file, String); filename = file))
            calls += 1
            where = "$(basename(file)):$line GWT.$name"
            @test (where, isdefined(ChainTables, name)) == (where, true)
            isdefined(ChainTables, name) || continue
            f = getfield(ChainTables, name)
            f isa Function || continue  # a constructor call, e.g. GWT.Ops(...): a type
            @test (where, n, keywords, accepts(f, n, keywords)) == (where, n, keywords, true)
        end
    end
    @test calls > 50  # the walk finds the calls at all
end
