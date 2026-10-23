"""fc-basecse.py <run dir> <base|new> -- the CSE type twin round's final
check: read run-bitjit.sh's part cse output (<run dir>/cse/: t_csefwd-,
cseir- and t_cserev-<set>.txt) case by case, as a build without the fix
(base: build/native at 1a13bed) or with it (new) must read.

new: t_csefwd's 32 cases right in all 15 sets; cseir's 32 cases ok in all
     12 of its sets, served 0, i64slot 0, every pair judged in the default
     set (20 of 20) and copy's and side's split at least 1 there;
     t_cserev's 8 cases ok in all 15, rserved 0, i64slot 0, its 4 reverse
     cases judged in the default set with split at least 1.
base: t_csefwd: the eleven cases of its first list (FIRST11) wrong in each
     of the 10 sets with fold, CSE and narrowing on; copy wrong in the 9 of
     them with the loop optimisation on and right in every other set;
     u8sh30 wrong under -O1 and -O-narrow, where nothing but u8sh30 and side
     is wrong; nothing wrong under -O0, -O-fold and -O-cse; the second list
     (EQ7) and the controls right everywhere; side wrong in the default set
     (elsewhere its value depends on whether a trace compiles its branch,
     which varied between runs: reported, not judged).  cseir: FIRST11 and
     EQ7 FAILED in each of the 10, copy in the 9, u8sh30 under -O1 and
     -O-narrow, every FAILED pair or eq case with served at least 1, no
     control FAILED.  t_cserev: its 4 reverse cases FAILED in each of the
     10 with rserved at least 1 and split 0, its controls ok, every value
     right.
Both: every cseir and t_cserev line reads i64slot 0 (no int64 instruction
in a snapshot), and t_cserev's cases are exactly its eight (the two no-slot
reverse shapes and their controls; the user's decision D2).
Prints one line per finding and a verdict; exit 0 iff it holds."""
import os, re, sys

RUN, MODE = sys.argv[1], sys.argv[2]
assert MODE in ("base", "new")
D = os.path.join(RUN, "cse")
SEL15 = "jon O0 O1 hl1 ms0 he1 noloop nofold nocse hx1 ts1 mx1 hl1ms0 noabc nonarrow".split()
NARROW10 = "jon hl1 ms0 he1 noloop hx1 ts1 mx1 hl1ms0 noabc".split()
LOOP9 = [s for s in NARROW10 if s != "noloop"]
NONARROW2 = ["O1", "nonarrow"]
NOPAIR3 = ["O0", "nofold", "nocse"]
CSEIR12 = NARROW10 + NONARROW2
FIRST11 = "lsh3 bnot bnotx bxorm1 lsh35 u8sh30 nested reassoc chain vlsh vrsh".split()
EQ7 = "lsh1 band rsh5 select byte2 sub2 forin".split()
CTRL = "ctl-shl3 ctl-bnot ctl-shl1 ctl-shr5 ctl-band ctl-vshl ctl-copy ctl-side bit-lsh3 same-bit same-53 c1".split()
ALL32 = set(FIRST11 + ["copy", "side"] + EQ7 + CTRL)
REV4 = "r5-sel r6-byte r6-sub r6-mul".split()
REVCTL = "rc-sel rc-shl1 rp-sel rp-byte".split()

bad = []
def need(cond, msg):
    if not cond:
        bad.append(msg)

def read(name):
    p = os.path.join(D, name)
    if not os.path.exists(p):
        bad.append("missing " + name)
        return []
    with open(p, "rb") as f:
        return [l for l in f.read().decode("latin-1").replace("\r", "").split("\n") if l]

def cases(lines):
    out = {}
    for l in lines:
        if "\t" in l:
            out[l.split("\t", 1)[0]] = l
    return out

def wrong(line):
    return re.search(r"\bb?bad=[1-9]", line) is not None

def field(line, k):
    m = re.search(r"\b" + k + r"=(\d+)", line)
    return int(m.group(1)) if m else None

# t_csefwd, every set.
fw = {s: cases(read("t_csefwd-%s.txt" % s)) for s in SEL15}
for s in SEL15:
    need(set(fw[s]) == ALL32, "t_csefwd-%s: its case list is not the 32 cases (%d read)" % (s, len(fw[s])))
    W = {c for c, l in fw[s].items() if wrong(l)}
    if MODE == "new":
        need(not W, "t_csefwd-%s: wrong on the fixed build: %s" % (s, " ".join(sorted(W))))
        continue
    if s in NARROW10:
        need(set(FIRST11) <= W, "t_csefwd-%s: FIRST11 not all wrong (missing %s)" % (s, " ".join(sorted(set(FIRST11) - W))))
    if s in LOOP9:
        need("copy" in W, "t_csefwd-%s: copy right, the loop copy's pair not served" % s)
    else:
        need("copy" not in W, "t_csefwd-%s: copy wrong where its pair cannot form" % s)
    if s in NONARROW2:
        need("u8sh30" in W and W <= {"u8sh30", "side"}, "t_csefwd-%s: wrong set %s, want u8sh30 (and side)" % (s, " ".join(sorted(W))))
    if s in NOPAIR3:
        need(not W, "t_csefwd-%s: wrong where no pair forms: %s" % (s, " ".join(sorted(W))))
    need(not (W & set(EQ7 + CTRL)), "t_csefwd-%s: a value-right case or a control is wrong: %s" % (s, " ".join(sorted(W & set(EQ7 + CTRL)))))
