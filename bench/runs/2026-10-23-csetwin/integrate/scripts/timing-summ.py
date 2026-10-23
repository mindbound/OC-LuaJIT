"""timing-summ.py <raw.txt> <rounds>: the CSE round's smoke timing summary
(integrate/scripts/timing.sh).  raw.txt holds one line per bench output
line per run:  round=<r> pos=<p> vm=<base|new> bench=<name>: <the line>
  bench_bit      bit X ns/it (r=R)  ref X ns/it (r=R)  ratio Y  crc X ns/byte (r=R)
  bench_bit2     rgb X ns (r=R) ref X ns (r=R) ratio Y | crc-table X ns/byte (r=R)
  ident          ten lines <row><TAB><result><TAB>X ns/it
  bench_numconv  ref X (r=R) | arith X (r=R) | key ... | bits ... | floor ...
Prints, per row, each build's median ns and new/base per round (median,
min, max), then
  RESULTS: EQUAL | DIFFER <rows>   every result of a row the same in both
                                   builds and every round
  GROSS: OK | FAIL <rows>          each row's median new/base in [0.5, 2.0]
                                   (a smoke bound, no speed claim)
  ALL: median of the rows' median ratios (information only)
  SUMMARY: OK | FAIL <why>         every row for both builds in every round,
                                   no malformed line, results equal
Exit 0 iff SUMMARY is OK.  No backslashes in this file."""
import sys
from collections import defaultdict
from statistics import median

TAB = chr(9)
raw, NR = sys.argv[1], int(sys.argv[2])
IDENT = [a + "-" + b for a in ("or0", "andm1", "xor0", "shl0", "shr0") for b in ("big", "small")]
ROWS = (["bench_bit:" + r for r in ("bit", "ref", "crc")] +
        ["bench_bit2:" + r for r in ("rgb", "ref", "crc-table")] +
        ["ident:" + r for r in IDENT] +
        ["bench_numconv:" + r for r in ("ref", "arith", "key", "bits", "floor")])
ns = defaultdict(dict)
res = defaultdict(set)
bad = []


def num(s):
    return float(s)


def pairs(body):
    """'name X [unit] (r=R)' groups, in order, from a bench_bit/bit2/numconv line."""
    out = []
    toks = body.replace("|", " ").split()
    i = 0
    while i < len(toks):
        t = toks[i]
        if i + 1 < len(toks):
            try:
                v = num(toks[i + 1])
            except ValueError:
                i += 1
                continue
            j = i + 2
            if j < len(toks) and toks[j].startswith("ns"):
                j += 1
            if j < len(toks) and toks[j].startswith("(r=") and toks[j].endswith(")"):
                out.append((t, v, toks[j][3:-1]))
                i = j + 1
                continue
        i += 1
    return out


for line in open(raw, "r", encoding="utf-8", errors="replace", newline="").read().split(chr(10)):
    line = line.rstrip()
    if not line:
        continue
    try:
        h = line.split(" ", 4)
        r = int(h[0][6:]); vm = h[2][3:]; bench = h[3][6:-1]; body = h[4] if len(h) > 4 else ""
        assert h[0].startswith("round=") and h[2].startswith("vm=") and vm in ("base", "new")
        if bench == "ident":
            f = body.split(TAB)
            assert len(f) == 3 and f[2].endswith(" ns/it"), "ident line"
            got = [(f[0], num(f[2][:-6]), f[1])]
        else:
            got = pairs(body)
            assert got, "no rows"
        for name, v, rr in got:
            key = bench + ":" + name
            assert key in ROWS, "unknown row " + key
            ns[key][(r, vm)] = v
            res[key].add(rr)
    except Exception as e:
        bad.append(line[:120] + " :: " + str(e))

ratios_all = []
gross_bad = []
missing = []
for key in ROWS:
    b = [ns[key].get((r, "base")) for r in range(1, NR + 1)]
    n = [ns[key].get((r, "new")) for r in range(1, NR + 1)]
    if None in b or None in n:
        missing.append(key)
        print("%-24s MISSING rounds" % key)
        continue
    rat = [x / y for x, y in zip(n, b) if y > 0]
    mr = median(rat) if rat else float("nan")
    ratios_all.append(mr)
    if not (0.5 <= mr <= 2.0):
        gross_bad.append(key)
    print("%-24s base %.3f ns  new %.3f ns  new/base median %.3f [%.3f-%.3f] over %d rounds  result %s" % (
        key, median(b), median(n), mr, min(rat), max(rat), len(rat), ",".join(sorted(res[key]))))
differ = [k for k in ROWS if len(res[k]) != 1]
print("RESULTS: " + ("EQUAL" if not differ else "DIFFER " + " ".join(differ)))
print("GROSS: " + ("OK (every row's median new/base within [0.5, 2])" if not gross_bad else "FAIL " + " ".join(gross_bad)))
if ratios_all:
    print("ALL: the %d rows' median new/base ratios have median %.3f [%.3f-%.3f] (information only)" % (
        len(ratios_all), median(ratios_all), min(ratios_all), max(ratios_all)))
for x in bad:
    print("MALFORMED: " + x)
why = []
if missing:
    why.append("missing " + " ".join(missing))
if bad:
    why.append("%d malformed lines" % len(bad))
if differ:
    why.append("results differ")
print("SUMMARY: " + ("OK" if not why else "FAIL " + "; ".join(why)))
sys.exit(0 if not why else 1)
