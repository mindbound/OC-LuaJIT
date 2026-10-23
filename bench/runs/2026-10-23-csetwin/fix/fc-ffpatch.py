"""fc-ffpatch.py <fresh outdir> <patch script> <pin lj_opt_fold.c>
<a4c0645 lj_opt_fold.c> [<old patch script>] -- the CSE type twin round's
fail-first of hunk 12's verify_content in native/luajit/patch-bitop-fold.sh
(the fixer's scripts/ffpatch.py, with its paths as arguments; the final
check runs it without the old script).

Scripts compared (each a whole patch-bitop-fold.sh):
  OLD  (optional) the round's script before the fixer's change, d488821b
  NEW  the script under test (with lj_opt_cse's two counts)

Part A, mutations of the SCRIPT's n12, each run in apply mode on the pin's
pristine lj_opt_fold.c (git cat-file of 1ee778a4:src/lj_opt_fold.c), with
NADD set to the mutation's own count so that only the content checks can
refuse it.  m1-m4 are verify-code's (its runs/ffpatch-1); m5 and m6 are the
fixer's, made so that each new count fails alone; c5 and c6 are the
round's own forms (CSEFWD's text and the reverse-allowing ||), refused
before the fix too.

Part B, the controls: NEW on the pin's file (76 added, 9 removed, of 2720),
on upstream a4c0645's (76/9 of 2730), and in its already-patched mode on
its own output.

Part C, every check evaluated without exiting: NEW with fail() printing
"CHECK-FAILED: <message>" and going on, in already-patched mode, on the
control output and on mutations of it (lines inserted into lj_opt_cse,
hunk 12's own seven lines left whole); it prints which checks fire.

Nothing here builds or runs a luajit.  Writes bytes (LF); the shell text it
writes holds no backslash and no tab."""
import os, subprocess, sys

out, NEW, PIN, TIP = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
OLD = sys.argv[5] if len(sys.argv) > 5 else None
if os.path.exists(out):
    print("REFUSING: %s exists" % out)
    sys.exit(99)
os.makedirs(out + "/tmp")

def rd(p):
    with open(p, "rb") as f:
        return f.read().decode("utf-8")

def wr(p, s):
    with open(p, "wb") as f:
        f.write(s.encode("utf-8"))

def run(script_text, name, args):
    p = "%s/%s.sh" % (out, name)
    assert "\\" not in script_text and "\t" not in script_text, name
    wr(p, script_text)
    env = dict(os.environ)
    env["TMPDIR"] = out + "/tmp"
    r = subprocess.run(["sh", p] + args, capture_output=True, env=env)
    msg = (r.stdout + r.stderr).decode("utf-8", "replace").strip()
    return r.returncode, msg

S_NEW = rd(NEW)
S_OLD = rd(OLD) if OLD else S_NEW
IFL = "      if (IR(ref)->op12 == op12 &&\n"
PRED = "@T@  irt_isi64(IR(ref)->t) == irt_isi64(fins->t))\n"
RET = "@T@return TREF(ref, irt_t(IR(ref)->t));  /* Common subexpression found. */\n"
N12 = IFL + PRED + RET + "EOF\n"
CMT = ("      /* OC-LuaJIT: an int64 instruction never commons with one of another\n"
       "      ** type.  On x64 simplify_conv_sext hands int64 ops int refs, so a 32-bit\n"
       "      ** op can share their op12: its value would stand in for the int64 one,\n"
       "      ** or an int64 ref would reach a 32-bit recorder (JIT guide P63). */\n")
for s in (S_OLD, S_NEW):
    assert s.count(N12) == 1 and s.count(CMT) == 1 and s.count("NADD=76 ") == 1

def mut_n12(s, new_tail, k, new_cmt=None):
    s2 = s.replace(N12, new_tail + "EOF\n")
    if new_cmt is not None:
        s2 = s2.replace(CMT, new_cmt)
    return s2.replace("NADD=76 ", "NADD=%d " % k)

