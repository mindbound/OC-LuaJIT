"""analyze.py <chain1.log> -- the capacity matrix of 2026-10-03 as tables.

Arms: S stock PUC 5.2 (OC's kernel) | D ours as shipped | E ours, JIT off through
kernel init then on | O ours, JIT off throughout.  Sticks: one = 192 KB,
onehalf = 256 KB, threehalf = 1024 KB.  All at OC's ramScaleFor64Bit 1.8.

Every run is classified before anything is averaged:
  clean      the fill ended in a caught refusal and the machine kept running
             (the only runs whose `held` is a number)
  recovery   the program caught the refusal and dropped its data, then its own
             next allocation was refused (stuck at filling/N, OCLJCAPF written,
             machine up) -- held is bounded to N..N+99
  down       a refusal took the machine down (running=false)
  bootfail   OpenOS did not boot (no CAPACITY line)
Counters over the fill (arms, flushes) and the batch times are read from clean
runs only: in the other classes they include an up-to-250 s wait.
"""
import re, sys, statistics as st
from collections import defaultdict

log = open(sys.argv[1], encoding="utf-8").read().splitlines()
runs = {}
live, idle = {}, {}
for line in log:
    m = re.match(r"^(\S+) exit=(\S*) ?C?APACITY\| (.*)$", line)
    if m:
        runs[m.group(1)] = dict(re.findall(r"(\S+?)=(\S+)", m.group(3)))
        continue
    m = re.match(r"^(\S+) exit=(\S*)\s*$", line)
    if m:
        runs.setdefault(m.group(1), {"_bootfail": "1"})
        continue
    m = re.match(r"^\s+(\S+) CAP-LIVE\| (.*)$", line)
    if m:
        live[m.group(1)] = dict(re.findall(r"(\S+?)=(\S+)", m.group(2)))
        continue
    m = re.match(r"^\s+(\S+) CAP-IDLE\| (.*)$", line)
    if m:
        idle[m.group(1)] = dict(re.findall(r"(\S+?)=([+\-]?\S+)", m.group(2)))

def key(name):
    m = re.match(r"^(one|onehalf|threehalf)-(record|array|string|closure)-r(\d)-([SDEO])$", name)
    return m.groups() if m else None

def num(s, default=None):
    try:
        return float(str(s).lstrip("+"))
    except Exception:
        return default

def classify(kv):
    if kv.get("_bootfail"):
        return "bootfail"
    if kv.get("running") == "false":
        return "down"
    if num(kv.get("held")) is not None and "not_enough_memory" in kv.get("why", ""):
        return "clean"
    return "recovery"

cells = defaultdict(list)
for name, kv in runs.items():
    k = key(name)
    if k:
        tier, shape, rep, arm = k
        cells[(tier, shape, arm)].append((name, kv, classify(kv)))

TIERS = [("one", 192), ("onehalf", 256), ("threehalf", 1024)]
SHAPES = ["record", "array", "string", "closure"]
ARMS = ["S", "D", "E", "O"]

print("## Outcomes at OC's 1.8, by arm and stick\n")
print("| stick | arm | clean | recovery refused | machine down | boot failed |")
print("|---|---|---|---|---|---|")
for tier, kb in TIERS:
    for arm in ARMS:
        c = defaultdict(int)
        for shape in SHAPES:
            for _, kv, cl in cells.get((tier, shape, arm), []):
                c[cl] += 1
        print("| %d KB | %s | %d | %d | %d | %d |" % (kb, arm, c["clean"], c["recovery"], c["down"], c["bootfail"]))

print("\n## Objects held at the refusal (clean runs; min / median / max), our median over stock's\n")
print("A cell marked `+k` had k more runs that did not end cleanly (see the outcomes table); `-` with `+k` means "
      "no run in that cell ended cleanly.\n")
