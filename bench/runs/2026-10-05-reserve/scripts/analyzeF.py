# analyzeF.py [runsF dir] -- THE RESERVE'S SIZE's in-machine gate (d3-final section 5.4), read from
# the chain's run directories: per run the harness lines (CAPACITY, CAP-GC, CAP-IDLE, CAP-X, CAP-LIVE)
# and the instrumented native's OCLJREF / OCLJPRF / OCLJXP stderr lines.  Prints every criterion with
# the figures it rests on; judges nothing silently.  Partial chains are fine (it reports what exists).
import os, re, sys, glob, statistics
from collections import Counter, defaultdict

ROOT = sys.argv[1] if len(sys.argv) > 1 else "C:/Users/astro/AppData/Local/Temp/claude/C--Users-astro-Downloads-OC-LuaJIT/b3c2bf14-9324-494a-a9cb-2700e7c43afc/scratchpad/wall2/runsF"
L, R, LEND, KSL = 4096, 8192, 4096, 16384

def kv(line, key, cast=float, default=None):
    m = re.search(r'(?:^|[ |])' + re.escape(key) + r'=\+?(-?[0-9.]+)', line)
    return cast(m.group(1)) if m else default

def parse_run(d):
    name = os.path.basename(os.path.normpath(d))
    p = os.path.join(d, "run.log")
    if not os.path.exists(p): return None
    r = {"name": name, "refs": [], "prfs": [], "xps": [], "class": "?", "exit": None}
    try: r["exit"] = open(os.path.join(d, "exit.txt")).read().strip()
    except Exception: pass
    for line in open(p, encoding="utf-8", errors="replace"):
        if "OCLJREF|" in line:
            r["refs"].append(dict(x.split("=", 1) for x in line.split("OCLJREF|", 1)[1].split() if "=" in x))
        elif "OCLJPRF|" in line:
            r["prfs"].append(dict(x.split("=", 1) for x in line.split("OCLJPRF|", 1)[1].split() if "=" in x))
        elif "OCLJXP|" in line:
            r["xps"].append(dict(x.split("=", 1) for x in line.split("OCLJXP|", 1)[1].split() if "=" in x))
        elif "SMOKE| CAPACITY|" in line:
            r["held"] = kv(line, "held", int); r["t5"] = kv(line, "t_last5"); r["refusals"] = kv(line, "refusals", int)
            r["why"] = (re.search(r'why=(\S+)', line) or [None, "?"])[1]
            r["jit"] = (re.search(r'jit=(\S+)', line) or [None, "?"])[1]
            r["shape"] = (re.search(r'shape=(\S+)', line) or [None, "?"])[1]
            r["native"] = (re.search(r'native=(\S+)', line) or [None, "?"])[1]
            r["tier"] = (re.search(r'tier=(\S+)', line) or [None, "?"])[1]
        elif "SMOKE| CAP-GC|" in line:
            r["od_peak"] = kv(line, "od_peak", int); r["G"] = kv(line, "od_limit", int); r["collects"] = kv(line, "collects", int)
        elif "SMOKE| CAP-IDLE|" in line:
            r["idle_arms"] = kv(line, "arms", int); r["idle_ref"] = kv(line, "refusals", int)
        elif "SMOKE| CAP-LIVE|" in line:
            r["total"] = kv(line, "total", int)
        elif "SMOKE| CAP-X|" in line:
            m = re.search(r'OCLJCAPX=([0-9/]+)', line)
            f = (m.group(1).split("/") if m else [])
            r["pf"] = int(f[2]) if len(f) > 2 else -1; r["oe"] = int(f[3]) if len(f) > 3 else -1
            r["rr"] = int(f[4]) if len(f) > 4 else -1
            r["class"] = (re.search(r'class=([A-Z-]+)', line) or [None, "?"])[1]
            r["site"] = (re.search(r'site=(\S+)', line) or [None, "?"])[1]
    # the name's build letter: ...-E-D / -F-D / -S-stock etc.
    last = name.rsplit("-", 1)[-1]
    r["build"] = "S" if last == "stock" else last if last in ("E", "F") else "?"
    r["cell"] = re.sub(r'-r\d+-', "-", name).rsplit("-", 1)[0]
    return r

def nz(v, d=0):
    return d if v is None else v

def sc_flag(r):
    refs = r["refs"]
    if not refs: return False
    at1 = refs[0].get("at", "")
    return at1.startswith("=machine") or (r.get("pf", -1) >= 0 and len(refs) >= r["pf"] + 2 and len(refs) >= 2)

def section(title): print("\n== " + title)

