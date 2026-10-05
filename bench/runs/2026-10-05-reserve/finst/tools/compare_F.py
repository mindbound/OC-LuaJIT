# compare_F.py [variant=F] [seedcaps]
# finst: the FINAL instrumented driver's censuses (this directory's
# out/<variant>_<cell>.tsv + .err/, and out/<variant>_<cell>_s<seed>.tsv for
# the extra seeds) against the baselines, on the caps both have:
#   seed 1    the forensics' censuses of the instrumented shipped shim
#             (sc/forensics/out/L4_* 4 096 caps, X_* 2 048 caps), all EIGHT
#             cells of lifetime's layout plus k2048_record_j1;
#   seeds 2,3 out/B_<cell>_s<seed>, run by census-M1.sh with the forensics'
#             own lref_ref.exe (no such baseline existed for the string cells;
#             lifetime's BASEs2/s3 oe-string runs are re-run here so every
#             baseline is in one directory and the re-run is a determinism check).
# Every run, baseline and variant, is classified on the fly by the forensics'
# analyze.py (parse_err + classify); where the forensics left a .class.tsv the
# on-the-fly second-chance flag is checked against it and disagreements counted.
# lifetime's compare_lt.py columns:
#   ident_b    caps whose BASELINE first refusal was the batch's (no second
#              chance): how many driver lines are byte-identical (expected all:
#              the rule changes nothing before a reserve opens, and a batch-
#              caught refusal ends the fill)
#   ident_sc   the same for baseline second-chance caps (expected ~none)
#   out        outside-handler landings (term 2/4/5/7), baseline -> variant
#   sc         second-chance runs (opener absorbed by paint/recorder/unseen/hb)
#   sc_out     ... of them ending outside
#   held       mean held count, all common caps, baseline -> variant (ratio);
#              then over the baseline's sc caps only
#   coll/arms  mean collects / arms per run, baseline -> variant
#   odx        max od_peak - G (bytes past cap + G)
#   >old/>new  runs whose od_peak passes the old sandbox bound (G + 4096) / the
#              design's (G/2 + RSV + 2*4096) -- M1 wants both 0 for the variant
#   fired      OCLJXP lines (reserves sized by a refusal)
#   checks     refusal lines != the driver's count; anomalies; class.tsv disagreements
# Then the per-seed table: outside counts in BOTH directions per cell and seed,
# never pooled (d3-final.txt M1, E2/C1).
import os
import sys
from collections import Counter

HERE = os.path.dirname(os.path.abspath(__file__))
WD = os.path.dirname(HERE)
FO = os.path.join(os.path.dirname(WD), "forensics")
sys.path.insert(0, FO)
import analyze  # noqa: E402  (the forensics' classifier, imported read-only)

CELLS1 = [("string_j1", "L4_string_j1"), ("record_j1", "L4_record_j1"),
          ("string_j0", "L4_string_j0"), ("record_j0", "L4_record_j0"),
          ("oe_string_j1", "X_oe_string_j1"), ("oe_record_j1", "X_oe_record_j1"),
          ("k2048_string_j1", "X_k2048_string_j1"), ("k2048_record_j1", "X_k2048_record_j1")]
SEEDCELLS = ["oe_string_j1", "string_j1", "string_j0"]
SEEDS = [2, 3]
OUTSIDE = {2, 4, 5, 7}
SC = ("paint", "recorder", "unseen", "unseen-end", "hb")
RSV = 8192          # LJ52_GC_RSV in the final shim
LEND = 4096         # LJ52_GC_LEND


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
    if not os.path.exists(path):
        return None
    with open(path, "r", newline="") as f:
        next(f)
        for line in f:
            c = line.rstrip("\n").split("\t")
            cl[int(c[0])] = int(c[5])
    return cl


def classify_dir(errdir, offs):
    """Classify every cap's stderr stream: nref, opener, sc, absorbers, fired, rsvs, last."""
    res = {}
    stats = Counter()
    rsvs = []
    for off in offs:
        path = os.path.join(errdir, "%d.err" % off)
        stream = analyze.parse_err(path)
        if stream is None:
            stats["no err"] += 1
            continue
        refs, anom, _ = analyze.classify(stream)
        for a in anom:
            stats["anomaly"] += 1
        ring = [d for k, d in stream if k == "RING"]
        if not ring or int(ring[-1]["n"]) != len(refs):
            stats["ring!=lines"] += 1
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


