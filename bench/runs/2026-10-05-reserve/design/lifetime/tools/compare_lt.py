# compare_lt.py <variant> [<variant> ...]
# Each variant's cells (this directory's out/<variant>_<cell>.tsv + .err/)
# against the forensics' baseline census of the same cell (the instrumented
# shipped shim, out/L4_* and out/X_*), on the caps both have:
#   ident_b    caps whose BASELINE first refusal was the batch's (no second
#              chance): how many driver lines are byte-identical (expected all:
#              the rule changes nothing before a reserve opens, and a batch-
#              caught refusal ends the fill)
#   ident_sc   the same for baseline second-chance caps (expected ~none)
#   out        outside-handler landings (term 2/4/5/7), baseline -> variant
#   sc         second-chance runs (opener absorbed by paint/recorder/unseen/hb)
#   sc_out     ... of them ending outside
#   held       mean held count, all common caps, baseline -> variant (and the
#              variant's mean as a ratio); then over the baseline's sc caps only
#   coll/arms  mean collects / arms per run, baseline -> variant
#   odx        max od_peak - G (bytes past cap + G; the old sandbox bound is
#              G + 4096, the design's G/2 + RSV + 2*4096 for a sandbox refusal)
#   >old/>new  runs whose od_peak passes the old / the design's sandbox bound
#   fired      OCLJXP lines (a reserve sized by a refusal / an L4 expiry)
#   checks     refusal lines != the driver's count; anomalies
import os
import sys
from collections import Counter

HERE = os.path.dirname(os.path.abspath(__file__))
WD = os.path.dirname(HERE)
FO = os.path.join(os.path.dirname(os.path.dirname(WD)), "forensics")
sys.path.insert(0, FO)
import analyze  # noqa: E402  (the forensics' classifier, imported read-only)

CELLS = [("string_j1", "L4_string_j1"), ("record_j1", "L4_record_j1"),
         ("string_j0", "L4_string_j0"), ("record_j0", "L4_record_j0"),
         ("oe_string_j1", "X_oe_string_j1"), ("oe_record_j1", "X_oe_record_j1"),
         ("k2048_string_j1", "X_k2048_string_j1")]
OUTSIDE = {2, 4, 5, 7}
SC = ("paint", "recorder", "unseen", "unseen-end", "hb")
RSV = {"R0": 0, "R1K": 1024, "R4K": 4096, "R8K": 8192, "L4": 16384}


def load_tsv(path):
    lines = {}
    if not os.path.exists(path):
        return None
    with open(path, "r", newline="") as f:
        for line in f:
            c = line.rstrip("\n").split("\t")
            lines[int(c[0])] = c
    return lines


def load_class(path):
    cl = {}
    with open(path, "r", newline="") as f:
        next(f)
        for line in f:
            c = line.rstrip("\n").split("\t")
            cl[int(c[0])] = dict(term=int(c[1]), nref=int(c[2]), absorbers=c[3], opener=c[4], sc=int(c[5]))
    return cl


def classify_variant(tag, offs):
    ed = os.path.join(WD, "out", tag + ".err")
    res = {}
    stats = Counter()
    rsvs = []
    for off in offs:
        path = os.path.join(ed, "%d.err" % off)
        stream = analyze.parse_err(path)
        if stream is None:
            stats["no err"] += 1
            continue
        refs, anom, _ = analyze.classify(stream)
        for a in anom:
            stats["anomaly"] += 1
        fired = 0
        with open(path, "r", newline="") as f:
            for ln in f:
                if ln.startswith("OCLJXP|"):
                    fired += 1
                    d = dict(analyze.KV.findall(ln[7:]))
                    if d.get("kind") == "rsv":
                        rsvs.append((int(d["rsv"]), int(d["used"]) - int(d["total"]), int(d["top"]) - int(d["total"])))
        ops = [r for r in refs if r.get("opened") == "1"]
        op = ops[0] if ops else None
        res[off] = dict(nref=len(refs), opener=op["absorber"] if op else "-",
                        sc=int(op is not None and op["absorber"] in SC),
                        absorbers=",".join(r["absorber"] for r in refs), fired=fired,
                        last=refs[-1] if refs else None)
    return res, stats, rsvs


