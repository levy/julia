# A struct whose field the edit renames, and a method that reads the field. The
# method must read the new field.
# Revise has the test set "struct revision (simple)".
module StructRevisionSimple
struct Hello; who::String; end
hello(x::Hello) = hello(x.who)
hello(who::String) = "Hello, $who"
shown() = (hello(Hello("World")), fieldnames(Hello))
end
