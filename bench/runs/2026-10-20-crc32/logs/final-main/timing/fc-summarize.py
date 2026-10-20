# fc-summarize.py <raw.txt> -- the timing part of crc2/fix/final-check.sh
# (the CRC32 follow-up, roadmap row 209, fold a only).  The fixer's copy of
# crc2/impl/fc-summarize.py (md5 314ae117): a PUC difference on a row that
# PUC_EXPECTED does not list now makes the summary PROBLEMS and exit 1
# (verify-code: it was printed as NOT EXPECTED and passed).
# raw.txt lines: "round=<r> pos=<p> vm=<vm> bench=<bench>: <the bench's output>",
# vm one of base (HEAD eb47daf's tree), new (the final check's build of the
# working tree), b0 (round 2's build, bench_bit and bench_bit2 only: its
# results differ by design, so only its times are read) and puc (PUC 5.3.6).
# Per metric (bench:row): every VM's per-round ns and median; new/base and
# b0/base IN THE SAME ROUND (median, min-max); new/b0 for the CRC rows.
# Every result (r=) of new must equal base's in the same round, and be the
# same in every round; PUC's results are compared and listed (expected to
# differ where plain arithmetic passes 2^53).  Prints, for the caller:
#   RESULTS: EQUAL | RESULTS: DIFFER
#   CRCTABLE_NEW_OVER_BASE <median ratio>
# Exit 0, or 1 when an output is malformed, a result differs between base
# and new, PUC's result differs on a row PUC_EXPECTED does not list, or a
# bench of base, new or puc printed INSTRUMENT or an error.
# Adapted from crc/combine/scripts/summarize.py (md5 68579d96) and
# crc/main/b0sum.py.  Written with a file tool (the regexes keep their
# backslashes; P8 is about shell command text).
import re
import sys
import statistics

VMS = ["base", "new", "b0", "puc"]
HEAD = re.compile(r"^round=(\S+) pos=(\d+) vm=(\S+) bench=(\S+): (.*)$")
PAIR = re.compile(r"(?:^|[\s|])([A-Za-z][A-Za-z0-9-]*) ([0-9]+\.[0-9]+)(?: ns(?:/it|/byte)?)?(?: \(r=([^)]*)\))?")
IDENT = re.compile(r"([A-Za-z0-9]+-(?:big|small))\s+(\S+)\s+([0-9]+\.[0-9]+) ns/it")
SKIP = {"ratio"}
PUC_EXPECTED = {"bench_bit2:ref", "bench_bit2:rgb", "ident:andm1-big", "ident:or0-big",
                "ident:shl0-big", "ident:shr0-big", "ident:xor0-big"}


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


def ratios(data, rounds, a, b, k):
    rr = []
    for rd in rounds:
        if (rd, a, k) in data and (rd, b, k) in data and data[(rd, b, k)][0] > 0:
            rr.append(data[(rd, a, k)][0] / data[(rd, b, k)][0])
    return rr


def cell(rr):
    if not rr:
        return "-"
    return "%.2f [%.2f-%.2f]" % (med(rr), min(rr), max(rr))


