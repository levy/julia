# dynamic_argument — a command-line argument selects among compiled behaviours.
# EXPECT proven=pass sealed=pass trace=pass   (PENDING: needs trace merging)
#
# MEASURED: it passes at every level with an empty recorded set, so it does not
# yet test its mechanism. Its real assertion needs a feature that does not
# exist: record ONE branch, build, and require the binary to fail loudly on the
# others - then record both and require it to succeed. That is trace merging
# (plan section 37), and until it exists this example only proves the branches
# compile.
#
# The recorded run covers ONE branch, so a single trace is not enough: this is
# the example that tests trace MERGING. Build from one trace and the other
# branch has no compiled target; the binary must then FAIL loudly rather than
# guess, because there is no compiler in the image to fall back on.
abstract type Mode end
struct Fast <: Mode end
struct Slow <: Mode end
struct Exact <: Mode end
Base.@noinline apply_mode(::Fast, x::Int)::Int  = x * 2
Base.@noinline apply_mode(::Slow, x::Int)::Int  = x + 100
Base.@noinline apply_mode(::Exact, x::Int)::Int = x
Base.@noinline choose(name::String)::Mode =
    name == "slow" ? Slow() : name == "exact" ? Exact() : Fast()

function (@main)(argv::Vector{String})::Cint
    mode = choose(isempty(argv) ? "fast" : argv[1])
    total = 0
    for i in 1:5
        total += apply_mode(mode, i)
    end
    Base.print(Core.stdout, "dynamic_argument: ", total, "\n")
    return Cint(0)
end
