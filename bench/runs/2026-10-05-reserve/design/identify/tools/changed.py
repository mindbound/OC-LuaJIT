# changed.py <variant>: for every cap whose driver line differs from the
# baseline, the baseline's and the variant's absorber sequence, term and count.
import sys, collections
import analyze, compare
v = sys.argv[1]
agg = collections.Counter()
for cell, btag in compare.CELLS:
    vl = compare.load("%s_%s" % (v, cell))
    bl = compare.load(btag)
    if vl is None:
        continue
    for off in sorted(vl):
        if off in bl and vl[off][2:] != bl[off][2:]:
            rb, _, _ = analyze.classify(analyze.parse_err("out/%s.err/%d.err" % (btag, off)))
            rv, _, _ = analyze.classify(analyze.parse_err("out/%s_%s.err/%d.err" % (v, cell, off)))
            key = (cell, ",".join(r["absorber"] for r in rb), bl[off][8], ",".join(r["absorber"] for r in rv), vl[off][8])
            agg[key] += 1
            dc = int(vl[off][9]) - int(bl[off][9])
            agg[("count delta", cell, dc)] += 1
for k, n in sorted(agg.items(), key=lambda kv: str(kv[0])):
    if k[0] == "count delta":
        print("  %-16s count(variant)-count(base) = %+d : %d caps" % (k[1], k[2], n))
    else:
        print("  %-16s base [%s] term %s  ->  variant [%s] term %s : %d caps" % (k + (n,)))