# verify-code's m1-m4 (scripts/ffpatch.py there), verbatim.
EXTRA_FWD = "      if (IR(ref)->op12 == op12 && irt_isi64(fins->t))\n" + RET
EXTRA_REV = "      if (IR(ref)->op12 == op12 && !irt_isi64(fins->t))\n" + RET
ELSE_ANY = "      else if (IR(ref)->op12 == op12) return TREF(ref, irt_t(IR(ref)->t));\n"
CMT3 = ("      /* OC-LuaJIT: an int64 instruction never commons with one of another type\n"
        "      ** (on x64 simplify_conv_sext hands int64 ops int refs; JIT guide P63). */\n")
ONE_REV = "      if (IR(ref)->op12 == op12 && !irt_isi64(fins->t)) return TREF(ref, irt_t(IR(ref)->t));\n"
# The fixer's: a reverse-allowing match spelled without op12 (the return
# count alone), and a stray line naming op12 == op12 with no return (the
# match count alone).
M5 = ("      if (IR(ref)->op1 == fins->op1 && IR(ref)->op2 == fins->op2 && !irt_isi64(fins->t))\n"
      "@T@return TREF(ref, irt_t(IR(ref)->t));\n")
M6 = "      if (IR(ref)->op12 == op12 && !irt_isi64(fins->t)) break;\n"
CSEFWD = "@T@  (irt_isi64(IR(ref)->t) == irt_isi64(fins->t) || irt_isi64(fins->t)))\n"
REVOR = "@T@  (irt_isi64(IR(ref)->t) == irt_isi64(fins->t) || irt_isi64(IR(ref)->t)))\n"

A = [
    # name, mutation, want rc on OLD (None: not asserted), want rc on NEW, a text NEW's message must hold
    ("control", lambda s: s, 0, 0, "(76 lines added, 9 removed, of 2720)"),
    ("m1-extra-fwd-line", lambda s: mut_n12(s, EXTRA_FWD + IFL + PRED + RET, 78), 0, 1, "names 'op12 == op12' on 2 lines"),
    ("m2-extra-rev-line", lambda s: mut_n12(s, EXTRA_REV + IFL + PRED + RET, 78), 0, 1, "names 'op12 == op12' on 2 lines"),
    ("m3-else-any", lambda s: mut_n12(s, IFL + PRED + RET + ELSE_ANY, 77), 0, 1, "names 'op12 == op12' on 2 lines"),
    ("m4-samecount-rev", lambda s: mut_n12(s, ONE_REV + IFL + PRED + RET, 76, CMT3 + "      /* */\n"), 0, 1, "names 'op12 == op12' on 2 lines"),
    ("m5-noop12-rev", lambda s: mut_n12(s, M5 + IFL + PRED + RET, 78), 0, 1, "names 'return' on 3 lines"),
    ("m6-stray-op12", lambda s: mut_n12(s, M6 + IFL + PRED + RET, 77), 0, 1, "names 'op12 == op12' on 2 lines"),
    ("c5-csefwd-text", lambda s: mut_n12(s, IFL + CSEFWD + RET, 76), 1, 1, "is a line of its own 0 times"),
    ("c6-rev-or", lambda s: mut_n12(s, IFL + REVOR + RET, 76), 1, 1, "is a line of its own 0 times"),
]
lines = []
nbad = 0
for name, f, w_old, w_new, needle in A:
    for tag, base, want in (("OLD", S_OLD, w_old), ("NEW", S_NEW, w_new)):
        if tag == "OLD" and not OLD:
            continue
        rc, msg = run(f(base), "%s.%s" % (name, tag), [PIN, "%s/%s.%s.out.c" % (out, name, tag)])
        ok = (rc == want) and (tag == "OLD" or needle in msg)
        nbad += 0 if ok else 1
        lines.append("%s A %s %s rc=%d want=%d :: %s" % ("ok" if ok else "WRONG", name, tag, rc, want,
                     msg.replace("\n", " | ")[:360]))

