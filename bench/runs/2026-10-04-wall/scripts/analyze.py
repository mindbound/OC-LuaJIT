"""analyze.py <chain.log> [...] -- capacity runs of the collector-at-the-wall work as tables.

Run names: <stick>-<shape>-r<rep>-<arm>-<build>, stick one (192 KB) | onehalf (256 KB) |
threehalf (1024 KB); arm S stock PUC 5.2 | D ours as shipped | E ours, JIT off through
kernel init then on | O ours, JIT off throughout | L the dropin (OC's own LuaState class,
the shim's legacy path); build base (cb29485d, 2026-10-03) | A (park reset) | B (credit and
cadence) | ... ; stock runs carry build "stock".

Every run is classified before anything is averaged (as 2026-10-03's analyze.py):
  clean      the fill ended in a caught refusal and the machine kept running
  recovery   the program caught the refusal and dropped its data, then its own next
             allocation was refused (stuck at filling/N, machine up, OCLJCAPF written)
  stalled    stuck at filling/N with the machine up and OCLJCAPF never written: the
             refusal landed in the probe's own code outside its pcall (the stage
             string, event.timer), so its timer chain broke before the handler ran
  down       a refusal took the machine down (running=false)
  bootfail   OpenOS did not boot (no CAPACITY line)
Counters over the fill and the batch times come from clean runs only: in the other
classes they include an up-to-200 s wait.
"""
import re, sys, statistics as st
from collections import defaultdict

runs, live, idle, mid, gc = {}, {}, {}, {}, {}
for path in sys.argv[1:]:
    for line in open(path, encoding="utf-8").read().splitlines():
        m = re.match(r"^(\S+) exit=(\S*) ?C?APACITY\| (.*)$", line)
        if m:
            runs[m.group(1)] = dict(re.findall(r"(\S+?)=(\S+)", m.group(3)))
            continue
        m = re.match(r"^(\S+) exit=(\S*)\s*$", line)
        if m:
            runs.setdefault(m.group(1), {"_bootfail": "1"})
            continue
        for tag, store in (("CAP-LIVE", live), ("CAP-IDLE", idle), ("CAP-MID", mid), ("CAP-GC", gc)):
            m = re.match(r"^\s+(\S+) " + tag + r"\| (.*)$", line)
            if m:
                store[m.group(1)] = dict(re.findall(r"(\S+?)=([+\-]?\S+)", m.group(2)))

def key(name):
    m = re.match(r"^(one|onehalf|threehalf)-(record|array|string|closure)-r(\d)-([SDEOL])-(\w+)$", name)
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
    if kv.get("freeKB_at_end/totalKB") == "-1/-1":
        return "stalled"
    return "recovery"

TIERS = [("one", 192), ("onehalf", 256), ("threehalf", 1024)]
SHAPES = ["record", "array", "string", "closure"]
cells = defaultdict(list)
groups = []
for name, kv in runs.items():
    k = key(name)
    if not k:
        continue
    tier, shape, rep, arm, build = k
    cells[(tier, arm, build)].append((name, shape, kv, classify(kv)))
    if (arm, build) not in groups:
        groups.append((arm, build))
order = {"S": 0, "D": 1, "E": 2, "O": 3, "L": 4}
groups.sort(key=lambda g: (order[g[0]], g[1]))

print("## Outcomes, by stick, arm and build\n")
print("| stick | arm | build | clean | recovery refused | stalled | machine down | boot failed |")
print("|---|---|---|---|---|---|---|---|")
for tier, kb in TIERS:
    for arm, build in groups:
        rs = cells.get((tier, arm, build), [])
        if not rs:
            continue
        c = defaultdict(int)
        for _, _, _, cl in rs:
            c[cl] += 1
        print("| %d KB | %s | %s | %d | %d | %d | %d | %d |" % (kb, arm, build, c["clean"], c["recovery"], c["stalled"], c["down"], c["bootfail"]))

print("\n## The collector over the fill (ours): medians over clean runs, and the park fingerprint over ALL runs\n")
print("`arms/batch` is the fill's arms over its batches; `parked runs` counts runs whose fill snapshots (CAP-MID, "
      "every tick) read the park: armed, at the pause, stepmul 0, threshold past gc.total.  Chain A's harness "
      "counted a snapshot taken after the machine went down too; later chains count running snapshots only. "
      "The end state after a machine went down is listed with the unclean runs, not counted here. "
      "`od_peak` must stay within `od_limit` (the sandbox's G) plus the kernel's 16 KB slice and the "
      "1.5 KB norefuse window.\n")
