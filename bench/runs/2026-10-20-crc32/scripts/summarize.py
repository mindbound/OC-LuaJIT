# summarize.py <raw.txt> -- crc/combine's timing-chain summary.
# raw.txt lines: "round=<r> pos=<p> vm=<vm> bench=<bench>: <the bench's output>".
# Per metric (bench:row): every VM's per-round ns and median; each build's
# ratio to base IN THE SAME ROUND (median, min-max); result (r=) agreement
# across the four builds in every round, and PUC's results beside them.
# Exit 0, or 1 when an output is malformed, a result differs between the
# builds, or a bench printed INSTRUMENT.  Written with a file tool (the
# regexes keep their backslashes; P8 is about shell command text).
import re
import sys
import statistics

BUILDS = ["base", "folda", "rg2", "both"]
VMS = BUILDS + ["puc"]
HEAD = re.compile(r"^round=(\S+) pos=(\d+) vm=(\S+) bench=(\S+): (.*)$")
PAIR = re.compile(r"(?:^|[\s|])([A-Za-z][A-Za-z0-9-]*) ([0-9]+\.[0-9]+)(?: ns(?:/it|/byte)?)?(?: \(r=([^)]*)\))?")
IDENT = re.compile(r"([A-Za-z0-9]+-(?:big|small))\t(\S+)\t([0-9]+\.[0-9]+) ns/it")
SKIP = {"ratio"}

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
    ms0 = {}       # (vm, metric) -> (ns, r)
    rounds, bad, notes = [], 0, []
    order = {}
    for l in rows:
        m = HEAD.match(l)
        if not m:
            if l.strip():
                notes.append("MALFORMED: " + l[:200]); bad = 1
            continue
        rd, pos, vm, bench, text = m.groups()
        if "INSTRUMENT" in text or "error" in text.lower():
            notes.append("BENCH PROBLEM round %s %s %s: %s" % (rd, vm, bench, text[:200])); bad = 1
        got = parse(bench, text)
        if not got:
            notes.append("NO NUMBERS round %s %s %s: %s" % (rd, vm, bench, text[:200])); bad = 1
        for name, v in got.items():
            key = bench + ":" + name
            if rd == "ms0":
                ms0[(vm, key)] = v
            else:
                data[(rd, vm, key)] = v
        if rd != "ms0":
            if rd not in rounds:
                rounds.append(rd)
            order.setdefault(rd, {})[vm] = int(pos)
    metrics = sorted({k[2] for k in data})
    print("timing-chain summary: %d rounds, VMs %s" % (len(rounds), " ".join(VMS)))
    for rd in rounds:
        o = sorted(order[rd], key=lambda v: order[rd][v])
        print("  round %s order: %s" % (rd, " ".join(o)))
    print("os.clock steps 1 ms: 0.1 ns a unit at N=1e7 (bench_bit2, bench_crcx, bench_idx, ident), 0.05 at 2e7 (bench_bit, bench_spec); 0.5 at 2e6 (ms0)")
    # results
    print()
    print("RESULTS (r=): must agree across the four builds in every round")
    differ = 0
    pucdiff = []
    for k in metrics:
        rs = {data[(rd, vm, k)][1] for rd in rounds for vm in BUILDS if (rd, vm, k) in data}
        rs.discard(None)
        if len(rs) > 1:
            differ = 1; bad = 1
            print("  RESULTS DIFFER %s: %s" % (k, sorted(rs)))
        pr = {data[(rd, "puc", k)][1] for rd in rounds if (rd, "puc", k) in data}
        pr.discard(None)
        if rs and pr and pr != rs:
            pucdiff.append("%s (builds %s, PUC %s)" % (k, "/".join(sorted(rs)), "/".join(sorted(pr))))
    if not differ:
        print("  every result equal across the four builds and every round")
    if pucdiff:
        print("  PUC 5.3.6 differs where plain arithmetic passes 2^53 (our numbers are doubles, PUC's are integers;")
        print("  expected: bench_bit2's rgb and ref, whose i * 2654435761 reaches 2.7e16, and ident's big rows, % of a")
        print("  double past 2^53; any other row here is a finding):")
        for p in pucdiff:
            print("    " + p)
    else:
        print("  PUC 5.3.6's results equal the builds' everywhere")
    # medians and ratios
    print()
    print("MEDIANS (ns per iteration or byte) and each build's ratio to base in the same round: median [min-max]")
    print("%-22s %8s  %-26s %-26s %-26s %8s" % ("metric", "base", "folda/base", "rg2/base", "both/base", "puc"))
    for k in metrics:
        bvals = [data[(rd, "base", k)][0] for rd in rounds if (rd, "base", k) in data]
        cells = []
        for vm in ["folda", "rg2", "both"]:
            rr = []
            vals = []
            for rd in rounds:
                if (rd, vm, k) in data:
                    vals.append(data[(rd, vm, k)][0])
                    if (rd, "base", k) in data and data[(rd, "base", k)][0] > 0:
                        rr.append(data[(rd, vm, k)][0] / data[(rd, "base", k)][0])
            if rr:
                cells.append("%6.2f %.2f [%.2f-%.2f]" % (med(vals), med(rr), min(rr), max(rr)))
            else:
                cells.append("%6.2f   -" % med(vals) if vals else "-")
        pvals = [data[(rd, "puc", k)][0] for rd in rounds if (rd, "puc", k) in data]
        print("%-22s %8.2f  %-26s %-26s %-26s %8.2f" % (k, med(bvals), cells[0], cells[1], cells[2], med(pvals)))
    print()
    print("EVERY ROUND'S RAW ns (rounds in order):")
    for k in metrics:
        for vm in VMS:
            vals = ["%.2f" % data[(rd, vm, k)][0] if (rd, vm, k) in data else "-" for rd in rounds]
            print("  %-22s %-6s %s" % (k, vm, " ".join(vals)))
    if ms0:
        print()
        print("-Omaxside=0, bench_spec.lua at 2e6, one pass (0.5 ns step):")
        keys = sorted({k for (_, k) in ms0})
        for k in keys:
            print("  %-22s %s" % (k, "  ".join("%s %.2f" % (vm, ms0[(vm, k)][0]) for vm in ["base", "rg2", "both"] if (vm, k) in ms0)))
    if notes:
        print()
        for n in notes:
            print(n)
    print()
    print("SUMMARY: %s" % ("PROBLEMS (see above)" if bad else "OK"))
    return bad

sys.exit(main())
