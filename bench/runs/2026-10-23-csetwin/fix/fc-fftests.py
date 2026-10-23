"""fc-fftests.py <fresh outdir> <bitop dir> <PUC lua.exe> <base luajit src
dir> <fixed luajit src dir> [<old bitop dir>] -- the CSE type twin round's
fail-firsts of the checks the fixer added to the round's test files
(verify-code's findings 2 and 5); the fixer's scripts/fftests.py with its
paths as arguments (the final check runs it without the old tree).

Each mutation copies <bitop dir> (test/native/bitop) to <outdir>/<case>/
bitop/, replaces one exact text that must occur exactly once, and runs one
file directly:
  t_cserev.lua under PUC 5.3.6 (no JIT at all), and under the base build's
               luajit.exe -joff (no trace, so no IR);
  t_csefwd.lua under the base build's luajit.exe -joff;
  cseir.lua    under the fixed build's luajit.exe with the JIT (forward
               cases only) and one option set.
NO MUTATION WRITES A REVERSE-ORDER CASE OR A SLOT SHAPE (the user's
decision D2): the text checks are proved by mutating their search strings
or by adding a Lua comment ("-- for ", "-- bit") to a case's text, which
the checks must refuse and which would compute nothing even if it ran.
With <old bitop dir> (the round's files before the fix) the same comment
mutations run on the old t_cserev too, to show that its check passed them.
Writes bytes (LF); exit 0 iff every case reads as wanted."""
import os, shutil, subprocess, sys

out, NEWB, PUC, BASE, FIX = sys.argv[1:6]
OLDB = sys.argv[6] if len(sys.argv) > 6 else None
if os.path.exists(out):
    print("REFUSING: %s exists" % out)
    sys.exit(99)
os.makedirs(out)

NL = "\n"
RV, FW, IR = "t_cserev.lua", "t_csefwd.lua", "cseir.lua"
R6 = '  { name = "r6-byte", kind = "rev", src = iloop('
R5 = '  { name = "r5-sel", kind = "rev",' + NL + '    src = jloop('
CASES = [
    # name, tree (NEW or OLD), file, old text, new text, how to run, want rc, a text the output must hold
    ("rv-for-new", "NEW", RV, R6, '  { name = "r6-byte", kind = "rev", src = "-- for " .. NL .. iloop(', "puc", 2, "INSTRUMENT: t_cserev's texts: r6-byte (a slot shape)"),
    ("rv-for-new-joff", "NEW", RV, R6, '  { name = "r6-byte", kind = "rev", src = "-- for " .. NL .. iloop(', "joff", 2, "INSTRUMENT: t_cserev's texts: r6-byte (a slot shape)"),
    ("rv-bit-new", "NEW", RV, R5, '  { name = "r5-sel", kind = "rev",' + NL + '    src = "-- bit" .. NL .. jloop(', "puc", 2, "INSTRUMENT: t_cserev's texts: r5-sel (a slot shape)"),
    ("rv-for-old", "OLD", RV, R6, '  { name = "r6-byte", kind = "rev", src = "-- for " .. NL .. iloop(', "puc", 0, "r6-byte"),
    ("rv-bit-old", "OLD", RV, R5, '  { name = "r5-sel", kind = "rev",' + NL + '    src = "-- bit" .. NL .. jloop(', "puc", 0, "r5-sel"),
    ("rv-control", "NEW", RV, None, None, "puc", 0, "r6-mul"),
    ("fw-copyorder", "NEW", FW, '"local a = bit.lshift(j, 30)",', '"local a = bit.lshift(j, 31)",', "joff", 2, "INSTRUMENT: t_csefwd's producer-first check fails for copy"),
    ("fw-sideorder", "NEW", FW, '"local c = b << 30", "else" })', '"local c = b << 31", "else" })', "joff", 2, "INSTRUMENT: t_csefwd's producer-first check fails for side"),
    ("fw-count", "NEW", FW, 'count(C.src, "bit.") == 1', 'count(C.src, "bit.") == 2', "joff", 2, "INSTRUMENT: t_csefwd's producer-first check fails for copy, side"),
    ("fw-control", "NEW", FW, None, None, "joff", 0, "side"),
    # cseir's two gates, removed, on the fixed build under the set where each
    # keeps a pair that does not form from being judged.
    ("ir-sidegate", "NEW", IR, 'if C.need == "side" then needs = needs and c.direct + c.served > 0 end',
     'if C.need == "side" then needs = needs and true end', "fix:-Omaxside=0", 1, "split 0: no int64 instruction beside the 32-bit one"),
    ("ir-loopgate", "NEW", IR, 'if C.need == "loop" then needs = needs and FLAG.loop end',
     'if C.need == "loop" then needs = needs and true end', "fix:-O3 -O-loop", 1, "split 0: no int64 instruction beside the 32-bit one"),
    ("ir-gates-control-ms0", "NEW", IR, None, None, "fix:-Omaxside=0", 0, "cseir: 32 of 32 cases ok"),
    ("ir-gates-control-noloop", "NEW", IR, None, None, "fix:-O3 -O-loop", 0, "cseir: 32 of 32 cases ok"),
]

lines, nbad = [], 0
for name, tree, fn, old, new, how, want, needle in CASES:
    if tree == "OLD" and not OLDB:
        continue
    d = os.path.join(out, name, "bitop")
    shutil.copytree(NEWB if tree == "NEW" else OLDB, d)
    p = os.path.join(d, fn)
    if old is not None:
        with open(p, "rb") as f:
            s = f.read().decode("latin-1")
        if s.count(old) != 1:
            lines.append("WRONG %s: the text to replace occurs %d times" % (name, s.count(old)))
            nbad += 1
            continue
        s = s.replace(old, new)
        assert "\r" not in s
        with open(p, "wb") as f:
            f.write(s.encode("latin-1"))
    env = dict(os.environ)
    for k in ("LUA_INIT", "LUA_INIT_5_3", "LUA_PATH", "LUA_CPATH"):
        env.pop(k, None)
    if how == "puc":
        cmd, cwd = [PUC, p], d
    elif how == "joff":
        cmd, cwd = [BASE + "/luajit.exe", "-joff", p], BASE
    else:
        opts = how.split(":", 1)[1].split()
        cmd, cwd = [FIX + "/luajit.exe"] + opts + [p], FIX
        env["LUA_PATH"] = FIX + "/?.lua;;"
    r = subprocess.run(cmd, cwd=cwd, capture_output=True, env=env, timeout=300)
    o = (r.stdout + r.stderr).decode("latin-1").replace("\r", "")
    with open(os.path.join(out, name, "out.txt"), "wb") as f:
        f.write(("$ " + " ".join(cmd) + NL + "rc=%d" % r.returncode + NL + o).encode("latin-1"))
    ok = r.returncode == want and needle in o
    nbad += 0 if ok else 1
    first = [l for l in o.split(NL) if "INSTRUMENT" in l or "FAILED" in l or l.startswith("cseir:")][:2]
    lines.append("%s %s (%s %s, %s): rc=%d want=%d :: %s" % ("ok" if ok else "WRONG", name, tree, fn, how,
                 r.returncode, want, " | ".join(first)[:300]))
lines.append("FFTESTS: %s (%d wrong)" % ("PASS" if nbad == 0 else "FAIL", nbad))
with open(os.path.join(out, "results.txt"), "wb") as f:
    f.write((NL.join(lines) + NL).encode("latin-1"))
print(NL.join(lines))
sys.exit(0 if nbad == 0 else 1)