print("| stick | arm | build | n clean | arms/batch | collects | bailouts (all runs) | park resets | overdrafts | od_peak max / od_limit | parked runs |")
print("|---|---|---|---|---|---|---|---|---|---|---|")
for tier, kb in TIERS:
    for arm, build in groups:
        if arm == "S":
            continue
        rs = cells.get((tier, arm, build), [])
        if not rs:
            continue
        clean = [(n, kv) for n, _, kv, cl in rs if cl == "clean"]
        apb = [num(kv.get("arms"), 0) / max(1.0, num(kv.get("batches"), 1)) for n, kv in clean]
        col = [num(gc.get(n, {}).get("collects")) for n, kv in clean]
        col = [x for x in col if x is not None]
        bail = sum(num(gc.get(n, {}).get("bailouts"), 0) or 0 for n, _, _, _ in rs)
        pr = [num(gc.get(n, {}).get("park_resets")) for n, kv in clean]
        pr = [x for x in pr if x is not None]
        od = [num(gc.get(n, {}).get("overdrafts")) for n, kv in clean]
        od = [x for x in od if x is not None]
        pk = [num(gc.get(n, {}).get("od_peak")) for n, _, _, _ in rs]
        pk = [x for x in pk if x is not None]
        lim = [num(gc.get(n, {}).get("od_limit")) for n, _, _, _ in rs]
        lim = [x for x in lim if x is not None]
        parked = 0
        for n, _, _, _ in rs:
            if num(mid.get(n, {}).get("parked"), 0):
                parked += 1
        f = lambda v: ("%.0f" % st.median(v)) if v else "n/a"
        print("| %d KB | %s | %s | %d | %s | %s | %d | %s | %s | %s / %s | %d of %d |" % (
            kb, arm, build, len(clean), ("%.1f" % st.median(apb)) if apb else "-", f(col), bail, f(pr), f(od),
            ("%.0f" % max(pk)) if pk else "n/a", ("%.0f" % max(lim)) if lim else "n/a", parked, len(rs)))

print("\n## Near the wall, clean runs only: the last five batches' time (s, median), and over stock's in the same chain\n")
print("| stick | shape | " + " | ".join("%s/%s" % g for g in groups) + " |")
print("|---|---|" + "---|" * len(groups))
for tier, kb in TIERS:
    for shape in SHAPES:
        lt = {}
        for g in groups:
            vs = [num(kv.get("t_last5")) for n, sh, kv, cl in cells.get((tier,) + g, []) if sh == shape and cl == "clean"]
            vs = [v for v in vs if v is not None]
            if vs:
                lt[g] = st.median(vs)
        if not lt:
            continue
        s = [lt[g] for g in lt if g[0] == "S"]
        sref = s[0] if s else None
        out = []
        for g in groups:
            if g not in lt:
                out.append("-")
            elif g[0] == "S" or not sref:
                out.append("%.4f" % lt[g])
            else:
                out.append("%.4f (%.1fx)" % (lt[g], lt[g] / sref))
        print("| %d KB | %s | %s |" % (kb, shape, " | ".join(out)))

print("\n## Idle window, 400 ticks after boot (ours): arms, collects, trace flushes, park resets (median, range)\n")
for tier, kb in TIERS:
    for arm, build in groups:
        if arm == "S":
            continue
        ns = [n for n in idle if key(n) and key(n)[0] == tier and key(n)[3] == arm and key(n)[4] == build]
        if not ns:
            continue
        def rng(field):
            v = [num(idle[n].get(field)) for n in ns]
            v = [x for x in v if x is not None]
            return ("%d (%d..%d)" % (st.median(v), min(v), max(v))) if v else "n/a"
        print("- %d KB %s/%s: arms %s, collects %s, trace flushes %s, park resets %s; kernelMemory %s; n=%d" % (
            kb, arm, build, rng("arms"), rng("collects"), rng("trace_flushes"), rng("park_resets"),
            "/".join(sorted(set(live.get(n, {}).get("kernelMemory", "?") for n in ns))), len(ns)))

print("\n## Every run that did not end cleanly\n")
for name in sorted(runs):
    kv = runs[name]
    if not key(name):
        continue
    cl = classify(kv)
    if cl != "clean":
        g = gc.get(name, {})
        print("- %s: %s  held=%s why=%s running=%s lastError=%s; parked(mid/end)=%s/%s; collects=%s bailouts=%s" % (
            name, cl, kv.get("held"), kv.get("why"), kv.get("running"), kv.get("lastError"),
            mid.get(name, {}).get("parked", "?"), g.get("parked", "?"), g.get("collects", "?"), g.get("bailouts", "?")))