def gate(runs):
    E = [r for r in runs if r["build"] == "E"]; F = [r for r in runs if r["build"] == "F"]
    section("(1) THE BOUND: od_peak per run (F must be <= G/2 + R + 2L = %d unless the kernel exception; E teeth >= 10 over)" % (16384 + R + 2 * L))
    for tag, rs in (("F", F), ("E", E)):
        over = exc = 0; worst = (0, "")
        for r in rs:
            if r.get("od_peak") is None: continue
            G = nz(r.get("G"), 32768); bound = G // 2 + R + 2 * L
            first = r["refs"][0] if r["refs"] else {}
            total = nz(r.get("total"), 0)
            exception = first.get("kernel") == "1" or (total and int(first.get("used", 0)) > total + G // 2 + L)
            if r["od_peak"] > bound:
                if exception and r["od_peak"] <= G + L: exc += 1
                else: over += 1
            if r["od_peak"] > worst[0]: worst = (r["od_peak"], r["name"])
        print("  %s: runs %d, past the new bound %d (kernel exception %d); worst od_peak %d (%s)" % (tag, len(rs), over, exc, worst[0], worst[1]))
    section("(2) THE CREEP: used at the last refusal - used at the first (F <= R + 2L + delta = %d + delta); the sizing's rsv in [%d, %d]" % (R + 2 * L, 16384 + R, 16384 + R + L))
    for tag, rs in (("F", F), ("E", E)):
        n = bad = 0; creeps = []; rsvbad = 0; rsvs = []
        for r in rs:
            refs = r["refs"]
            if len(refs) >= 2:
                n += 1; creep = int(refs[-1]["used"]) - int(refs[0]["used"]); creeps.append(creep)
                if creep > R + 2 * L + int(refs[-1]["delta"]): bad += 1
            for x in r["xps"]:
                if x.get("kind", "rsv") == "rsv":
                    v = int(x["rsv"]); rsvs.append(v)
                    G = nz(r.get("G"), 32768)
                    first = refs[0] if refs else {}
                    total = nz(r.get("total"), 0)
                    exception = first.get("kernel") == "1" or (total and int(first.get("used", 0)) > total + G // 2 + L)
                    if not (G // 2 + R <= v <= G // 2 + R + L) and not exception: rsvbad += 1
        print("  %s: runs with >= 2 refusals %d, creep past the bound %d; creep median %s max %s; sizings %d, outside [G/2+R, +L] %d" %
              (tag, n, bad, statistics.median(creeps) if creeps else "-", max(creeps) if creeps else "-", len(rsvs), rsvbad))
    section("(3) BAD OUTCOMES per build (F's STALL+DOWN <= E's + 3), second-chance incidence, refusals per run")
    for tag, rs in (("E", E), ("F", F)):
        cls = Counter(r["class"] for r in rs)
        sc = sum(1 for r in rs if sc_flag(r))
        dist = Counter(len(r["refs"]) for r in rs)
        drec = [r for r in rs if r["cell"].startswith("g-record") and r["jit"] == "on" and r["native"] == "additive"]
        screc = sum(1 for r in drec if sc_flag(r))
        print("  %s: %s; second chances %d of %d (D record: %d of %d); refusals/run %s" %
              (tag, dict(cls), sc, len(rs), screc, len(drec), dict(sorted(dist.items()))))
        for r in rs:
            if r["class"] not in ("CLEAN", "?"):
                seq = " | ".join("%s:%sB t%s>%s w%s at=%s" % (x["seq"], x["delta"], x["tier0"], x["tier1"], x.get("win0"), x.get("at")) for x in r["refs"])
                print("     BAD %s class=%s site=%s pf=%s refs=%d: %s" % (r["name"], r["class"], r.get("site"), r.get("pf"), len(r["refs"]), seq[:300]))
    section("(4) CAPACITY: held per cell, F against E and stock; second-chance runs' held")
    cells = sorted(set(r["cell"] for r in runs))
    for c in cells:
        row = []
        for tag in ("S", "E", "F"):
            hs = [r["held"] for r in runs if r["cell"] == c and r["build"] == tag and r.get("held") is not None]
            if hs: row.append("%s med %d (n %d, %d-%d)" % (tag, statistics.median(hs), len(hs), min(hs), max(hs)))
        if row: print("  %-28s %s" % (c, "; ".join(row)))
    for tag in ("E", "F"):
        hs = [r["held"] for r in runs if r["build"] == tag and sc_flag(r) and r.get("held") is not None and r["cell"].startswith("g-")]
        h1 = [r["held"] for r in runs if r["build"] == tag and not sc_flag(r) and r.get("held") is not None and r["cell"].startswith("g-")]
        print("  %s amplified: second-chance runs held med %s (n %d); single-refusal runs med %s (n %d)" %
              (tag, statistics.median(hs) if hs else "-", len(hs), statistics.median(h1) if h1 else "-", len(h1)))
    section("(6) COST: t_last5 F/E per cell (<= 1.10); idle arms per window; idle refusals")
    for c in cells:
        te = [r["t5"] for r in runs if r["cell"] == c and r["build"] == "E" and r.get("t5")]
        tf = [r["t5"] for r in runs if r["cell"] == c and r["build"] == "F" and r.get("t5")]
        ia = {tag: [r["idle_arms"] for r in runs if r["cell"] == c and r["build"] == tag and r.get("idle_arms") is not None] for tag in ("E", "F")}
        ir = sum(nz(r.get("idle_ref")) for r in runs if r["cell"] == c)
        if te and tf:
            print("  %-28s t_last5 E %.4f F %.4f ratio %.2f; idle arms E med %s F med %s; idle refusals %d" %
                  (c, statistics.median(te), statistics.median(tf), statistics.median(tf) / max(statistics.median(te), 1e-9),
                   statistics.median(ia["E"]) if ia["E"] else "-", statistics.median(ia["F"]) if ia["F"] else "-", ir))
    section("(7) THE RECOVERY CELLS: class, rr, the catch and the held peak after it")
    for r in sorted(runs, key=lambda x: x["name"]):
        if not r["cell"].startswith("rc"): continue
        refs = r["refs"]; catch = next((x for x in refs if "autorun" in x.get("at", "")), None)
        peak = "-"
        if catch and r["prfs"]:
            g0 = int(catch["gseq"]); u0 = int(catch["used"]); total = int(catch["total"])
            after = [int(p["used"]) for p in r["prfs"] if int(p["gseq"]) > g0]
            seen = []
            for u in after:
                seen.append(u)
                if u <= total: break
            peak = (max(seen) - u0) if seen else 0
        print("  %-24s class=%-16s rr=%s pf=%s refs=%d opener=%s catch=%s heldpeak=%s" %
              (r["name"], r["class"], r.get("rr"), r.get("pf"), len(refs), refs[0].get("at") if refs else "-", catch.get("at") if catch else "-", peak))
    section("(8) THE INSTRUMENT'S OWN QUESTIONS: first-refusal absorbers per build; kernel=1; power-of-two requests >= 8 KiB")
    for tag in ("E", "F"):
        rs = [r for r in runs if r["build"] == tag]
        first = Counter((r["refs"][0].get("at", "?") if r["refs"] else "none") for r in rs)
        later = Counter(x.get("at", "?") for r in rs for x in r["refs"][1:])
        k1 = sum(1 for r in rs for x in r["refs"] if x.get("kernel") == "1")
        p2 = sum(1 for r in rs for x in r["refs"] if int(x["delta"]) >= 8192 and (int(x["delta"]) & (int(x["delta"]) - 1)) == 0)
        rec = sum(1 for r in rs for x in r["refs"] if x.get("recorder") == "1")
        print("  %s: first %s" % (tag, dict(first.most_common(6))))
        print("     later %s" % dict(later.most_common(8)))
        print("     kernel=1 refusals %d; recorder=1 %d; power-of-two >= 8 KiB requests %d" % (k1, rec, p2))

def main():
    for sub in ("gate", "recover", "matrix"):
        dirs = sorted(glob.glob(os.path.join(ROOT, sub, "*", "")))
        runs = [x for x in (parse_run(d) for d in dirs) if x]
        if not runs: continue
        print("\n######## %s: %d runs" % (sub, len(runs)))
        if sub == "matrix":
            section("the batch-100 matrix: class per build, held per cell")
            for tag in ("S", "E", "F"):
                rs = [r for r in runs if r["build"] == tag]
                if rs: print("  %s: %s" % (tag, dict(Counter(r["class"] for r in rs))))
            for c in sorted(set(r["cell"] for r in runs)):
                row = []
                for tag in ("S", "E", "F"):
                    hs = [r["held"] for r in runs if r["cell"] == c and r["build"] == tag and r.get("held") is not None]
                    if hs: row.append("%s %d" % (tag, statistics.median(hs)))
                print("  %-30s %s" % (c, "; ".join(row)))
            for r in runs:
                if r["class"] not in ("CLEAN", "?"): print("     BAD %s class=%s" % (r["name"], r["class"]))
        else:
            gate(runs)
    p = os.path.join(ROOT, "full.log")
    if os.path.exists(p):
        print("\n######## the suites"); print(open(p).read())

main()
