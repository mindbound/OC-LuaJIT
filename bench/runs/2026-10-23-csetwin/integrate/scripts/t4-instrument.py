"""t4-instrument.py <lj_opt_fold.c>: T4's instrument (design 4.5), in a
scratch copy only, never shipped.  Edits the file in place:
  - after '#include <math.h>' (once): '#include <stdio.h>' (the file sees
    no stdio otherwise: lj_def.h brings stdint, string and stdlib only);
  - after hunk 12's return line in lj_opt_cse (anchored on the predicate
    line and the return line together, once): one line that prints
    'CSEREFUSE op=<opcode> fins=<type> cand=<type>' to stderr when the
    candidate's op12 matched and the predicate refused it.  The newline is
    printed as %c with 10, so this file and the C line hold no backslash.
Asserts each anchor once, and the file's line count grows by exactly 2.
Writes bytes, LF kept."""
import sys

p = sys.argv[1]
NL = chr(10)
TAB = chr(9)
t = open(p, "rb").read().decode("latin-1")
n0 = t.count(NL)
inc_old = "#include <math.h>" + NL
inc_new = inc_old + "#include <stdio.h>  /* T4 INSTRUMENT: never shipped */" + NL
pred = TAB + "  irt_isi64(IR(ref)->t) == irt_isi64(fins->t))" + NL
ret = TAB + "return TREF(ref, irt_t(IR(ref)->t));  /* Common subexpression found. */" + NL
probe = ("      if (IR(ref)->op12 == op12) fprintf(stderr, " + chr(34) +
         "CSEREFUSE op=%d fins=%d cand=%d%c" + chr(34) +
         ", (int)fins->o, (int)irt_type(fins->t), (int)irt_type(IR(ref)->t), 10);"
         "  /* T4 INSTRUMENT: the predicate refused this candidate; never shipped */" + NL)
assert t.count(inc_old) == 1, "include anchor"
assert t.count(pred + ret) == 1, "predicate+return anchor"
assert t.count("CSEREFUSE") == 0, "already instrumented"
t = t.replace(inc_old, inc_new).replace(pred + ret, pred + ret + probe)
assert t.count(NL) == n0 + 2
assert chr(92) not in probe
open(p, "wb").write(t.encode("latin-1"))
print("instrumented", p, "lines", n0, "->", t.count(NL))
