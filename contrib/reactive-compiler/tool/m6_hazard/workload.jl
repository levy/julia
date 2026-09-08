# The workload of the gates: the precompile script of the founding build and
# the rebuild workload of every later build. Plain calls into the package, so
# that the delta converges (a top-level definition here would re-evaluate on
# every rebuild).
using HazardApp
HazardApp.report()
HazardApp.changes_report()
