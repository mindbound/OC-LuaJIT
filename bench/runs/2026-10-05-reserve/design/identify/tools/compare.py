# compare.py <variant> [<variant> ...]
# For each experiment variant, each JIT-on cell against the baseline census
# of the same cell (the instrumented shim, unmodified logic):
#   differ      caps whose driver TSV line differs from the baseline's
#   out         outside-handler landings (term 2/4/5/7), baseline -> variant
#   sc          second-chance runs (opener absorbed by paint/recorder/unseen)
#   sc_out      ... of them ending outside
#   recop       runs whose reserve tier was opened by a recorder-absorbed refusal
#   rec         recorder-absorbed refusals (the wrap's ground truth)
#   fired       OCLJXP lines (the lever fired)
#   odx         max over runs of od_peak - G (bytes past cap + G; the
#               sandbox's bound is G + 4096 past the cap, the kernel's G + 16384)
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import analyze  # noqa: E402

WD = os.path.dirname(os.path.abspath(__file__))
CELLS = [("string_j1", "L4_string_j1"), ("record_j1", "L4_record_j1"),
         ("oe_string_j1", "X_oe_string_j1"), ("oe_record_j1", "X_oe_record_j1"),
         ("k2048_string_j1", "X_k2048_string_j1"), ("k2048_record_j1", "X_k2048_record_j1"),
         ("hb3_string_j1", "X_hb3_string_j1")]
OUTSIDE = {2, 4, 5, 7}


def load(tag):
    tsv = os.path.join(WD, "out", tag + ".tsv")
    if not os.path.exists(tsv):
        return None
    lines = {}
    with open(tsv, "r", newline="") as f:
        for line in f:
            c = line.rstrip("\n").split("\t")
            lines[int(c[0])] = c
    return lines


def summarize(tag, lines):
    ed = os.path.join(WD, "out", tag + ".err")
    s = dict(out=0, sc=0, sc_out=0, recop=0, rec=0, fired=0, odx=-10 ** 9, runs=0, bad=0)
    for off, c in lines.items():
        if len(c) < 30:
            s["bad"] += 1
            continue
        s["runs"] += 1
        t = int(c[8])
        G = int(c[6])
        odp = float(c[29])
        s["odx"] = max(s["odx"], int(odp) - G)
        if t in OUTSIDE:
            s["out"] += 1
        path = os.path.join(ed, "%d.err" % off)
        stream = analyze.parse_err(path)
        if stream is None:
            continue
        with open(path, "r", newline="") as f:
            s["fired"] += sum(1 for ln in f if ln.startswith("OCLJXP|"))
        refs, _, _ = analyze.classify(stream)
        s["rec"] += sum(1 for r in refs if r["absorber"] == "recorder")
        ops = [r for r in refs if r.get("opened") == "1"]
        op = ops[0] if ops else None
        if op is not None and op["absorber"] in ("paint", "recorder", "unseen", "unseen-end", "hb"):
            s["sc"] += 1
            if t in OUTSIDE:
                s["sc_out"] += 1
        if op is not None and op["absorber"] == "recorder":
            s["recop"] += 1
    return s


def main(variants):
    base_cache = {}
    for v in variants:
        print("=" * 100)
        print("variant %s" % v)
        print("%-16s %6s %7s %10s %10s %10s %8s %8s %7s %13s" % (
            "cell", "runs", "differ", "out b->v", "sc b->v", "sc_out", "recop", "rec", "fired", "odx b->v"))
        for cell, btag in CELLS:
            vtag = "%s_%s" % (v, cell)
            vl = load(vtag)
            if vl is None:
                print("%-16s (not run)" % cell)
                continue
            if btag not in base_cache:
                bl = load(btag)
                base_cache[btag] = (bl, summarize(btag, bl))
            bl, bs = base_cache[btag]
            vs = summarize(vtag, vl)
            differ = sum(1 for off in vl if off in bl and vl[off][2:] != bl[off][2:])
            print("%-16s %6d %7d %4d->%-5d %4d->%-5d %3d->%-4d %3d->%-3d %3d->%-3d %7d %6d->%-6d" % (
                cell, vs["runs"], differ, bs["out"], vs["out"], bs["sc"], vs["sc"], bs["sc_out"], vs["sc_out"],
                bs["recop"], vs["recop"], bs["rec"], vs["rec"], vs["fired"], bs["odx"], vs["odx"]))


if __name__ == "__main__":
    main(sys.argv[1:])