print("| stick | shape | stock S | ours D | ours E | ours O | D/S | E/S | O/S |")
print("|---|---|---|---|---|---|---|---|---|")
for tier, kb in TIERS:
    for shape in SHAPES:
        out, med = [], {}
        for arm in ARMS:
            vals, bad, lo, hi = [], 0, None, None
            for name, kv, cl in cells.get((tier, shape, arm), []):
                if cl == "clean":
                    vals.append(num(kv["held"]))
                else:
                    bad += 1
            txt = "-"
            if vals:
                med[arm] = st.median(vals)
                txt = ("%d / %d / %d" % (min(vals), med[arm], max(vals))) if len(vals) > 1 else "%d" % vals[0]
            if bad:
                txt += " +%d" % bad
            out.append(txt)
        r = lambda a: ("%.2f" % (med[a] / med["S"])) if a in med and med.get("S") else "-"
        print("| %d KB | %s | %s | %s | %s | %s |" % (kb, shape, " | ".join(out), r("D"), r("E"), r("O")))

print("\n## Post-boot live set after three full collects: user = used - kernelMemory (bytes)\n")
print("D's `user` under-reads at 192 and 256 KB: its kernelMemory holds trace metadata that kernel init compiled, "
      "which the pressure flush later released while OC's grant stayed.\n")
print("| stick | arm | user min / median / max | kernelMemory min / max | n |")
print("|---|---|---|---|---|")
for tier, kb in TIERS:
    for arm in ARMS:
        us, ks = [], []
        for name, kv in live.items():
            k = key(name)
            if k and k[0] == tier and k[3] == arm:
                us.append(num(kv.get("user"), 0)); ks.append(num(kv.get("kernelMemory"), 0))
        if us:
            print("| %d KB | %s | %d / %d / %d | %d / %d | %d |" % (kb, arm, min(us), st.median(us), max(us), min(ks), max(ks), len(us)))

print("\n## Near the wall, clean runs only: the last five batches' time (s, median), and over stock's\n")
print("The first-to-last ratio is not comparable across arms (the first batches start at different distances from "
      "the collector's knee, and with five or fewer batches both windows are the same batches); the absolute last-five "
      "time against stock's is.\n")
print("| stick | shape | S last5 | D last5 (x S) | E last5 (x S) | O last5 (x S) | D arms / flushes | O arms |")
print("|---|---|---|---|---|---|---|---|")
for tier, kb in TIERS:
    for shape in SHAPES:
        lt, ar, fl = {}, {}, {}
        for arm in ARMS:
            vs = [(num(kv.get("t_last5")), num(kv.get("arms")), num(kv.get("trace_flushes")))
                  for _, kv, cl in cells.get((tier, shape, arm), []) if cl == "clean"]
            vs = [v for v in vs if v[0] is not None]
            if vs:
                lt[arm] = st.median([v[0] for v in vs])
                if vs[0][1] is not None:
                    ar[arm] = st.median([v[1] for v in vs])
                if vs[0][2] is not None:
                    fl[arm] = st.median([v[2] for v in vs])
        def cell(a):
            if a not in lt: return "-"
            if a == "S" or not lt.get("S"): return "%.4f" % lt[a]
            return "%.4f (%.0f)" % (lt[a], lt[a] / lt["S"])
        print("| %d KB | %s | %s | %s | %s | %s | %s / %s | %s |" % (
            kb, shape, cell("S"), cell("D"), cell("E"), cell("O"),
            ("%d" % ar["D"]) if "D" in ar else "-", ("%d" % fl["D"]) if "D" in fl else "-",
            ("%d" % ar["O"]) if "O" in ar else "-"))

print("\n## Idle window, 400 ticks after boot, 192 KB (ours): collector arms and trace flushes (median, range)\n")
for arm in ["D", "E", "O"]:
    a = [num(v.get("arms")) for n, v in idle.items() if key(n) and key(n)[0] == "one" and key(n)[3] == arm]
    f = [num(v.get("trace_flushes")) for n, v in idle.items() if key(n) and key(n)[0] == "one" and key(n)[3] == arm]
    a = [x for x in a if x is not None]; f = [x for x in f if x is not None]
    if a:
        print("- %s: arms %d (%d..%d), trace flushes %d (%d..%d), n=%d" % (arm, st.median(a), min(a), max(a), st.median(f), min(f), max(f), len(a)))

print("\n## Every run that did not end cleanly\n")
for name in sorted(runs):
    kv = runs[name]
    cl = classify(kv) if key(name) else ("other: " + classify(kv))
    if cl != "clean" or not key(name):
        print("- %s: %s  held=%s why=%s running=%s lastError=%s" % (name, cl, kv.get("held"), kv.get("why"), kv.get("running"), kv.get("lastError")))
