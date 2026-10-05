# cmp.py <variant> [<variant> ...]      (the forensics' compare.py, for this directory)
# Each cell of a variant against the forensics' BASELINE census of the same
# cell (the instrumented shipped shim), restricted to the offsets the variant
# ran.  Columns:
#   runs      caps run (rc 0 and a full driver line)
#   same      caps whose driver TSV line is byte-identical to the baseline's
#   fired     caps where a rule of the variant fired: an OCLJID absorbed=1 line
#             (rec), or the reserve tier opened by a refusal (res: the tier's
#             top moved) -- every differing cap must be one of these
#   out       outside-handler landings (term 2/4/5/7), baseline -> variant
#   sc        second-chance runs (the reserve's opener absorbed by paint/recorder/unseen)
#   sc_out    ... of them ending outside
#   recop     runs whose reserve was opened by a recorder-absorbed refusal
#   rec       recorder-absorbed refusals (the cpcall wrap's ground truth)
#   abs       OCLJID absorbed=1 lines (the shim's own flag)
#   strtab    OCLJID strtab=1 lines (an intern-table doubling refused)
#   held      sum of the driver's count (objects held at the end), b -> v, and the ratio
#   coll      sum of collects, b -> v
#   odx       max over runs of od_peak - G (bytes past cap + G)
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
WD = os.path.dirname(HERE)
sys.path.insert(0, HERE)
import analyze  # noqa: E402

FOR = os.path.join(os.path.dirname(WD), "forensics", "out")
CELLS = [("string_j1", "L4_string_j1"), ("record_j1", "L4_record_j1"),
         ("string_j0", "L4_string_j0"), ("record_j0", "L4_record_j0"),
         ("oe_string_j1", "X_oe_string_j1"), ("oe_record_j1", "X_oe_record_j1"),
         ("k2048_string_j1", "X_k2048_string_j1"), ("k2048_record_j1", "X_k2048_record_j1")]
OUTSIDE = {2, 4, 5, 7}


def load(d, tag):
    tsv = os.path.join(d, tag + ".tsv")
    if not os.path.exists(tsv):
        return None
    lines = {}
    with open(tsv, "r", newline="") as f:
        for line in f:
            c = line.rstrip("\n").split("\t")
            lines[int(c[0])] = c
    return lines


def summarize(d, tag, lines, offs):
    ed = os.path.join(d, tag + ".err")
    s = dict(out=0, sc=0, sc_out=0, recop=0, rec=0, abs=0, strtab=0, resop=0, odx=-10 ** 9,
             runs=0, bad=0, held=0, coll=0, firedoffs=set(), outoffs=[])
    for off in offs:
        c = lines.get(off)
        if c is None or len(c) < 30 or c[1] != "0":
            s["bad"] += 1
            continue
        s["runs"] += 1
        t = int(c[8])
        G = int(c[6])
        s["held"] += int(c[9])
        s["coll"] += int(float(c[26]))
        s["odx"] = max(s["odx"], int(float(c[29])) - G)
        if t in OUTSIDE:
            s["out"] += 1
            s["outoffs"].append(off)
        path = os.path.join(ed, "%d.err" % off)
        stream = analyze.parse_err(path)
        if stream is None:
            continue
        with open(path, "r", newline="") as f:
            for ln in f:
                if ln.startswith("OCLJID|"):
                    if " absorbed=1 " in ln:
                        s["abs"] += 1
                        s["firedoffs"].add(off)
                    if " strtab=1 " in ln:
                        s["strtab"] += 1
        refs, _, _ = analyze.classify(stream)
        s["rec"] += sum(1 for r in refs if r["absorber"] == "recorder")
        ops = [r for r in refs if r.get("opened") == "1"]
        if ops:
            s["resop"] += 1
            s["firedoffs"].add(off)      # the reserve opened: under res its top moved
        op = ops[0] if ops else None
        if op is not None and op["absorber"] in ("paint", "recorder", "unseen", "unseen-end", "hb"):
            s["sc"] += 1
            if t in OUTSIDE:
                s["sc_out"] += 1
        if op is not None and op["absorber"] == "recorder":
            s["recop"] += 1
    return s


def main(variants):
    for v in variants:
        print("=" * 120)
        print("variant %s  (baseline: the forensics' instrumented shipped shim, same offsets)" % v)
        print("%-16s %5s %5s %5s %9s %9s %7s %6s %6s %4s %6s %19s %13s %13s" % (
            "cell", "runs", "same", "fired", "out b->v", "sc b->v", "sc_out", "recop", "rec", "abs", "strtab",
            "held b->v (ratio)", "coll b->v", "odx b->v"))
        for cell, btag in CELLS:
            vtag = "%s_%s" % (v, cell)
            vl = load(os.path.join(WD, "out"), vtag)
            if vl is None:
                continue
            bl = load(FOR, btag)
            offs = sorted(o for o in vl if o in bl)
            bs = summarize(FOR, btag, bl, offs)
            vs = summarize(os.path.join(WD, "out"), vtag, vl, offs)
            same = sum(1 for o in offs if vl[o][2:] == bl[o][2:])
            differ = [o for o in offs if vl[o][2:] != bl[o][2:]]
            unexplained = [o for o in differ if o not in vs["firedoffs"] and o not in bs["firedoffs"]]
            print("%-16s %5d %5d %5d %4d->%-4d %4d->%-4d %3d->%-3d %2d->%-3d %2d->%-3d %4d %6d %8d->%-8d %.4f %6d->%-6d %6d->%-6d" % (
                cell, vs["runs"], same, len(vs["firedoffs"]), bs["out"], vs["out"], bs["sc"], vs["sc"], bs["sc_out"], vs["sc_out"],
                bs["recop"], vs["recop"], bs["rec"], vs["rec"], vs["abs"], vs["strtab"],
                bs["held"], vs["held"], vs["held"] / float(bs["held"]) if bs["held"] else 0,
                bs["coll"], vs["coll"], bs["odx"], vs["odx"]))
            if unexplained:
                print("    DIFFER WITHOUT A RULE FIRING (%d): %s" % (len(unexplained), unexplained[:12]))
            if vs["bad"] or bs["bad"]:
                print("    bad lines: variant %d baseline %d" % (vs["bad"], bs["bad"]))
            if vs["out"] or bs["out"]:
                print("    outside offsets: baseline %s -> variant %s" % (bs["outoffs"][:25], vs["outoffs"][:25]))


if __name__ == "__main__":
    main(sys.argv[1:])
