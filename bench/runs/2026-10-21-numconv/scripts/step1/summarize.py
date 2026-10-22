# summarize.py <raw.txt> -- numconv's timing-chain summary (FIX-NUMCONV,
# 2026-10-21), after crc/combine's summarize.py.
# raw.txt lines: "round=<r> pos=<p> vm=<vm> bench=<bench>: <the bench's output>".
# Per metric (bench:row): base's and proto's per-round ns and medians, and
# proto's ratio to base IN THE SAME ROUND (median, min-max); every result
# (r=) must agree between the two VMs in every round, else RESULTS DIFFER.
# Exit 0, or 1 when a line is malformed, a bench printed an error or no
# numbers, a (round, vm, bench) line is missing, or a result differs.
# Written with a file tool (the regexes keep their backslashes; P8 is about
# shell command text).
import re
import sys
import statistics

VMS = ["base", "proto"]
BENCHES = ["ident", "bench_numconv", "bench_bit2", "bench_idx", "bench_spec-mix", "bench_spec-lo50"]
HEAD = re.compile(r"^round=(\S+) pos=(\d+) vm=(\S+) bench=(\S+): (.*)$")
PAIR = re.compile(r"(?:^|[\s|])([A-Za-z][A-Za-z0-9-]*) ([0-9]+\.[0-9]+)(?: ns(?:/it|/byte)?)?(?: \(r=([^)]*)\))?")
IDENT = re.compile(r"([A-Za-z0-9]+-(?:big|small))\t(\S+)\t([0-9]+\.[0-9]+) ns/it")
SKIP = {"ratio"}
# Which metrics answer which question (bench_numconv:ref and every control
# must read 1.00; the identity rows are the rule's targets).
TARGETS = ("ident:", "bench_numconv:arith", "bench_numconv:key", "bench_numconv:bits", "bench_numconv:floor")

def parse(bench, text):
    out = {}
    if bench == "ident":
        for name, r, ns in IDENT.findall(text):
            out[name] = (float(ns), r)
        return out
    for name, ns, r in PAIR.findall(text):
        if name in SKIP:
            continue
        out[name] = (float(ns), r if r else None)
    return out

def med(xs):
    return statistics.median(xs) if xs else float("nan")

def main():
    rows = [l.rstrip("\n") for l in open(sys.argv[1], encoding="utf-8", errors="replace")]
    data = {}      # (round, vm, metric) -> (ns, r)
    seen = set()   # (round, vm, bench)
    rounds, bad, notes = [], 0, []
    order = {}
    for l in rows:
        m = HEAD.match(l)
        if not m:
            if l.strip():
                notes.append("MALFORMED: " + l[:200]); bad = 1
            continue
        rd, pos, vm, bench, text = m.groups()
        if vm not in VMS or bench not in BENCHES:
            notes.append("UNKNOWN VM OR BENCH: " + l[:200]); bad = 1
            continue
        seen.add((rd, vm, bench))
        if "INSTRUMENT" in text or "error" in text.lower() or "REFUS" in text:
            notes.append("BENCH PROBLEM round %s %s %s: %s" % (rd, vm, bench, text[:200])); bad = 1
        b = "bench_spec" if bench.startswith("bench_spec-") else bench
        got = parse(b, text)
        if not got:
            notes.append("NO NUMBERS round %s %s %s: %s" % (rd, vm, bench, text[:200])); bad = 1
        for name, v in got.items():
            data[(rd, vm, b + ":" + name)] = v
        if rd not in rounds:
            rounds.append(rd)
        order.setdefault(rd, {})[vm] = int(pos)
    for rd in rounds:
        for vm in VMS:
            for bench in BENCHES:
                if (rd, vm, bench) not in seen:
                    notes.append("MISSING round %s vm %s bench %s" % (rd, vm, bench)); bad = 1
    metrics = sorted({k[2] for k in data})
    print("timing-chain summary: %d rounds, VMs %s" % (len(rounds), " ".join(VMS)))
    for rd in rounds:
        o = sorted(order[rd], key=lambda v: order[rd][v])
        print("  round %s order: %s" % (rd, " ".join(o)))
    print("os.clock steps 1 ms: 0.1 ns a unit at N=1e7 (ident, bench_bit2, bench_idx), 0.05 at 2e7 (bench_numconv, bench_spec)")
    print()
    print("RESULTS (r=): must agree between base and proto in every round")
    differ = 0
    for k in metrics:
        rs = {data[(rd, vm, k)][1] for rd in rounds for vm in VMS if (rd, vm, k) in data}
        rs.discard(None)
        if len(rs) > 1:
            differ = 1; bad = 1
            print("  RESULTS DIFFER %s: %s" % (k, sorted(rs)))
        for rd in rounds:
            for vm in VMS:
                if (rd, vm, k) not in data:
                    notes.append("METRIC MISSING round %s vm %s %s" % (rd, vm, k)); bad = 1
    if not differ:
        print("  every result equal between base and proto in every round")
    print()
    print("MEDIANS (ns per iteration or byte) and proto's ratio to base in the same round: median [min-max]")
    print("%-24s %8s %8s  %-22s %s" % ("metric", "base", "proto", "proto/base", "role"))
    for k in metrics:
        bvals = [data[(rd, "base", k)][0] for rd in rounds if (rd, "base", k) in data]
        pvals = [data[(rd, "proto", k)][0] for rd in rounds if (rd, "proto", k) in data]
        rr = [data[(rd, "proto", k)][0] / data[(rd, "base", k)][0] for rd in rounds
              if (rd, "proto", k) in data and (rd, "base", k) in data and data[(rd, "base", k)][0] > 0]
        cell = "%.2f [%.2f-%.2f]" % (med(rr), min(rr), max(rr)) if rr else "-"
        role = "target" if k.startswith(TARGETS) else "control"
        print("%-24s %8.2f %8.2f  %-22s %s" % (k, med(bvals), med(pvals), cell, role))
    print()
    print("EVERY ROUND'S RAW ns (rounds in order):")
    for k in metrics:
        for vm in VMS:
            vals = ["%.2f" % data[(rd, vm, k)][0] if (rd, vm, k) in data else "-" for rd in rounds]
            print("  %-24s %-6s %s" % (k, vm, " ".join(vals)))
    if notes:
        print()
        for n in notes:
            print(n)
    print()
    print("SUMMARY: %s" % ("PROBLEMS (see above)" if bad else "OK"))
    return bad

sys.exit(main())
