# compare.py [cell ...]
# The verdict prototype's census (verdict/out/V_<cell>) against the forensics'
# baseline census of the same cell (forensics/out/<base>), run by run (by cap
# offset), using the forensics' classifier (analyze.classify) on both streams:
#   runs / differ   caps in both; caps whose driver TSV data line differs
#   out b->v        outside-handler landings (term 2/4/5/7)
#   sc b->v         second-chance runs (the reserve's opener absorbed by paint/recorder/unseen)
#   sc_out          ... of them ending outside
#   recop           runs whose reserve tier was opened by a recorder-absorbed refusal
#   held            runs with at least one held verdict (OCLJHOLD) / total holds
#   unaddr          refusals with addr=0 (opened nothing) / their absorbers
#   count           the held count (TSV col 8) mean b -> v, and the per-cap delta's min/median/max
#   collects        TSV col 25 mean b -> v
#   refusals/run    histogram v
#   identity        among caps where NOTHING fired (no hold, no addr=0 refusal): identical lines / caps
import os
import sys
from collections import Counter

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import analyze  # noqa: E402  (the forensics' classifier, copied)

VD = os.path.dirname(HERE)
FD = os.path.join(os.path.dirname(VD), "forensics")
CELLS = [("string_j1", "L4_string_j1"), ("record_j1", "L4_record_j1"),
         ("string_j0", "L4_string_j0"), ("record_j0", "L4_record_j0"),
         ("oe_string_j1", "X_oe_string_j1"), ("oe_record_j1", "X_oe_record_j1"),
         ("k2048_string_j1", "X_k2048_string_j1"), ("k2048_record_j1", "X_k2048_record_j1")]
OUTSIDE = {2, 4, 5, 7}
PREFIX = os.environ.get("VPREFIX", "V_")   # V_ the first draft, V2_ revision 2


def load(path):
    if not os.path.exists(path):
        return None
    lines = {}
    with open(path, "r", newline="") as f:
        for line in f:
            c = line.rstrip("\n").split("\t")
            if c and c[0].isdigit():
                lines[int(c[0])] = c
    return lines


def run_info(errdir, off):
    path = os.path.join(errdir, "%d.err" % off)
    stream = analyze.parse_err(path)
    holds = 0
    if stream is None:
        return None, 0, [], 0
    try:
        with open(path, "r", newline="") as f:
            for ln in f:
                if ln.startswith("OCLJHOLD|"):
                    holds += 1
    except OSError:
        pass
    refs, anom, _ = analyze.classify(stream)
    return refs, holds, anom, 1


