# interpret_blowup — one call site over a 12×12 type product that no split
# budget will take. The traced combinations compile; the others interpret.
# SPLIT-CASES 16
# EXPECT proven=fail sealed=fail trace=fail
#
# `combine(a, b)` has one generic method and one specific pair. Twelve unit
# types make 144 combinations at the site, and `# SPLIT-CASES 16` keeps the
# compiler from splitting them, so the site is a dynamic call. The FIRST
# argument decides how many combinations the run touches: the recorded run
# takes none and touches 3×3, so a binary run with `12` reaches 135
# combinations nothing compiled. Without an interpreter those are a crash at
# startup; with SEALED_INTERPRET=1 the generic method is retained with its
# source, its `getproperty` and arithmetic dispatch to what the image holds,
# and the binary prints what the source prints. `JULIA_REPORT_INTERPRETED=1`
# names every combination the interpreter took.
#
# MEASURED on the fork host (plan/pending/seal-to-interpreter.md):
#   interpreter off          the trim refuses the program, 2 errors
#   candidates only          1.8 MB, dies at `getproperty(U1, :v)` — one Base fallback
#   + every Core-typed Base method   20.4 MB, correct: 8 142 methods to supply that one
#   + the SUPPORT SET instead        3.1 MB, correct — k=12: 429 interpreted calls, 155 instances
#   trace level              k=3 runs 0 interpreted calls; k=12 runs 351, correct
# The stock ladder levels build without the flag, so all three declare fail.
abstract type Unit end
struct U1  <: Unit; v::Int; end
struct U2  <: Unit; v::Int; end
struct U3  <: Unit; v::Int; end
struct U4  <: Unit; v::Int; end
struct U5  <: Unit; v::Int; end
struct U6  <: Unit; v::Int; end
struct U7  <: Unit; v::Int; end
struct U8  <: Unit; v::Int; end
struct U9  <: Unit; v::Int; end
struct U10 <: Unit; v::Int; end
struct U11 <: Unit; v::Int; end
struct U12 <: Unit; v::Int; end

Base.@noinline combine(a::Unit, b::Unit)::Int = a.v * 12 + b.v
Base.@noinline combine(a::U1, b::U1)::Int = 1000

function (@main)(argv::Vector{String})::Cint
    k = isempty(argv) ? 3 : Base.parse(Int, argv[1])
    units = Any[U1(1), U2(2), U3(3), U4(4), U5(5), U6(6),
                U7(7), U8(8), U9(9), U10(10), U11(11), U12(12)]
    total = 0
    for i in 1:k, j in 1:k
        total += combine(units[i], units[j])   # the 144-way site
    end
    Base.print(Core.stdout, "interpret_blowup: k=", k, " total=", total, "\n")
    return Cint(0)
end
