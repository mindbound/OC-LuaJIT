"""ffpatch.py <fresh outdir> -- verify-code's own fail-first of hunk 12 in
the round's native/luajit/patch-bitop-fold.sh (verify-code/vrepo).

Mutations of the SCRIPT's n12 (apply mode, on the pin's pristine
lj_opt_fold.c), each with NADD set to the count the mutation makes, so that
only the content checks can refuse it.  Each mutation runs on:
  S    the round's script, and
  SP   S plus the extra check proposed here: inside lj_opt_cse (between its
       definition line and lj_opt_cselim's), exactly one line names
       'op12 == op12' and exactly one 'return TREF(ref, irt_t(IR(ref)->t))'.
Controls: S and SP on the pristine file (must pass, 76/9), and SP on the
round's own CSEFWD and reverse-allowing forms (must refuse, as S does).
Nothing here builds or runs a luajit.  Writes LF; no backslashes in the
shell text it writes."""
import os, subprocess, sys

V = "C:/Users/astro/claude-tmp/oclj/csetwin/round/verify-code"
SRC = V + "/vrepo/native/luajit/patch-bitop-fold.sh"
PRISTINE = V + "/bfix/luajit-export-windows-x86_64/src/lj_opt_fold.c"
out = sys.argv[1]
if os.path.exists(out):
    print("REFUSING: %s exists" % out); sys.exit(99)
os.makedirs(out + "/tmp")

def rd(p):
    with open(p, "rb") as f:
        return f.read().decode("utf-8")
def wr(p, s):
    with open(p, "wb") as f:
        f.write(s.encode("utf-8"))

S = rd(SRC)
IFL = "      if (IR(ref)->op12 == op12 &&\n"
PRED = "@T@  irt_isi64(IR(ref)->t) == irt_isi64(fins->t))\n"
RET = "@T@return TREF(ref, irt_t(IR(ref)->t));  /* Common subexpression found. */\n"
N12 = IFL + PRED + RET + "EOF\n"
assert S.count(N12) == 1, "n12's tail not found once"
CMT = ("      /* OC-LuaJIT: an int64 instruction never commons with one of another\n"
       "      ** type.  On x64 simplify_conv_sext hands int64 ops int refs, so a 32-bit\n"
       "      ** op can share their op12: its value would stand in for the int64 one,\n"
       "      ** or an int64 ref would reach a 32-bit recorder (JIT guide P63). */\n")
assert S.count(CMT) == 1, "n12's comment not found once"

# SP: the proposed check, appended at the end of verify_content (before its
# closing brace, which directly follows the ADJ check's fail line).
ADJFAIL_HEAD = '  [ "$ADJ" = yes/yes ] || fail '
i = S.index(ADJFAIL_HEAD)
j = S.index("\n}\n", i)
EXTRA = (
    "\n  # Proposed (verify-code): lj_opt_cse holds one match and one return of it.\n"
    "  NM=$(awk -v s=\"$LS\" -v t=\"$LT\" 'NR > s + 0 && NR < t + 0 && index($0, \"op12 == op12\") { n++ } END { print n + 0 }' \"$1\")\n"
    "  NR1=$(awk -v s=\"$LS\" -v t=\"$LT\" 'NR > s + 0 && NR < t + 0 && index($0, \"return TREF(ref, irt_t(IR(ref)->t))\") { n++ } END { print n + 0 }' \"$1\")\n"
    "  [ \"$NM\" = 1 ] && [ \"$NR1\" = 1 ] || fail \"$1: lj_opt_cse (lines $LS-$LT) names 'op12 == op12' on $NM lines and returns a common subexpression on $NR1, expected 1 and 1: a match other than hunk 12's\"")
SP = S[:j] + EXTRA + S[j:]
assert "\\" not in EXTRA

def nadd(s, k):
    assert s.count("NADD=76 ") == 1
    return s.replace("NADD=76 ", "NADD=%d " % k)

def mut_n12(s, new_tail, k, new_cmt=None):
    s2 = s.replace(N12, new_tail + "EOF\n")
    if new_cmt is not None:
        s2 = s2.replace(CMT, new_cmt)
    return nadd(s2, k)

EXTRA_FWD = ("      if (IR(ref)->op12 == op12 && irt_isi64(fins->t))\n" + RET)
EXTRA_REV = ("      if (IR(ref)->op12 == op12 && !irt_isi64(fins->t))\n" + RET)
ELSE_ANY = "      else if (IR(ref)->op12 == op12) return TREF(ref, irt_t(IR(ref)->t));\n"
CMT3 = ("      /* OC-LuaJIT: an int64 instruction never commons with one of another type\n"
        "      ** (on x64 simplify_conv_sext hands int64 ops int refs; JIT guide P63). */\n")
ONE_REV = "      if (IR(ref)->op12 == op12 && !irt_isi64(fins->t)) return TREF(ref, irt_t(IR(ref)->t));\n"
CSEFWD = "@T@  (irt_isi64(IR(ref)->t) == irt_isi64(fins->t) || irt_isi64(fins->t)))\n"
REVOR = "@T@  (irt_isi64(IR(ref)->t) == irt_isi64(fins->t) || irt_isi64(IR(ref)->t)))\n"

CASES = [
    # name, mutate(script) -> script, wanted on S (0 pass / 1 refuse), wanted on SP
    ("control", lambda s: s, 0, 0),
    ("m1-extra-fwd-line", lambda s: mut_n12(s, EXTRA_FWD + IFL + PRED + RET, 78), None, 1),
    ("m2-extra-rev-line", lambda s: mut_n12(s, EXTRA_REV + IFL + PRED + RET, 78), None, 1),
    ("m3-else-any", lambda s: mut_n12(s, IFL + PRED + RET + ELSE_ANY, 77), None, 1),
    ("m4-samecount-rev", lambda s: mut_n12(s, ONE_REV + IFL + PRED + RET, 76, CMT3 + "      /* */\n"), None, 1),
    ("c5-csefwd-text", lambda s: mut_n12(s, IFL + CSEFWD + RET, 76), 1, 1),
    ("c6-rev-or", lambda s: mut_n12(s, IFL + REVOR + RET, 76), 1, 1),
]
# m4 replaces the 4-line comment with a 2-line one plus an empty comment
# line, and adds one line: the same 76/9 line counts as the round's text.

res = []
for name, f, want_s, want_sp in CASES:
    for tag, base in (("S", S), ("SP", SP)):
        sc = f(base)
        assert "\\" not in sc and "\t" not in sc
        p = "%s/%s.%s.sh" % (out, name, tag)
        wr(p, sc)
        env = dict(os.environ)
        env["TMPDIR"] = out + "/tmp"
        r = subprocess.run(["sh", p, PRISTINE, "%s/%s.%s.out.c" % (out, name, tag)],
                           capture_output=True, env=env)
        msg = (r.stdout + r.stderr).decode("utf-8", "replace").strip().replace("\n", " | ")
        want = want_s if tag == "S" else want_sp
        verdict = "-" if want is None else ("ok" if (r.returncode == 0) == (want == 0) else "WRONG")
        res.append("%s %s %s rc=%d want=%s :: %s" % (verdict, name, tag, r.returncode,
                   "?" if want is None else want, msg[:330]))
wr(out + "/results.txt", "\n".join(res) + "\n")
print("\n".join(res))