def compare_cell(label, bt, bdir, bclass, vt, vdir, rsv):
    """One row.  bt/vt the tsv dicts, bdir/vdir the .err dirs, bclass the forensics' class.tsv (or None)."""
    offs = sorted(o for o in vt if o in bt and len(vt[o]) >= 30 and len(bt[o]) >= 30)
    if not offs:
        print("%-18s no common caps" % label)
        return None
    bc, bstats, _ = classify_dir(bdir, offs)
    vc, vstats, rsvs = classify_dir(vdir, offs)
    cls_dis = 0
    if bclass is not None:
        cls_dis = sum(1 for o in offs if o in bc and o in bclass and bc[o]["sc"] != bclass[o])
    nb_b = nb_v = 0; ib = isc = 0; nsc_b = nsc_v = 0
    out_b = out_v = 0; sco_b = sco_v = 0
    held_b = held_v = 0.0; hsc_b = hsc_v = 0.0; nsc = 0
    coll_b = coll_v = arms_b = arms_v = 0.0
    odx_b = odx_v = -10 ** 9; gt_old_b = gt_new_b = gt_old = gt_new = 0; fired = 0; mism = 0
    for o in offs:
        b, w = bt[o], vt[o]
        tb, tv = int(b[8]), int(w[8])
        same = b[2:] == w[2:]
        bsc = bc[o]["sc"] if o in bc else 0
        vsc = vc[o]["sc"] if o in vc else 0
        if bsc:
            nb_v += 1
            if same: isc += 1
        else:
            nb_b += 1
            if same: ib += 1
        out_b += tb in OUTSIDE; out_v += tv in OUTSIDE
        nsc_b += bsc; nsc_v += vsc
        sco_b += bsc and tb in OUTSIDE
        sco_v += vsc and tv in OUTSIDE
        held_b += int(b[9]); held_v += int(w[9])
        if bsc:
            nsc += 1; hsc_b += int(b[9]); hsc_v += int(w[9])
        coll_b += int(b[26]); coll_v += int(w[26]); arms_b += int(b[27]); arms_v += int(w[27])
        G = int(w[6])
        odb = int(float(b[29])) - int(b[6]); odv = int(float(w[29])) - G
        odx_b = max(odx_b, odb); odx_v = max(odx_v, odv)
        gt_old_b += odb > LEND; gt_new_b += int(float(b[29])) > int(b[6]) // 2 + rsv + 2 * LEND
        gt_old += odv > LEND
        gt_new += int(float(w[29])) > G // 2 + rsv + 2 * LEND
        if o in vc:
            fired += vc[o]["fired"]
            if vc[o]["nref"] != int(float(w[25])): mism += 1
    n = len(offs)
    notes = []
    if mism: notes.append("refusal-lines!=driver %d" % mism)
    if cls_dis: notes.append("class.tsv disagrees %d" % cls_dis)
    if bstats: notes.append("baseline %s" % dict(bstats))
    if vstats: notes.append("variant %s" % dict(vstats))
    print("%-18s %5d %4d/%-4d %3d/%-4d %4d->%-4d %4d->%-4d %3d->%-3d %7.0f->%-7.0f(%.3f) %7.0f->%-7.0f %6.1f->%-6.1f %6.1f->%-6.1f %6d->%-6d %2d->%-2d %2d->%-2d %6d  %s" % (
        label, n, ib, nb_b, isc, nb_v, out_b, out_v, nsc_b, nsc_v, sco_b, sco_v,
        held_b / n, held_v / n, held_v / held_b if held_b else 0,
        hsc_b / nsc if nsc else 0, hsc_v / nsc if nsc else 0,
        coll_b / n, coll_v / n, arms_b / n, arms_v / n, odx_b, odx_v, gt_old_b, gt_old, gt_new_b, gt_new, fired,
        "; ".join(notes)))
    for o in offs:
        if int(vt[o][8]) in OUTSIDE and o in vc:
            last = vc[o]["last"] or {}
            print("      out: off %5d term %s nref %d [%s] opener %s; last: delta=%s tier0=%s win0=%s at=%s over=%s rsv=%s tier=%s   (baseline: term %d [%s])" % (
                o, vt[o][8], vc[o]["nref"], vc[o]["absorbers"], vc[o]["opener"],
                last.get("delta"), last.get("tier0"), last.get("win0"), last.get("at"), last.get("over"),
                last.get("rsv"), last.get("tier"),
                int(bt[o][8]), bc[o]["absorbers"] if o in bc else "?"))
    return dict(label=label, n=n, ident_b=(ib, nb_b), ident_sc=(isc, nb_v), out=(out_b, out_v),
                sc=(nsc_b, nsc_v), sc_out=(sco_b, sco_v), gt_old=(gt_old_b, gt_old), gt_new=(gt_new_b, gt_new),
                fired=fired, rsvs=rsvs)


