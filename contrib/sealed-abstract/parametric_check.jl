# Does the sealed compiler help a PARAMETRIC subtype?
# The motivating simulator's `Statistic{F,A,U}` is parametric, and its
# trimming guide reports that no number of instantiations helps.
source = """
module Param
abstract type AbstractStat end
struct Stat{U} <: AbstractStat
    v::Float64
end
value(s::Stat{U}) where {U} = s.v
function total(xs::Vector{AbstractStat})
    t = 0.0
    for x in xs
        t += value(x)
    end
    return t
end
entry() = total(AbstractStat[Stat{Nothing}(1.0), Stat{String}(2.0), Stat{Int}(3.0)])
end"""

# The same shape with plain, non-parametric subtypes, as a control.
control = """
module Plain
abstract type AbstractStat end
$(join(["struct Stat$i <: AbstractStat\n    v::Float64\nend" for i in 1:6], "\n"))
$(join(["value(s::Stat$i) = s.v" for i in 1:6], "\n"))
function total(xs::Vector{AbstractStat})
    t = 0.0
    for x in xs
        t += value(x)
    end
    return t
end
entry() = total(AbstractStat[$(join(["Stat$i(1.0)" for i in 1:6], ", "))])
end"""

include_string(Main, source)
include_string(Main, control)

function measure(name)
    M = Base.invokelatest(getglobal, Main, name)
    A = Base.invokelatest(getglobal, M, :AbstractStat)
    f = Base.invokelatest(getglobal, M, :total)
    ci, rt = only(Base.invokelatest(code_typed, f, (Vector{A},)))
    dyn = count(s -> Meta.isexpr(s, :call) && endswith(string(s.args[1]), ".value"), ci.code)
    return (dynamic = dyn, rt = rt)
end

report(label) = println(rpad(label, 24),
    "parametric subtype -> ", measure(:Param), "   ",
    "plain 6 subtypes -> ", measure(:Plain))

# Run directly. With `--project=env2` and the sealed compiler activated, this
# reports the sealed answer; without it, the stock answer.
if abspath(PROGRAM_FILE) == @__FILE__
    sealed = false
    if haskey(Base.loaded_modules, Base.PkgId(Base.UUID("807dbc54-b67e-4c79-8afb-eafe4df6f2e1"), "Compiler"))
        compiler = Base.loaded_modules[Base.PkgId(Base.UUID("807dbc54-b67e-4c79-8afb-eafe4df6f2e1"), "Compiler")]
        sealed = Base.invokelatest(getglobal, compiler, :SEALED_WORLD)[]
    end
    report(sealed ? "sealed" : "stock")
end