# Part B: the controls on the tip's file and the already-patched mode.
rc, msg = run(S_NEW, "B-tip.NEW", [TIP, out + "/B-tip.out.c"])
ok = rc == 0 and "(76 lines added, 9 removed, of 2730)" in msg
nbad += 0 if ok else 1
lines.append("%s B tip-a4c0645 NEW rc=%d :: %s" % ("ok" if ok else "WRONG", rc, msg[:300]))
rc, msg = run(S_NEW, "B-idem.NEW", [out + "/control.NEW.out.c", out + "/B-idem.out.c"])
ok = rc == 0 and "already folds the 64-bit bit operators without FFI (verified) -- unchanged" in msg
same = rd(out + "/control.NEW.out.c") == rd(out + "/B-idem.out.c") if ok else False
ok = ok and same
nbad += 0 if ok else 1
lines.append("%s B idempotent NEW rc=%d same-bytes=%s :: %s" % ("ok" if ok else "WRONG", rc, same, msg[:300]))
nc = rd(out + "/control.NEW.out.c")
if OLD:
    oc = rd(out + "/control.OLD.out.c")
    ok = oc == nc
    nbad += 0 if ok else 1
    lines.append("%s B the control's output is the same bytes under OLD and NEW (only verify_content changed)" % ("ok" if ok else "WRONG"))

# Part C: every check evaluated without exiting, on mutations of a patched file.
FAILDEF = 'fail() { echo "$ME: $*" >&2; exit 1; }\n'
assert S_NEW.count(FAILDEF) == 1
S_NX = S_NEW.replace(FAILDEF, 'fail() { echo "CHECK-FAILED: $*" >&2; }\n')
P = nc
ANCH = "      /* OC-LuaJIT: an int64 instruction never commons with one of another\n"
assert P.count(ANCH) == 1
RETF = "\treturn TREF(ref, irt_t(IR(ref)->t));  /* Common subexpression found. */\n"
assert P.count(RETF) == 1
T = lambda x: x.replace("@T@", "\t")
C = [
    ("p0-control", P),
    ("p1-extra-fwd-line", P.replace(ANCH, T(EXTRA_FWD) + ANCH)),
    ("p2-extra-rev-line", P.replace(ANCH, T(EXTRA_REV) + ANCH)),
    ("p3-else-any", P.replace(RETF, RETF + ELSE_ANY)),
    ("p5-noop12-rev", P.replace(ANCH, T(M5) + ANCH)),
    ("p6-stray-op12", P.replace(ANCH, M6 + ANCH)),
]
for name, text in C:
    fp = "%s/%s.c" % (out, name)
    wr(fp, text)
    rc, msg = run(S_NX, "C-" + name, [fp, fp])
    fired = [l.split("CHECK-FAILED: ", 1)[1] for l in msg.split("\n") if "CHECK-FAILED: " in l]
    short = []
    for m in fired:
        if "names 'op12 == op12'" in m: short.append("match-count")
        elif "names 'return'" in m: short.append("return-count")
        else: short.append(m.split(": ", 1)[-1][:90])
    want = {"p0-control": [], "p1-extra-fwd-line": ["match-count", "return-count"],
            "p2-extra-rev-line": ["match-count", "return-count"], "p3-else-any": ["match-count", "return-count"],
            "p5-noop12-rev": ["return-count"], "p6-stray-op12": ["match-count"]}[name]
    ok = short == want
    nbad += 0 if ok else 1
    lines.append("%s C %s fired: [%s] want [%s]" % ("ok" if ok else "WRONG", name, ", ".join(short), ", ".join(want)))

lines.append("FFPATCH: %s (%d wrong)" % ("PASS" if nbad == 0 else "FAIL", nbad))
wr(out + "/results.txt", "\n".join(lines) + "\n")
print("\n".join(lines))
sys.exit(0 if nbad == 0 else 1)
