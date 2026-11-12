# Inline annotations on small functions. The edit moves the annotations from two
# functions to the third; the flag of each function must follow.
# Revise has the test set "Changing @inline annotations".
module ChangingInlineAnnotations
inlined(x) = x
kept_out(x) = x
@noinline plain(x) = x
call_inlined(x) = inlined(x)
call_kept_out(x) = kept_out(x)
call_plain(x) = plain(x)
flag(f) = Base.uncompressed_ir(only(methods(f))).inlining
shown() = (call_inlined(3), call_kept_out(3), call_plain(3),
           flag(inlined), flag(kept_out), flag(plain))
end
