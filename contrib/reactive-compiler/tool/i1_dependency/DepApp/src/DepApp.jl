# The application of the I1 gate. Its own sources do not change; every edit
# of the gate is in the path package DepLib.
module DepApp
using DepLib
include("app.jl")
end