def median(xs):
    xs = sorted(xs)
    n = len(xs)
    if n == 0:
        return float("nan")
    return xs[n // 2] if n % 2 else (xs[n // 2 - 1] + xs[n // 2]) / 2.0


def main(cells):
    want = set(cells)
    for cell, btag in CELLS:
        if want and cell not in want:
            continue
        vl = load(os.path.join(VD, "out", "%s%s.tsv" % (PREFIX, cell)))
        bl = load(os.path.join(FD, "out", "%s.tsv" % btag))
        if vl is None or bl is None:
            print("%-16s (not run)" % cell)
            continue
        ved = os.path.join(VD, "out", "%s%s.err" % (PREFIX, cell))
        bed = os.path.join(FD, "out", "%s.err" % btag)
        offs = sorted(set(vl) & set(bl))
        s = dict(runs=0, differ=0, out_b=0, out_v=0, sc_b=0, sc_v=0, sco_b=0, sco_v=0,
                 recop_b=0, recop_v=0, heldruns=0, holds=0, unaddr=0, quiet=0, quiet_same=0,
                 rec_b=0, rec_v=0, badline=0)
        unaddr_abs = Counter()
        nref_v = Counter()
        nref_b = Counter()
        counts_b, counts_v, deltas, coll_b, coll_v = [], [], [], [], []
        outs_v = []
        fired_outside = []
        abs_v = Counter()
        abs_b = Counter()
        sc_count_delta = []
        for off in offs:
            vc, bc = vl[off], bl[off]
            if len(vc) < 30 or len(bc) < 30:
                s["badline"] += 1
                continue
            s["runs"] += 1
            tv, tb = int(vc[8]), int(bc[8])
            cv, cb = int(vc[9]), int(bc[9])
            counts_v.append(cv); counts_b.append(cb); deltas.append(cv - cb)
            coll_v.append(float(vc[26])); coll_b.append(float(bc[26]))
            differ = vc[2:] != bc[2:]
            if differ:
                s["differ"] += 1
            if tv in OUTSIDE:
                s["out_v"] += 1
            if tb in OUTSIDE:
                s["out_b"] += 1
            refs_v, holds, anom, okv = run_info(ved, off)
            refs_b, _, _, okb = run_info(bed, off)
            if refs_v is None or refs_b is None:
                continue
            nref_v[len(refs_v)] += 1
            nref_b[len(refs_b)] += 1
            for r in refs_v:
                abs_v[r["absorber"]] += 1
            for r in refs_b:
                abs_b[r["absorber"]] += 1
            s["holds"] += holds
            if holds:
                s["heldruns"] += 1
            ua = [r for r in refs_v if r.get("addr") == "0" or r.get("rec") == "1"]
            s["unaddr"] += len(ua)
            for r in ua:
                unaddr_abs[r["absorber"]] += 1
            s["rec_v"] += sum(1 for r in refs_v if r["absorber"] == "recorder")
            s["rec_b"] += sum(1 for r in refs_b if r["absorber"] == "recorder")

            def sc_of(refs):
                ops = [r for r in refs if r.get("opened") == "1"]
                op = ops[0] if ops else None
                sc = op is not None and op["absorber"] in ("paint", "recorder", "unseen", "unseen-end", "hb")
                return sc, op
            scv, opv = sc_of(refs_v)
            scb, opb = sc_of(refs_b)
            if scv:
                s["sc_v"] += 1
                if tv in OUTSIDE:
                    s["sco_v"] += 1
            if scb:
                s["sc_b"] += 1
                if tb in OUTSIDE:
                    s["sco_b"] += 1
                sc_count_delta.append(cv - cb)
            if opv is not None and opv["absorber"] == "recorder":
                s["recop_v"] += 1
            if opb is not None and opb["absorber"] == "recorder":
                s["recop_b"] += 1
            fired = holds > 0 or len(ua) > 0
            if not fired:
                s["quiet"] += 1
                if not differ:
                    s["quiet_same"] += 1
            if tv in OUTSIDE:
                last = refs_v[-1] if refs_v else {}
                outs_v.append((off, tv, tb, holds, len(ua), ",".join(r["absorber"] for r in refs_v),
                               last.get("delta"), last.get("tier0"), last.get("win0"), last.get("at"),
                               last.get("over"), last.get("addr"), last.get("vm")))
        print("=" * 100)
        print("%s%s  (baseline %s)" % (PREFIX, cell, btag))
        print("  runs %d (bad lines %d); differ %d" % (s["runs"], s["badline"], s["differ"]))
        print("  outside landings     %4d -> %-4d   second chances %4d -> %-4d   of them outside %3d -> %-3d   recorder-opened %d -> %d   recorder-absorbed refusals %d -> %d"
              % (s["out_b"], s["out_v"], s["sc_b"], s["sc_v"], s["sco_b"], s["sco_v"], s["recop_b"], s["recop_v"], s["rec_b"], s["rec_v"]))
        print("  held verdicts: %d holds in %d runs; refusals that opened nothing (addr=0): %d, absorbed by %s"
              % (s["holds"], s["heldruns"], s["unaddr"], dict(unaddr_abs)))
        print("  refusals/run  base %s   verdict %s" % (
            ", ".join("%d:%d" % kv for kv in sorted(nref_b.items())), ", ".join("%d:%d" % kv for kv in sorted(nref_v.items()))))
        print("  absorbers     base %s   verdict %s" % (dict(abs_b), dict(abs_v)))
        if counts_b:
            print("  held count: mean %.1f -> %.1f (%.3fx); per-cap delta min %d median %g max %d; caps lower %d, equal %d, higher %d"
                  % (sum(counts_b) / len(counts_b), sum(counts_v) / len(counts_v),
                     (sum(counts_v) / len(counts_v)) / (sum(counts_b) / len(counts_b)),
                     min(deltas), median(deltas), max(deltas),
                     sum(1 for d in deltas if d < 0), sum(1 for d in deltas if d == 0), sum(1 for d in deltas if d > 0)))
            if sc_count_delta:
                print("  ... in the baseline's second-chance runs: delta min %d median %g max %d (n %d)"
                      % (min(sc_count_delta), median(sc_count_delta), max(sc_count_delta), len(sc_count_delta)))
            print("  collects: mean %.1f -> %.1f" % (sum(coll_b) / len(coll_b), sum(coll_v) / len(coll_v)))
        print("  identity where nothing fired: %d of %d quiet caps identical" % (s["quiet_same"], s["quiet"]))
        for o in outs_v[:30]:
            print("    OUTSIDE off %5d term %d (base %d) holds %d unaddr %d absorbers [%s] last: delta=%s tier0=%s win0=%s at=%s over=%s addr=%s vm=%s" % o)


if __name__ == "__main__":
    main(sys.argv[1:])
