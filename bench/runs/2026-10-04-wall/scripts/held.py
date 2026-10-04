"""held.py <chain.log> -- objects held at the refusal, clean runs, median per cell, and over stock's."""
import re, sys, statistics as st
from collections import defaultdict
runs = {}
for line in open(sys.argv[1], encoding="utf-8").read().splitlines():
    m = re.match(r"^(\S+) exit=(\S*) ?C?APACITY\| (.*)$", line)
    if m:
        runs[m.group(1)] = dict(re.findall(r"(\S+?)=(\S+)", m.group(3)))
cells = defaultdict(list)
for name, kv in runs.items():
    m = re.match(r"^(one|onehalf|threehalf)-(record|array|string|closure)-r(\d)-([SDEOL])-(\w+)$", name)
    if not m:
        continue
    tier, shape, rep, arm, build = m.groups()
    try:
        held = float(kv.get("held"))
    except Exception:
        continue
    if kv.get("running") == "true" and "not_enough_memory" in kv.get("why", ""):
        cells[(tier, shape, arm)].append(held)
print("| stick | shape | S | D (x S) | E (x S) | O (x S) | L (x S) |")
print("|---|---|---|---|---|---|---|")
for tier, kb in [("one", 192), ("onehalf", 256), ("threehalf", 1024)]:
    for shape in ["record", "array", "string", "closure"]:
        med = {a: st.median(v) for a in "SDEOL" for v in [cells.get((tier, shape, a), [])] if v}
        if not med:
            continue
        def c(a):
            if a not in med: return "-"
            if a == "S" or "S" not in med: return "%d" % med[a]
            return "%d (%.2f)" % (med[a], med[a] / med["S"])
        print("| %d KB | %s | %s |" % (kb, shape, " | ".join(c(a) for a in "SDEOL")))