HEADER = "%-18s %5s %9s %8s %9s %9s %7s %22s %22s %13s %13s %14s %5s %5s %7s" % (
    "cell", "caps", "ident_b", "ident_sc", "out b->v", "sc b->v", "sc_out",
    "held all b->v (ratio)", "held sc-caps b->v", "coll b->v", "arms b->v", "odx b->v", ">old", ">new", "fired")


def main(argv):
    v = argv[0] if argv else "F"
    rows = []
    print("=" * 150)
    print("variant %s  (RSV %d, window %d; the design's sandbox bound od_peak <= G/2 + RSV + 2*window; the old one G + window)" % (v, RSV, LEND))
    print("-- seed 1, against the forensics' baselines (sc/forensics/out)")
    print(HEADER)
    tot_rsvs = []
    for cell, btag in CELLS1:
        vt = load_tsv(os.path.join(WD, "out", "%s_%s.tsv" % (v, cell)))
        if vt is None:
            print("%-18s (not run)" % cell)
            continue
        bt = load_tsv(os.path.join(FO, "out", btag + ".tsv"))
        if bt is None:
            print("%-18s (no baseline %s)" % (cell, btag))
            continue
        r = compare_cell(cell, bt, os.path.join(FO, "out", btag + ".err"),
                         load_class(os.path.join(FO, "out", btag + ".class.tsv")),
                         vt, os.path.join(WD, "out", "%s_%s.err" % (v, cell)), RSV)
        if r:
            r["seed"] = 1; rows.append(r); tot_rsvs += r["rsvs"]
    print("-- seeds %s, against out/B_<cell>_s<seed> (the forensics' lref_ref.exe, run by census-M1.sh)" % SEEDS)
    print(HEADER)
    for s in SEEDS:
        for cell in SEEDCELLS:
            tag_v = "%s_%s_s%d" % (v, cell, s)
            tag_b = "B_%s_s%d" % (cell, s)
            vt = load_tsv(os.path.join(WD, "out", tag_v + ".tsv"))
            bt = load_tsv(os.path.join(WD, "out", tag_b + ".tsv"))
            if vt is None or bt is None:
                print("%-18s (%s)" % ("%s s%d" % (cell, s), "not run" if vt is None else "no baseline " + tag_b))
                continue
            r = compare_cell("%s s%d" % (cell, s), bt, os.path.join(WD, "out", tag_b + ".err"), None,
                             vt, os.path.join(WD, "out", tag_v + ".err"), RSV)
            if r:
                r["seed"] = s; rows.append(r); tot_rsvs += r["rsvs"]
    if tot_rsvs:
        d = [r[0] - r[1] for r in tot_rsvs]       # rsv credit - over at the refusal
        print("  reserves sized by a refusal: %d; gc_rsv (credit past the cap, unclamped) min %d max %d; past the refused heap min %d max %d; top past cap (clamped) min %d max %d" % (
            len(tot_rsvs), min(r[0] for r in tot_rsvs), max(r[0] for r in tot_rsvs), min(d), max(d),
            min(r[2] for r in tot_rsvs), max(r[2] for r in tot_rsvs)))
    # M1's criteria, per cell and seed, in both directions, never pooled
    print()
    print("-- M1 per cell and seed (b = baseline, v = %s); outside counts in both directions, never pooled" % v)
    print("%-18s %4s %5s %12s %12s %12s %12s %12s %10s" % ("cell", "seed", "caps", "nonsc ident", "out b / v", "sc b / v", "sc_out b / v", ">old b / v", ">new b / v"))
    ok_ident = ok_bound = True
    for r in rows:
        ib, nb = r["ident_b"]
        if ib != nb: ok_ident = False
        if r["gt_old"][1] or r["gt_new"][1]: ok_bound = False
        print("%-18s %4d %5d %5d/%-6d %5d / %-5d %5d / %-5d %5d / %-5d %5d / %-5d %4d / %-4d" % (
            r["label"].split()[0], r["seed"], r["n"], ib, nb, r["out"][0], r["out"][1], r["sc"][0], r["sc"][1],
            r["sc_out"][0], r["sc_out"][1], r["gt_old"][0], r["gt_old"][1], r["gt_new"][0], r["gt_new"][1]))
    if not rows:
        print("M1: no cells compared (nothing run yet)")
        return
    print("M1 must hold (over the %d rows above): non-second-chance caps byte-identical in every cell and seed: %s; 0 variant runs past either bound: %s"
          % (len(rows), "HOLDS" if ok_ident else "FAILS", "HOLDS" if ok_bound else "FAILS"))


if __name__ == "__main__":
    main(sys.argv[1:])
