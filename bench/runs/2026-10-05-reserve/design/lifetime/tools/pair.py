# pair.py <tagA> <tagB> : two censuses in this directory's out/, same caps: outside, sc, sc_out, held, identity.
import os, sys
HERE = os.path.dirname(os.path.abspath(__file__)); WD = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(WD)), "forensics")); import analyze
OUT = {2, 4, 5, 7}; SC = ("paint", "recorder", "unseen", "unseen-end", "hb")
def load(tag):
    t = {}
    for line in open(os.path.join(WD, "out", tag + ".tsv"), newline=""):
        c = line.rstrip("\n").split("\t"); t[int(c[0])] = c
    cl = {}
    for off in t:
        refs, _, _ = analyze.classify(analyze.parse_err(os.path.join(WD, "out", tag + ".err", "%d.err" % off)))
        ops = [r for r in refs if r.get("opened") == "1"]; op = ops[0] if ops else None
        cl[off] = (int(op is not None and op["absorber"] in SC), ",".join(r["absorber"] for r in refs), refs[-1] if refs else {})
    return t, cl
A, B = sys.argv[1], sys.argv[2]
ta, ca = load(A); tb, cb = load(B)
offs = sorted(o for o in ta if o in tb and len(ta[o]) >= 30 and len(tb[o]) >= 30)
def summ(t, c):
    n = len(offs); out = sum(int(t[o][8]) in OUT for o in offs); sc = sum(c[o][0] for o in offs)
    sco = sum(c[o][0] and int(t[o][8]) in OUT for o in offs); held = sum(int(t[o][9]) for o in offs) / n
    hsc = [int(t[o][9]) for o in offs if c[o][0]]
    return out, sc, sco, held, (sum(hsc) / len(hsc) if hsc else 0)
sa, sb = summ(ta, ca), summ(tb, cb)
ident = sum(ta[o][2:] == tb[o][2:] for o in offs); identb = sum(ta[o][2:] == tb[o][2:] for o in offs if not ca[o][0])
nb = sum(1 for o in offs if not ca[o][0])
print("%s vs %s: caps %d; identical %d (of A's non-sc caps %d/%d)" % (A, B, len(offs), ident, identb, nb))
print("  A: outside %d, sc %d, sc_out %d, held %.0f, held(sc caps) %.0f" % sa)
print("  B: outside %d, sc %d, sc_out %d, held %.0f, held(sc caps) %.0f" % sb)
for o in offs:
    if int(ta[o][8]) in OUT or int(tb[o][8]) in OUT:
        la, lb = ca[o][2], cb[o][2]
        print("  off %5d  A term %s [%s] at=%s over=%s | B term %s [%s] at=%s over=%s" % (
            o, ta[o][8], ca[o][1], la.get("at"), la.get("over"), tb[o][8], cb[o][1], lb.get("at"), lb.get("over")))
