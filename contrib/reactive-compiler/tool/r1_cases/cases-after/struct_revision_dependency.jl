# A struct with methods that use it, a constructor that reads its field count,
# and a second struct that holds it. The edit adds a field to the first struct.
# Revise has the test set "struct revision (dependency)".
module StructRevisionDependency
struct Point
    x::Float64
    y::Float64
end
firstval(p::Point) = p.x
mynorm(p::Point) = sqrt(p.x^2 + p.y^2)
hiddenconstructor(x) = Point(ntuple(_ -> x, length(fieldnames(Point)))...)
struct PointWrapper
    p::Point
end
scaled(pw::PointWrapper) = 55 * pw.p.x
fieldvalues(p) = ntuple(i -> getfield(p, i), nfields(p))
shown() = (fieldvalues(hiddenconstructor(2.0)), firstval(hiddenconstructor(2.0)),
           mynorm(hiddenconstructor(2.0)), scaled(PointWrapper(hiddenconstructor(2.0))),
           fieldnames(Point))
end
