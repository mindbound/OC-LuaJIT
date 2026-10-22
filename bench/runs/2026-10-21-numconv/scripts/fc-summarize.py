#!/usr/bin/env python3
"""fc-summarize.py <raw.txt> [--gross LO,HI]: FIX-NUMCONV's smoke timing
summary (final-check.sh's timing part, scratch claude-tmp/oclj/numconv/fix).

raw.txt holds one line per bench output line per run:
  round=<r> pos=<p> vm=<base|new> bench=<ident|bench_numconv>: <the line>
ident.lua <N> time prints ten lines "<row><TAB><result><TAB><ns> ns/it"
(or0, andm1, xor0, shl0, shr0, each big and small); bench_numconv.lua <N>
prints one line "ref <ns> (r=<result>) | arith ... | key ... | bits ... |
floor ...".

Prints, per row, each build's median ns over the rounds and new/base per
round (median, min, max), then:
  RESULTS: EQUAL | RESULTS: DIFFER <rows>   every result of a row, in both
                                             builds and every round, the same
  GROSS: OK | FAIL <rows> | NONE <rows>      each row's median new/base within
                                             [LO, HI] (default 0.5,2.0): a smoke
                                             bound, no speed claim; NONE where
                                             base reads 0 ns (a small N)
  IDENT: median of the ten identity rows' median ratios (information only)
  SUMMARY: OK | SUMMARY: FAIL <why>          every row for both builds in every
                                             round, no malformed line, results
                                             equal
Exit 0 when SUMMARY is OK (GROSS is reported, not part of the exit code;
final-check.sh reads it only at full N).  No backslashes in this file.
"""
import sys
from collections import defaultdict
from statistics import median

TAB = chr(9)
IDENT_ROWS = [a + "-" + b for a in ("or0", "andm1", "xor0", "shl0", "shr0") for b in ("big", "small")]
NC_ROWS = ["ref", "arith", "key", "bits", "floor"]
ROWS = ["ident:" + r for r in IDENT_ROWS] + ["bench_numconv:" + r for r in NC_ROWS]

raw = sys.argv[1]
lo, hi = 0.5, 2.0
if len(sys.argv) > 3 and sys.argv[2] == "--gross":
    lo, hi = (float(x) for x in sys.argv[3].split(","))

ns = defaultdict(dict)          # row -> (round, vm) -> ns
res = defaultdict(set)          # row -> results seen
bad_lines = []


def parse_head(line):
    t = line.split(" ", 4)
    assert t[0].startswith("round=") and t[1].startswith("pos=") and t[2].startswith("vm=")
    assert t[3].startswith("bench=") and t[3].endswith(":")
    r = int(t[0][6:])
    vm = t[2][3:]
    assert vm in ("base", "new")
    return r, vm, t[3][6:-1], (t[4] if len(t) > 4 else "")


with open(raw, "r", encoding="utf-8", errors="replace", newline="") as f:
    for line in f.read().split(chr(10)):
        line = line.rstrip()
        if not line:
            continue
        try:
            r, vm, bench, text = parse_head(line)
            if bench == "ident":
                c = text.split(TAB)
                assert len(c) == 3 and c[2].endswith(" ns/it"), "ident line"
                row = "ident:" + c[0]
                assert row in ROWS
                ns[row][(r, vm)] = float(c[2][:-6])
                res[row].add(c[1])
            elif bench == "bench_numconv":
                parts = text.split(" | ")
                assert len(parts) == 5, "five rows"
                for p in parts:
                    name, v, rr = p.split(" ")
                    assert rr.startswith("(r=") and rr.endswith(")")
                    row = "bench_numconv:" + name
                    assert row in ROWS
                    ns[row][(r, vm)] = float(v)
                    res[row].add(rr[3:-1])
            else:
                raise AssertionError("unknown bench")
        except Exception:
            bad_lines.append(line)

why = []
differ = []
gross = []
noratio = []
identm = []
allrounds = sorted({r for row in ns for r, _ in ns[row]})
for row in ROWS:
    d = ns.get(row, {})
    miss = [str(r) + v for r in allrounds for v in ("base", "new") if (r, v) not in d]
    if not d or miss:
        why.append("row %s incomplete (%s)" % (row, ",".join(miss) if d else "absent"))
        print("%-20s incomplete: %s" % (row, ",".join(miss) if d else "absent"))
        continue
    if len(res[row]) != 1:
        differ.append(row)
    rounds = sorted({r for r, _ in d})
    b = [d[(r, "base")] for r in rounds]
    n = [d[(r, "new")] for r in rounds]
    ratios = [d[(r, "new")] / d[(r, "base")] for r in rounds if d[(r, "base")] > 0]
    if not ratios:
        noratio.append(row)
        print("%-20s base %.3f ns  new %.3f ns  no ratio (base reads 0)  result %s" % (
            row, median(b), median(n), ",".join(sorted(res[row]))))
        continue
    m = median(ratios)
    if row.startswith("ident:"):
        identm.append(m)
    print("%-20s base %.3f ns  new %.3f ns  new/base median %.3f [%.3f-%.3f] over %d rounds  result %s" % (
        row, median(b), median(n), m, min(ratios), max(ratios), len(ratios), ",".join(sorted(res[row]))))
    if not (lo <= m <= hi):
        gross.append("%s=%.3f" % (row, m))
for l in bad_lines[:5]:
    print("MALFORMED: " + l)
if bad_lines:
    why.append("%d malformed lines" % len(bad_lines))
if not allrounds:
    why.append("no rounds")
print("RESULTS: EQUAL" if not differ else "RESULTS: DIFFER " + " ".join(differ))
if gross:
    print("GROSS: FAIL " + " ".join(gross) + " (outside [%g, %g])" % (lo, hi))
elif noratio:
    print("GROSS: NONE (no ratio for %s: times below the clock's resolution)" % " ".join(noratio))
else:
    print("GROSS: OK (every row's median new/base within [%g, %g])" % (lo, hi))
if identm:
    print("IDENT: the ten identity rows' median new/base ratios have median %.3f [%.3f-%.3f] (information only)" % (
        median(identm), min(identm), max(identm)))
if differ:
    why.append("results differ")
print("SUMMARY: OK" if not why else "SUMMARY: FAIL " + "; ".join(why))
sys.exit(0 if not why else 1)