def main():
    rows = [l.rstrip("\n") for l in open(sys.argv[1], encoding="utf-8", errors="replace")]
    data = {}
    rounds, bad, notes, order = [], 0, [], {}
    for l in rows:
        m = HEAD.match(l)
        if not m:
            if l.strip():
                notes.append("MALFORMED: " + l[:200]); bad = 1
            continue
        rd, pos, vm, bench, text = m.groups()
        if vm not in VMS:
            notes.append("UNKNOWN VM: " + l[:200]); bad = 1
            continue
        problem = "INSTRUMENT" in text or "error" in text.lower()
        if problem:
            notes.append("BENCH PROBLEM round %s %s %s: %s" % (rd, vm, bench, text[:200]))
            if vm != "b0":
                bad = 1
        got = parse(bench, text)
        if not got:
            notes.append("NO NUMBERS round %s %s %s: %s" % (rd, vm, bench, text[:200])); bad = 1
        for name, v in got.items():
            data[(rd, vm, bench + ":" + name)] = v
        if rd not in rounds:
            rounds.append(rd)
        order.setdefault(rd, {})[vm] = int(pos)
    metrics = sorted({k[2] for k in data})
    print("final-check timing summary: %d rounds, VMs %s" % (len(rounds), " ".join(VMS)))
    for rd in rounds:
        o = sorted(order[rd], key=lambda v: order[rd][v])
        print("  round %s order: %s" % (rd, " ".join(o)))
    print("os.clock steps 1 ms: 0.1 ns a unit at N=1e7, 0.05 at 2e7 (at full N; FC_NDIV scales it)")
    print()
    print("RESULTS (r=): new must equal base in every round, and both stay the same across rounds")
    differ = []
    pucdiff = []
    for k in metrics:
        for rd in rounds:
            a = data.get((rd, "base", k))
            b = data.get((rd, "new", k))
            if (a is None) != (b is None) or (a and b and a[1] != b[1]):
                differ.append("%s round %s: base %s, new %s" % (k, rd, a and a[1], b and b[1]))
        rs = {data[(rd, vm, k)][1] for rd in rounds for vm in ("base", "new") if (rd, vm, k) in data}
        rs.discard(None)
        if len(rs) > 1:
            differ.append("%s: across rounds %s" % (k, sorted(rs)))
        pr = {data[(rd, "puc", k)][1] for rd in rounds if (rd, "puc", k) in data}
        pr.discard(None)
        if rs and pr and pr != rs:
            pucdiff.append((k, "/".join(sorted(rs)), "/".join(sorted(pr))))
    if differ:
        bad = 1
        print("RESULTS: DIFFER")
        for d in differ:
            print("  " + d)
    else:
        print("RESULTS: EQUAL (every result of new equals base's, in every round)")
    if pucdiff:
        print("  PUC 5.3.6 differs (our numbers are doubles, PUC's integers; expected where plain")
        print("  arithmetic passes 2^53: bench_bit2's rgb and ref, ident's big rows):")
        for k, ours, theirs in pucdiff:
            tag = "expected" if k in PUC_EXPECTED else "NOT EXPECTED"
            print("    %s (ours %s, PUC %s) %s" % (k, ours, theirs, tag))
            if k not in PUC_EXPECTED:
                notes.append("PUC DIFFERS, NOT EXPECTED: %s (ours %s, PUC %s)" % (k, ours, theirs))
                bad = 1
    else:
        print("  PUC 5.3.6's results equal ours everywhere")
    print("  b0's results are not compared (round 2's 32-bit operators differ by design)")
    print()
    print("MEDIANS (ns per iteration or byte); ratios IN THE SAME ROUND: median [min-max]")
    print("%-22s %8s %8s  %-18s %8s  %-18s %8s" % ("metric", "base", "new", "new/base", "b0", "b0/base", "puc"))
    for k in metrics:
        vals = {vm: [data[(rd, vm, k)][0] for rd in rounds if (rd, vm, k) in data] for vm in VMS}
        print("%-22s %8.2f %8.2f  %-18s %8s  %-18s %8.2f" % (
            k, med(vals["base"]), med(vals["new"]), cell(ratios(data, rounds, "new", "base", k)),
            ("%.2f" % med(vals["b0"])) if vals["b0"] else "-", cell(ratios(data, rounds, "b0", "base", k)),
            med(vals["puc"])))
    print()
    print("ROW 209 (crc-table, ns/byte): new against round 2's b0 in the same round")
    for k in ["bench_bit2:crc-table", "bench_bit:crc"]:
        rr = ratios(data, rounds, "new", "b0", k)
        print("  %-22s new/b0 %s" % (k, cell(rr)))
    ct = ratios(data, rounds, "new", "base", "bench_bit2:crc-table")
    print("CRCTABLE_NEW_OVER_BASE %s" % (("%.3f" % med(ct)) if ct else "nan"))
    print()
    print("EVERY ROUND'S RAW ns (rounds in order):")
    for k in metrics:
        for vm in VMS:
            if any((rd, vm, k) in data for rd in rounds):
                vals = ["%.2f" % data[(rd, vm, k)][0] if (rd, vm, k) in data else "-" for rd in rounds]
                print("  %-22s %-5s %s" % (k, vm, " ".join(vals)))
    if notes:
        print()
        for n in notes:
            print(n)
    print()
    print("SUMMARY: %s" % ("PROBLEMS (see above)" if bad else "OK"))
    return bad


sys.exit(main())
