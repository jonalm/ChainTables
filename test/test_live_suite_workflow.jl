using Test
using ChainTables: ChainTables

# test/live/ never runs under Pkg.test, so a change to an internal it calls went
# unnoticed until a live run. This reads every `GWT.f(...)` call in test/live/*.jl and
# checks that `ChainTables.f` exists and has a method taking that many positional
# arguments and those keyword names. Argument types are not checked.

const LIVE_DIR = joinpath(@__DIR__, "live")

"""
    LiveCall

One `GWT.f(args...; kws...)` call in a test/live file. `n_positional` is `nothing` when
the call splats.
"""
struct LiveCall
    name::Symbol
    n_positional::Union{Nothing, Int}
    keywords::Vector{Symbol}
    file::String
    line::Int
end

"""
    read_live_calls(file)

Return the `LiveCall`s in the Julia source `file`.
"""
function read_live_calls(file)
    source = Meta.parseall(read(file, String); filename = file)
    return collect_live_calls!(LiveCall[], source, basename(file), 0)
end

function collect_live_calls!(found, ex, file, line)
    ex isa Expr || return found
    ex.head === :do && return collect_do_call!(found, ex, file, line)
    push_live_call!(found, ex, file, line, 0)
    for a in ex.args
        a isa LineNumberNode && (line = a.line)
        collect_live_calls!(found, a, file, line)
    end
    return found
end

# `GWT.f(x) do t … end` is `GWT.f(function, x)`.
function collect_do_call!(found, ex, file, line)
    call = ex.args[1]
    push_live_call!(found, call, file, line, 1)
    foreach(a -> collect_live_calls!(found, a, file, line), call.args)
    return collect_live_calls!(found, ex.args[2], file, line)
end

function push_live_call!(found, ex, file, line, n_function_arguments)
    is_gwt_call(ex) || return found
    args = ex.args[2:end]
    parameters = parameter_arguments(args)
    splats = any(is_splat, args) || any(is_splat, parameters)
    n_positional = splats ? nothing : n_function_arguments + count(is_positional, args)
    keywords = vcat(keyword_names(filter(is_keyword, args)), keyword_names(parameters))
    name = ex.args[1].args[2].value
    return push!(found, LiveCall(name, n_positional, keywords, file, line))
end

function is_gwt_call(ex)
    ex isa Expr && ex.head === :call || return false
    callee = ex.args[1]
    return callee isa Expr && callee.head === :. && callee.args[1] === :GWT
end

is_splat(a) = a isa Expr && a.head === :...
is_keyword(a) = a isa Expr && a.head === :kw
is_parameters(a) = a isa Expr && a.head === :parameters
is_positional(a) = !(is_splat(a) || is_keyword(a) || is_parameters(a))

function parameter_arguments(args)
    return Any[p for a in args if is_parameters(a) for p in a.args]
end

keyword_names(args) = Symbol[keyword_name(a) for a in args if !is_splat(a)]
keyword_name(a::Symbol) = a
keyword_name(a::Expr) = a.args[1]

"""
    resolves(call::LiveCall)

Return whether `ChainTables` defines `call.name` and, for a function, has a method
that takes the call's positional count and keyword names.
"""
function resolves(call::LiveCall)
    isdefined(ChainTables, call.name) || return false
    f = getfield(ChainTables, call.name)
    # A type or module accessed through GWT, such as `GWT.Ops`.
    f isa Function || return true
    return any(m -> method_accepts(m, call), methods(f))
end

function method_accepts(m::Method, call::LiveCall)
    n_declared = m.nargs - 1
    n = call.n_positional
    fits = n === nothing || (m.isva ? n >= n_declared - 1 : n == n_declared)
    declared = Base.kwarg_decl(m)
    takes_any_keyword = any(endswith("..."), string.(declared))
    return fits && (takes_any_keyword || call.keywords ⊆ declared)
end

const LIVE_FILES = filter(endswith(".jl"), readdir(LIVE_DIR; join = true))
const LIVE_CALLS = reduce(vcat, map(read_live_calls, LIVE_FILES))

@testset "the live suite's call reading finds the calls" begin
    @test length(LIVE_CALLS) > 50
end

@testset "live call $(c.file):$(c.line) GWT.$(c.name) resolves" for c in LIVE_CALLS
    @test resolves(c)
end

# Each live suite creates a chain under `<prefix>/<run id>/`. Drawn from the task RNG,
# two suites in one run drew the same id, because `@testset` restores that RNG when a
# testset ends: the second suite's create_chain then lost slot 0 to the first's chain.
@testset "live_run_id draws a fresh id in each suite" begin
    live = Module(:LiveConfig)
    Base.include(live, joinpath(LIVE_DIR, "config.jl"))
    ids = String[]
    @testset "a suite" begin
        push!(ids, live.live_run_id())
    end
    @testset "the next suite" begin
        push!(ids, live.live_run_id())
    end
    @test allunique(ids)
    @testset "id $id is 16 hex digits" for id in ids
        @test contains(id, r"^[0-9a-f]{16}$")
    end
end
