# The live suite (test/live/, ADR-0030) never runs under `Pkg.test`, so a change to an
# internal it calls went unnoticed until a live run (#92). This reads every
# `ChainTables.f(…)` call in test/live/*.jl and checks that `ChainTables.f` exists and
# has a method that takes that many positional arguments and those keyword names.
# Argument types are not checked.
using Test
using ChainTables: ChainTables

const LIVE_DIR = joinpath(@__DIR__, "live")

# One `ChainTables.f(…)` call: its name, its positional count (`nothing` when it
# splats), its keyword names, and where it is.
struct LiveCall
    name::Symbol
    n_positional::Union{Nothing, Int}
    keywords::Vector{Symbol}
    file::String
    line::Int
end

is_chaintables_call(ex) = ex.head === :call && is_chaintables_name(ex.args[1])
is_chaintables_name(f) = f isa Expr && f.head === :. && f.args[1] === :ChainTables
is_splat(a) = a isa Expr && a.head === :...
is_parameters(a) = a isa Expr && a.head === :parameters
is_keyword(a) = a isa Expr && a.head === :kw

# `k` or `k = v` inside `;`.
parameter_name(p) = p isa Symbol ? p : p.args[1]

function parameter_names(args)
    blocks = filter(is_parameters, args)
    return [parameter_name(p) for b in blocks for p in b.args if !is_splat(p)]
end

function splats_parameters(args)
    blocks = filter(is_parameters, args)
    return any(b -> any(is_splat, b.args), blocks)
end

# `ChainTables.f(x) do t … end` is `ChainTables.f(function, x)`: `extra` counts the
# function.
function live_call(ex, file, line; extra = 0)
    args = ex.args[2:end]
    positional = filter(a -> !is_parameters(a) && !is_keyword(a) && !is_splat(a), args)
    splats = any(is_splat, args) || splats_parameters(args)
    keywords = vcat(parameter_names(args), [a.args[1] for a in args if is_keyword(a)])
    n_positional = splats ? nothing : length(positional) + extra
    return LiveCall(ex.args[1].args[2].value, n_positional, keywords, file, line)
end

# Every call in `ex`, depth first; `line` is the last line number seen.
function live_calls!(found, ex, file, line)
    ex isa Expr || return found
    if ex.head === :do
        call = ex.args[1]
        is_chaintables_call(call) && push!(found, live_call(call, file, line; extra = 1))
        foreach(a -> live_calls!(found, a, file, line), ex.args[1].args)
        return live_calls!(found, ex.args[2], file, line)
    end
    is_chaintables_call(ex) && push!(found, live_call(ex, file, line))
    for a in ex.args
        if a isa LineNumberNode
            line = a.line
        else
            live_calls!(found, a, file, line)
        end
    end
    return found
end

function live_calls_in(file)
    ex = Meta.parseall(read(file, String); filename = file)
    return live_calls!(LiveCall[], ex, basename(file), 0)
end

const LIVE_FILES = filter(endswith(".jl"), readdir(LIVE_DIR; join = true))
const LIVE_CALLS = reduce(vcat, map(live_calls_in, LIVE_FILES))

function takes_positional(m, n)
    n === nothing && return true
    n_arguments = m.nargs - 1
    return m.isva ? n >= n_arguments - 1 : n == n_arguments
end

function takes_keywords(m, keywords)
    declared = Base.kwarg_decl(m)
    return any(endswith("..."), string.(declared)) || keywords ⊆ declared
end

function is_accepted(m, call)
    return takes_positional(m, call.n_positional) && takes_keywords(m, call.keywords)
end

accepts(f, call) = any(m -> is_accepted(m, call), methods(f))

where_called(call) = "$(call.file):$(call.line) ChainTables.$(call.name)"

# A constructor call names a type; only a function's methods are checked.
is_function_name(call) = getfield(ChainTables, call.name) isa Function

@testset "live_calls_in finds the live suite's calls" begin
    @test length(LIVE_CALLS) > 50
end

@testset "live suite calls a defined name: $(where_called(call))" for call in LIVE_CALLS
    @test isdefined(ChainTables, call.name)
end

is_function_call(call) = isdefined(ChainTables, call.name) && is_function_name(call)

const FUNCTION_CALLS = filter(is_function_call, LIVE_CALLS)

@testset "live suite call has a method: $(where_called(call))" for call in FUNCTION_CALLS
    @test accepts(getfield(ChainTables, call.name), call)
end

# Two suites in one run drew the same id from the task RNG, because `@testset` restores
# that RNG when it ends: the second suite's `create_chain` then lost slot 0.
module LiveConfig
    include(joinpath(@__DIR__, "live", "config.jl"))
end

@testset "live_run_id draws another id in each testset" begin
    ids = String[]
    @testset "first" begin
        push!(ids, LiveConfig.live_run_id())
    end
    @testset "next" begin
        push!(ids, LiveConfig.live_run_id())
    end
    @test ids[1] != ids[2]
    @testset "$id is 16 hex digits" for id in ids
        @test contains(id, r"^[0-9a-f]{16}$")
    end
end
