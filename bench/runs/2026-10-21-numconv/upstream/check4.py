import sys, os, re
# check4.py <issue.md> <run dir>: upstream's fix a4c0645 (build-up3.sh's
# a4c and a4cnogc64) against the issue: on both builds the JIT's repro.lua
# output must equal -joff's and the issue's -joff block (byte for byte,
# the "$ luajit" lines dropped); vsel must differ from -joff in none of its
# 21 sets; every rc file 0; each build's FR2 byte.  Also printed, not
# judged: repro's and konst's traces and NYI VARG aborts, and vsel's #cov.
# Prints FAIL lines and exits 1 on any mismatch.  No backslashes.
NL = chr(10)
FENCE = chr(96) * 3
issue = open(sys.argv[1], "rb").read().decode("utf-8")
R = sys.argv[2]
bad = []
def rd(name):
    p = os.path.join(R, name)
    return open(p, "rb").read().decode("utf-8", "replace") if os.path.exists(p) else None

lines = issue.split(NL)
blocks, cur, lang = [], None, None
for ln in lines:
    if cur is None and ln.startswith(FENCE):
        cur, lang = [], ln[3:]
    elif cur is not None and ln == FENCE:
        blocks.append((lang, cur))
        cur = None
    elif cur is not None:
        cur.append(ln)
outs = [b for l, b in blocks if l == ""]
if len(outs) != 1:
    sys.exit("expected one bare output block, got %d" % len(outs))
out = outs[0]
i_joff = out.index("$ luajit -joff repro.lua")
i_jon = out.index("$ luajit repro.lua")
want_joff = NL.join(out[i_joff + 1:i_jon]) + NL

if not (rd("a4c-fixline.txt") or "").strip():
    bad.append("the extracted tree lacks upstream's fix line")
for b in ("a4c", "a4cnogc64"):
    j = rd(b + "-repro-joff.txt")
    n = rd(b + "-repro-jon.txt")
    if j != want_joff:
        bad.append(b + ": -joff output differs from the issue's")
    if n != want_joff:
        bad.append(b + ": JIT output differs from -joff (the issue's -joff block)")
    fr2 = (rd(b + "-fr2.txt") or "").strip()
    exp = "0" if "nogc64" in b else "8"
    if fr2 != exp:
        bad.append(b + ": FR2 byte " + fr2 + ", expected " + exp)
    for f in ("repro", "konst"):
        jv = rd(b + "-" + f + ".jv") or ""
        tr = len(re.findall(r"^.TRACE +[0-9]+ ", jv, re.M))
        side = len(re.findall(r"^.TRACE +[0-9]+ [(]", jv, re.M))
        ab = jv.count("NYI: bytecode VARG")
        print("%-10s %-5s traces %d side %d VARG-aborts %d" % (b, f, tr, side, ab))
    print("%-10s konst joff/jit: %s / %s" % (b, (rd(b + "-konst-joff.txt") or "").strip(), (rd(b + "-konst-jon.txt") or "").strip()))
    s = rd(b + "-vsel/summary.txt") or ""
    ds = [int(m) for m in re.findall(r" diff=([0-9]+)", s)]
    jl = re.findall(r"joff rc=([0-9]+) lines=([0-9]+)", s)
    print("%-10s vsel: sets %d, diffs min %s max %s, joff %s" % (b, len(ds), min(ds) if ds else "-", max(ds) if ds else "-", jl))
    if len(ds) != 21:
        bad.append(b + ": vsel ran %d sets" % len(ds))
    if any(ds):
        bad.append(b + ": vsel differs from -joff")
for f in sorted(os.listdir(R)):
    if f.endswith(".rc"):
        v = (rd(f) or "").strip()
        if v != "0":
            bad.append(f + " = " + v)
for x in bad:
    print("FAIL", x)
print("checks:", "FAIL" if bad else "PASS")
sys.exit(1 if bad else 0)