def main(variants):
    for v in variants:
        rsv = RSV.get(v, 4096)
        print("=" * 110)
        print("variant %s  (RSV %d)" % (v, rsv))
        print("%-15s %5s %9s %8s %9s %9s %7s %22s %22s %13s %13s %10s %7s %6s %7s" % (
            "cell", "caps", "ident_b", "ident_sc", "out b->v", "sc b->v", "sc_out",
            "held all b->v (ratio)", "held sc-caps b->v", "coll b->v", "arms b->v", "odx b->v", ">old", ">new", "fired"))
        tot_rsvs = []
        for cell, btag in CELLS:
            vt = load_tsv(os.path.join(WD, "out", "%s_%s.tsv" % (v, cell)))
            if vt is None:
                print("%-15s (not run)" % cell)
                continue
            bt = load_tsv(os.path.join(FO, "out", btag + ".tsv"))
            bc = load_class(os.path.join(FO, "out", btag + ".class.tsv"))
            offs = sorted(o for o in vt if o in bt and len(vt[o]) >= 30 and len(bt[o]) >= 30)
            vc, stats, rsvs = classify_variant("%s_%s" % (v, cell), offs)
            tot_rsvs += rsvs
            nb_b = nb_v = 0; ib = isc = 0; nsc_b = nsc_v = 0
            out_b = out_v = 0; sco_b = sco_v = 0
            held_b = held_v = 0.0; hsc_b = hsc_v = 0.0; nsc = 0
            coll_b = coll_v = arms_b = arms_v = 0.0
            odx_b = odx_v = -10 ** 9; gt_old = gt_new = 0; fired = 0; mism = 0
            G = int(vt[offs[0]][6]) if offs else 0
            for o in offs:
                b, w = bt[o], vt[o]
                tb, tv = int(b[8]), int(w[8])
                same = b[2:] == w[2:]
                if bc[o]["sc"]:
                    nb_v += 1
                    if same: isc += 1
                else:
                    nb_b += 1
                    if same: ib += 1
                out_b += tb in OUTSIDE; out_v += tv in OUTSIDE
                nsc_b += bc[o]["sc"]; nsc_v += vc[o]["sc"] if o in vc else 0
                sco_b += bc[o]["sc"] and tb in OUTSIDE
                sco_v += (vc[o]["sc"] if o in vc else 0) and tv in OUTSIDE
                held_b += int(b[9]); held_v += int(w[9])
                if bc[o]["sc"]:
                    nsc += 1; hsc_b += int(b[9]); hsc_v += int(w[9])
                coll_b += int(b[26]); coll_v += int(w[26]); arms_b += int(b[27]); arms_v += int(w[27])
                odb = int(float(b[29])) - int(b[6]); odv = int(float(w[29])) - int(w[6])
                odx_b = max(odx_b, odb); odx_v = max(odx_v, odv)
                gt_old += odv > 4096
                gt_new += int(float(w[29])) > int(w[6]) // 2 + rsv + 2 * 4096
                if o in vc:
                    fired += vc[o]["fired"]
                    if vc[o]["nref"] != int(float(w[25])): mism += 1
            n = len(offs)
            print("%-15s %5d %4d/%-4d %3d/%-4d %4d->%-4d %4d->%-4d %3d->%-3d %7.0f->%-7.0f(%.3f) %7.0f->%-7.0f %6.1f->%-6.1f %6.1f->%-6.1f %5d->%-5d %5d %5d %6d  %s" % (
                cell, n, ib, nb_b, isc, nb_v, out_b, out_v, nsc_b, nsc_v, sco_b, sco_v,
                held_b / n, held_v / n, held_v / held_b if held_b else 0,
                hsc_b / nsc if nsc else 0, hsc_v / nsc if nsc else 0,
                coll_b / n, coll_v / n, arms_b / n, arms_v / n, odx_b, odx_v, gt_old, gt_new, fired,
                ("mismatch %d " % mism if mism else "") + (str(dict(stats)) if stats else "")))
            # the variant's outside landings, in detail
            for o in offs:
                if int(vt[o][8]) in OUTSIDE and o in vc:
                    last = vc[o]["last"] or {}
                    print("      out: off %5d term %s nref %d [%s] opener %s; last: delta=%s tier0=%s win0=%s at=%s over=%s   (baseline: term %d [%s])" % (
                        o, vt[o][8], vc[o]["nref"], vc[o]["absorbers"], vc[o]["opener"],
                        last.get("delta"), last.get("tier0"), last.get("win0"), last.get("at"), last.get("over"),
                        int(bt[o][8]), bc[o]["absorbers"]))
        if tot_rsvs:
            d = [r[0] - r[1] for r in tot_rsvs]       # rsv credit - over at the refusal
            print("  reserves sized by a refusal: %d; credit past the cap min %d max %d; R granted past the refused heap min %d max %d; top past cap min %d max %d" % (
                len(tot_rsvs), min(r[0] for r in tot_rsvs), max(r[0] for r in tot_rsvs), min(d), max(d),
                min(r[2] for r in tot_rsvs), max(r[2] for r in tot_rsvs)))


if __name__ == "__main__":
    main(sys.argv[1:])
