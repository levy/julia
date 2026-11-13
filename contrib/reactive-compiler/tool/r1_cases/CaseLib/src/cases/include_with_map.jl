# A file that `include` reads through a function of its expressions. The edit
# changes the text of the file and no other text. A build that does not apply
# the function must stop: the file is an input that it can not apply.
module IncludeWithMap
double_literals(e) = e isa Expr ? Expr(e.head, map(double_literals, e.args)...) : e isa Int ? 2 * e : e
include(double_literals, "include_with_map/part.jl")
shown() = part()
end
