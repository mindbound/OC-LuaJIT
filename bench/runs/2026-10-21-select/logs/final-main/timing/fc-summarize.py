#!/usr/bin/env python3
"""fc-summarize.py <raw.txt> [--gross LO,HI]: the select round's smoke timing
summary (final-check.sh's timing part).

raw.txt holds one line per bench row per run:
  round=<r> pos=<p> vm=<base|new> <row> <ns per iteration> <result>
as fc-bench_sel.lua prints its rows (idx, cycle, beyond, vbeyond, konst, count).

Prints, per row, each build's median ns over the rounds and new/base per
round (median, min, max), then:
  RESULTS: EQUAL | RESULTS: DIFFER <rows>   every result of a row, in both
                                             builds and every round, the same
  GROSS: OK | FAIL <rows> | NONE <rows>      each row's median new/base within
                                             [LO, HI] (default 0.5,2.0): a smoke
                                             bound that only a gross change
                                             (a trace that always exits) fails;
                                             NONE where base reads 0 ns (a small
                                             N, below the clock's resolution)
  SUMMARY: OK | SUMMARY: FAIL <why>          the five rows for both builds in
                                             every round, no malformed line,
                                             results equal
Exit 0 when SUMMARY is OK (GROSS is reported, not part of the exit code;
final-check.sh reads it only at full N).  No backslashes in this file.
"""
import sys
from collections import defaultdict
from statistics import median

ROWS = ["idx", "cycle", "beyond", "vbeyond", "konst", "count"]

raw = sys.argv[1]
lo, hi = 0.5, 2.0
if len(sys.argv) > 3 and sys.argv[2] == "--gross":
    lo, hi = (float(x) for x in sys.argv[3].split(","))

ns = defaultdict(dict)          # row -> (round, vm) -> ns
res = defaultdict(set)          # row -> results seen
bad_lines = []
with open(raw, "r", encoding="utf-8", errors="replace", newline="") as f:
    for line in f.read().split(chr(10)):
        line = line.rstrip()
        if not line:
            continue
        t = line.split()
        try:
            assert t[0].startswith("round=") and t[1].startswith("pos=") and t[2].startswith("vm=")
            r = int(t[0][6:])
            vm = t[2][3:]
            assert vm in ("base", "new")
            row = t[3]
            assert row in ROWS and len(t) == 6
            v = float(t[4])
            ns[row][(r, vm)] = v
            res[row].add(t[5])
        except Exception:
            bad_lines.append(line)

why = []
differ = []
gross = []
noratio = []
allrounds = sorted({r for row in ns for r, _ in ns[row]})
for row in ROWS:
    d = ns.get(row, {})
    # Every round must hold the row for both builds.
    miss = [str(r) + v for r in allrounds for v in ("base", "new") if (r, v) not in d]
    if not d or miss:
        why.append("row %s incomplete (%s)" % (row, ",".join(miss) if d else "absent"))
        print("%-7s incomplete: %s" % (row, ",".join(miss) if d else "absent"))
        continue
    if len(res[row]) != 1:
        differ.append(row)
    rounds = sorted({r for r, _ in d})
    b = [d[(r, "base")] for r in rounds]
    n = [d[(r, "new")] for r in rounds]
    ratios = [d[(r, "new")] / d[(r, "base")] for r in rounds if d[(r, "base")] > 0]
    if not ratios:
        # Below the clock's resolution (a run at a small N): no ratio.
        noratio.append(row)
        print("%-7s base %.3f ns  new %.3f ns  no ratio (base reads 0)  result %s" % (
            row, median(b), median(n), ",".join(sorted(res[row]))))
        continue
    m = median(ratios)
    print("%-7s base %.3f ns  new %.3f ns  new/base median %.3f [%.3f-%.3f] over %d rounds  result %s" % (
        row, median(b), median(n), m, min(ratios), max(ratios), len(ratios), ",".join(sorted(res[row]))))
    if not (lo <= m <= hi):
        gross.append("%s=%.3f" % (row, m))
for l in bad_lines[:5]:
    print("MALFORMED: " + l)
if bad_lines:
    why.append("%d malformed lines" % len(bad_lines))
print("RESULTS: EQUAL" if not differ else "RESULTS: DIFFER " + " ".join(differ))
if gross:
    print("GROSS: FAIL " + " ".join(gross) + " (outside [%g, %g])" % (lo, hi))
elif noratio:
    print("GROSS: NONE (no ratio for %s: times below the clock's resolution)" % " ".join(noratio))
else:
    print("GROSS: OK (every row's median new/base within [%g, %g])" % (lo, hi))
if differ:
    why.append("results differ")
print("SUMMARY: OK" if not why else "SUMMARY: FAIL " + "; ".join(why))
sys.exit(0 if not why else 1)