if MODE == "base":
    need("side" in {c for c, l in fw["jon"].items() if wrong(l)}, "t_csefwd-jon: side right in the default set")
    sides = [s for s in SEL15 if "side" in fw[s] and wrong(fw[s]["side"])]
    print("t_csefwd side wrong in: " + " ".join(sides) + " (reported, not judged but in jon)")

# cseir, every set it runs.
for s in CSEIR12:
    L = read("cseir-%s.txt" % s)
    C = cases(L)
    need(set(C) == ALL32, "cseir-%s: its case list is not the 32 cases (%d read)" % (s, len(C)))
    summ = [l for l in L if l.startswith("cseir: ")]
    need(len(summ) == 1, "cseir-%s: no summary line" % s)
    F = {c for c, l in C.items() if "FAILED" in l}
    for c, l in C.items():
        need(field(l, "i64slot") == 0, "cseir-%s %s: i64slot %s" % (s, c, field(l, "i64slot")))
        need(field(l, "rserved") == 0, "cseir-%s %s: rserved %s" % (s, c, field(l, "rserved")))
    if MODE == "new":
        need(not F, "cseir-%s: FAILED on the fixed build: %s" % (s, " ".join(sorted(F))))
        for c, l in C.items():
            need(field(l, "served") == 0, "cseir-%s %s: served %s on the fixed build" % (s, c, field(l, "served")))
        if s == "jon":
            need(summ and summ[0].endswith("pairs judged 20 of 20"), "cseir-jon: not every pair judged: %s" % (summ[0] if summ else "-"))
            for c in ("copy", "side"):
                need((field(C.get(c, ""), "split") or 0) >= 1, "cseir-jon %s: split 0" % c)
        continue
    need(not (F & set(CTRL)), "cseir-%s: a control FAILED: %s" % (s, " ".join(sorted(F & set(CTRL)))))
    for c in F & set(FIRST11 + EQ7 + ["copy", "side"]):
        need((field(C[c], "served") or 0) >= 1, "cseir-%s %s: FAILED with served 0" % (s, c))
    if s in NARROW10:
        need(set(FIRST11 + EQ7) <= F, "cseir-%s: not FAILED: %s" % (s, " ".join(sorted(set(FIRST11 + EQ7) - F))))
    if s in LOOP9:
        need("copy" in F, "cseir-%s: copy not FAILED" % s)
    if s in NONARROW2:
        need("u8sh30" in F, "cseir-%s: u8sh30 not FAILED" % s)

# t_cserev, every set.
for s in SEL15:
    L = read("t_cserev-%s.txt" % s)
    C = cases(L)
    need(set(C) == set(REV4 + REVCTL), "t_cserev-%s: its cases are not exactly its eight: %s" % (s, " ".join(sorted(C))))
    F = {c for c, l in C.items() if "FAILED" in l}
    for c, l in C.items():
        need(field(l, "i64slot") in (0, None), "t_cserev-%s %s: i64slot %s" % (s, c, field(l, "i64slot")))
        need(not wrong(l), "t_cserev-%s %s: a value unlike the reference" % (s, c))
    need(not (F & set(REVCTL)), "t_cserev-%s: a control FAILED: %s" % (s, " ".join(sorted(F & set(REVCTL)))))
    if MODE == "new":
        need(not F, "t_cserev-%s: FAILED on the fixed build: %s" % (s, " ".join(sorted(F))))
        for c, l in C.items():
            need(field(l, "rserved") in (0, None), "t_cserev-%s %s: rserved on the fixed build" % (s, c))
        if s == "jon":
            summ = [l for l in L if l.startswith("t_cserev: ")]
            need(summ and summ[0].endswith("reverse cases judged 4 of 4"), "t_cserev-jon: not every reverse case judged")
            for c in REV4:
                need((field(C.get(c, ""), "split") or 0) >= 1, "t_cserev-jon %s: split 0" % c)
    elif s in NARROW10:
        need(set(REV4) <= F, "t_cserev-%s: reverse cases not FAILED: %s" % (s, " ".join(sorted(set(REV4) - F))))
        for c in REV4:
            l = C.get(c, "")
            need((field(l, "rserved") or 0) >= 1 and field(l, "split") == 0, "t_cserev-%s %s: not rserved with split 0" % (s, c))

for b in bad:
    print("BAD " + b)
print("BASECSE %s %s: %s (%d findings)" % (MODE, RUN, "PASS" if not bad else "FAIL", len(bad)))
sys.exit(0 if not bad else 1)
