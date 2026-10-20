# b0sum.py <raw.txt> -- b0-companion.sh's summary: per metric, each VM's
# per-round ns and median, and each VM's ratio to b0 in the same round.
import re, statistics, sys
sys.stdout.reconfigure(encoding="utf-8")
HEAD = re.compile(r"^round=(\S+) pos=(\d+) vm=(\S+) bench=(\S+): (.*)$")
PAIR = re.compile(r"(?:^|[\s|])([A-Za-z][A-Za-z0-9-]*) ([0-9]+[.][0-9]+)")
VMS = ["b0", "base", "folda", "both"]
data = {}
rounds = []
bad = 0
for l in open(sys.argv[1], encoding="utf-8", errors="replace"):
    m = HEAD.match(l.rstrip("\n"))
    if not m:
        if l.strip():
            print("MALFORMED:", l[:200]); bad = 1
        continue
    rd, pos, vm, bench, text = m.groups()
    if "error" in text.lower() or "INSTRUMENT" in text:
        print("BENCH PROBLEM", rd, vm, bench, text[:200]); bad = 1
    if rd not in rounds:
        rounds.append(rd)
    for name, ns in PAIR.findall(text):
        if name == "ratio":
            continue
        data[(rd, vm, bench + ":" + name)] = float(ns)
metrics = sorted({k[2] for k in data})
print("b0 companion: %d rounds" % len(rounds))
print("%-22s %8s %8s %8s %8s   ratios to b0 in the same round: median [min-max]" % ("metric", *VMS))
for k in metrics:
    meds = []
    for vm in VMS:
        xs = [data[(rd, vm, k)] for rd in rounds if (rd, vm, k) in data]
        meds.append(statistics.median(xs) if xs else float("nan"))
    rat = []
    for vm in VMS[1:]:
        rs = [data[(rd, vm, k)] / data[(rd, "b0", k)] for rd in rounds
              if (rd, vm, k) in data and (rd, "b0", k) in data and data[(rd, "b0", k)] > 0]
        rat.append("%s %.2f [%.2f-%.2f]" % (vm, statistics.median(rs), min(rs), max(rs)) if rs else vm + " -")
    print("%-22s %8.2f %8.2f %8.2f %8.2f   %s" % (k, *meds, "  ".join(rat)))
print()
for k in metrics:
    for vm in VMS:
        print("  %-22s %-6s %s" % (k, vm, " ".join("%.2f" % data[(rd, vm, k)] for rd in rounds if (rd, vm, k) in data)))
sys.exit(bad)
