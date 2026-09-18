# The live suite's configuration (ADR-0030): which variables each live test needs, read from
# ENV with nothing defaulted and nothing skipped. Depends on nothing, so test/live/run.sh also
# runs it as a script — `julia test/live/config.jl <selection>` — to learn which profiles to
# check a session for before anything is written: one `profile<TAB>region` line per test.

const LIVE_EXAMPLE = "test/live/live.env.example"

# test => the variables it requires, each read from CHAINTABLES_LIVE_<TEST>_<NAME>
const LIVE_VARIABLES = (
    s3 = (:bucket, :region, :profile),
    gateway = (:bucket, :url, :region, :profile, :prefix, :unlisted_prefix),
)

live_variable(test, name) = "CHAINTABLES_LIVE_" * uppercase("$(test)_$(name)")

"""
    live_selection(args) -> Vector{Symbol}

The live tests named by `args`, all of them when there are none; an unknown name is an error.
"""
function live_selection(args)
    known = collect(keys(LIVE_VARIABLES))
    isempty(args) && return known
    selection = Symbol.(args)
    for test in selection
        test in known || error("live tests: there is no live test '$test'; choose from $(join(known, ", ")), or none for all")
    end
    return unique(selection)
end

"""
    live_config(test) -> NamedTuple

Every variable of `test`, from ENV. Absent or empty is an error naming the variable: not
selecting a test is how it is not run.
"""
function live_config(test)
    names = LIVE_VARIABLES[test]
    values = map(names) do name
        variable = live_variable(test, name)
        value = get(ENV, variable, "")
        isempty(value) && error("live $test test: $variable is not set. Set it in env/live.env (or the file " *
            "CHAINTABLES_LIVE_ENV names) and run test/live/run.sh; $LIVE_EXAMPLE lists every variable")
        value
    end
    return NamedTuple{names}(values)
end

if abspath(PROGRAM_FILE) == @__FILE__
    for test in live_selection(ARGS)
        config = live_config(test)
        println(config.profile, '\t', config.region)
    end
end
