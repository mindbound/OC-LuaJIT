# pairratio.py <raw.txt> <vm a> <vm b> -- per metric, the per-round ratio a/b
# from a timing-chain raw.txt (same round, same machine state): median
# [min-max].  Reuses summarize.py's parser.
import sys, statistics, importlib.util
spec = importlib.util.spec_from_file_location("s", sys.argv[0].replace("pairratio.py", "summarize.py"))
src = open(spec.origin, encoding="utf-8").read().replace("sys.exit(main())", "")
ns = {}
exec(compile(src, spec.origin, "exec"), ns)
raw, a, b = sys.argv[1], sys.argv[2], sys.argv[3]
data = {}
for l in open(raw, encoding="utf-8", errors="replace"):
    m = ns["HEAD"].match(l.rstrip("\n"))
    if not m or m.group(1) == "ms0":
        continue
    rd, _, vm, bench, text = m.groups()
    for name, v in ns["parse"](bench, text).items():
        data[(rd, vm, bench + ":" + name)] = v[0]
keys = sorted({k[2] for k in data})
rounds = sorted({k[0] for k in data})
print("%s / %s, per round" % (a, b))
for k in keys:
    rr = [data[(r, a, k)] / data[(r, b, k)] for r in rounds
          if (r, a, k) in data and (r, b, k) in data and data[(r, b, k)] > 0]
    if rr:
        print("  %-22s %.2f [%.2f-%.2f]" % (k, statistics.median(rr), min(rr), max(rr)))
