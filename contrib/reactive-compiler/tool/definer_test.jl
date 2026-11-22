# The test of the place that a method keeps (decision D13 of
# plan/done/a-rebuild-equals-a-whole-build.md): the file and the first line
# of the top-level expression that defined it (`toplevel_file`,
# `toplevel_line`), beside the place of its text (`file`, `line`).
#
#   julia --startup-file=no definer_test.jl
#
# The test writes three files into a temporary folder, loads them, and prints
# one line for each check and a last line with the result.
dir = mktempdir()
write(joinpath(dir, "helper.jl"), """
function build(name)
    return quote
        \$(esc(name))() = 7
    end
end
macro steady(name)
    return build(name)
end
macro top(name)
    return esc(Expr(:toplevel, LineNumberNode(999, Symbol("elsewhere.jl")), :(\$name() = 1)))
end
""")
write(joinpath(dir, "user.jl"), """
plain() = 1

"doc"
documented(x) = x

@steady steady_value

for (name, value) in ((:looped, 3),)
    @eval \$name() = \$value
end

module Inner
inner() = 2
keyed(x; k = 1) = y -> x + y + k
end

@top fromtop
struct P; x::Int; end
@generated staged(x) = :(x)
include("nested.jl")
after_include() = 5

"a documented module"
module Documented
inside() = 1
end
""")
write(joinpath(dir, "nested.jl"), "\nnested() = 4\n")
module T end
Base.include(T, joinpath(dir, "helper.jl"))
Base.include(T, joinpath(dir, "user.jl"))
definer(m::Method) = (basename(String(m.toplevel_file)), Int(m.toplevel_line))
text(m::Method) = (basename(String(m.file)), Int(m.line))
failed = Ref(0)
function check(name, ok, got)
    println(ok ? "ok   " : "FAIL ", name, ok ? "" : string(": ", got))
    ok || (failed[] += 1)
end
one(f) = only(methods(f))
check("a plain method", definer(one(T.plain)) == ("user.jl", 1) && text(one(T.plain)) == ("user.jl", 1),
      (definer(one(T.plain)), text(one(T.plain))))
check("a documented method has the line of its docstring", definer(one(T.documented)) == ("user.jl", 3),
      definer(one(T.documented)))
check("a method of an expansion has the place of the user", definer(one(T.steady_value)) == ("user.jl", 6),
      definer(one(T.steady_value)))
check("its text is in the macro file", text(one(T.steady_value))[1] == "helper.jl", text(one(T.steady_value)))
check("a method of an eval in a loop has the place of the loop", definer(one(T.looped)) == ("user.jl", 8),
      definer(one(T.looped)))
check("a method in a module has the line of its form", definer(one(T.Inner.inner)) == ("user.jl", 13),
      definer(one(T.Inner.inner)))
keyed = [m for m in Base.MethodList(Core.methodtable) if m.module === T.Inner && occursin("keyed", string(m.sig))]
check("the keyword method, its body and its closure have one place",
      length(keyed) >= 3 && all(m -> definer(m) == ("user.jl", 14), keyed), [(m.name, definer(m)) for m in keyed])
check("a macro that returns top-level forms does not move the place", definer(one(T.fromtop)) == ("user.jl", 17),
      definer(one(T.fromtop)))
check("the constructors of a struct", all(m -> definer(m) == ("user.jl", 18), methods(T.P)),
      [definer(m) for m in methods(T.P)])
staged = one(T.staged)
check("a generated method", definer(staged) == ("user.jl", 19), definer(staged))
generators = collect(methods(staged.generator.gen))
check("the method of its generator", !isempty(generators) && all(m -> definer(m) == ("user.jl", 19), generators),
      [definer(m) for m in generators])
check("a method of an included file has the place of its own form", definer(one(T.nested)) == ("nested.jl", 2),
      definer(one(T.nested)))
check("the place comes back after an include", definer(one(T.after_include)) == ("user.jl", 21),
      definer(one(T.after_include)))
check("a method in the body of a documented module has the line of its form",
      definer(one(T.Documented.inside)) == ("user.jl", 25), definer(one(T.Documented.inside)))
Core.eval(T, Expr(:toplevel, LineNumberNode(5, Symbol("given.jl")), :(given() = 1)))
check("an evaluation with a place", definer(one(T.given)) == ("given.jl", 5), definer(one(T.given)))
moved = one(T.plain)
setfield!(moved, :toplevel_line, Int32(40))
check("the line of the place can be set", definer(moved) == ("user.jl", 40), definer(moved))
base_methods = [m for m in Base.MethodList(Core.methodtable) if m.module === Base]
println("     methods of Base with a place: ", count(m -> m.toplevel_file !== Symbol(""), base_methods), " of ",
        length(base_methods))
# A method that the program defines outside each top-level evaluation has no
# place. The file of this test is a top-level evaluation itself, so the check
# runs when the process ends.
atexit() do
    Core.eval(T, :(late() = 1))
    late = only(methods(Base.invokelatest(getfield, T, :late)))
    check("a method that the program defines outside a top-level evaluation has no place",
          definer(late) == ("", 0), definer(late))
    println(failed[] == 0 ? "definer test: all pass" : "definer test: $(failed[]) FAILED")
end
