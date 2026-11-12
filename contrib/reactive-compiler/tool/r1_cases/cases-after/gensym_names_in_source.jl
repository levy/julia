# Names written as var"#..." look like names that the compiler makes. The edit
# changes only such a name in a function body.
# Revise has the test set "Gensym names in source".
module GensymNamesInSource
const var"#x" = 1
const var"#y" = 2
getval() = var"#y"
shown() = getval()
end
