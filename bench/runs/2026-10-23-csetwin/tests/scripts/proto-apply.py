# proto-apply.py <lj_opt_fold.c> <variant> -- hand-apply the round's CSE
# predicate to a SCRATCH copy of the build copy's lj_opt_fold.c (guide 7.4's
# one-file method).  PROTOTYPE ONLY, not the shipped object: impl-code owns
# hunk 12 of patch-bitop-fold.sh.  Variants:
#   fix     the design's B-i64 text (design.md 2.1), the predicate on a line
#           of its own
#   fwd     the CSEFWD sabotage's text (design.md 5): forward merges allowed,
#           reverse ones still refused -- memory-safe by construction
# The old text must occur exactly once (lj_opt_cse's if, indented 6 spaces,
# and its return line).  Reads and writes bytes; LF; no backslash here.
import sys

T, L = chr(9), chr(10)
OLD = ("      if (IR(ref)->op12 == op12)" + L +
       T + "return TREF(ref, irt_t(IR(ref)->t));  /* Common subexpression found. */" + L)
PRED = {
    "fix": T + "  irt_isi64(IR(ref)->t) == irt_isi64(fins->t))",
    "fwd": T + "  (irt_isi64(IR(ref)->t) == irt_isi64(fins->t) || irt_isi64(fins->t)))"
           "  /* SABOTAGE CSEFWD: an int64 instruction may common with a narrower one"
           " (the forward order); the reverse stays refused */",
}

def main():
    path, var = sys.argv[1], sys.argv[2]
    if var not in PRED:
        print("unknown variant " + var)
        return 1
    new = ("      /* OC-LuaJIT: never common an int64 instruction with a narrower one." + L +
           "      ** On x64 simplify_conv_sext hands int64 ops int refs, so a 32-bit op" + L +
           "      ** can share their op12: its value would stand in for the int64 one, or" + L +
           "      ** an int64 ref would reach a 32-bit recorder (JIT guide P63). */" + L +
           "      if (IR(ref)->op12 == op12 &&" + L +
           PRED[var] + L +
           T + "return TREF(ref, irt_t(IR(ref)->t));  /* Common subexpression found. */" + L)
    data = open(path, "rb").read().decode("latin-1")
    if data.count(chr(13)):
        print("REFUSED: the input holds CRs")
        return 1
    n = data.count(OLD)
    if n != 1:
        print("REFUSED: the old text occurs %d times" % n)
        return 1
    data = data.replace(OLD, new)
    with open(path, "wb") as f:
        f.write(data.encode("latin-1"))
    print("applied %s to %s" % (var, path))
    return 0

sys.exit(main())
