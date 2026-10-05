# sitepass.py -- for every run of a faithful sweep (lj_repro_If, probe2.lua)
# whose refusal landed outside the batch's handler (term 2) or killed the
# sandbox (term 4), re-run it deterministically with the site pass armed at the
# refused allocation's site, and decide whether a full collection at that
# moment would have made room for the whole object within the tier's top.
#
# usage: python sitepass.py <faithful.tsv> <out.tsv> <exe> <probe> <capk> [jit arm paint hb control junk batch]
import csv, subprocess, sys, os
src, dst, exe, probe, capk = sys.argv[1:6]
rest = sys.argv[6:] or ["0", "1", "1", "0", "0", "24", "100"]
jit, arm, paint, hb, control, junk, batch = rest
SITE = {40: (1, 40), 64: (2, 256), 192: (2, 256), 80: (3, 128), 48: (3, 128)}
rows = list(csv.DictReader(open(src, newline=""), delimiter="\t"))
out = open(dst, "w", newline="")
w = csv.writer(out, delimiter="\t", lineterminator="\n")
w.writerow(["shape", "off", "term", "count", "tb", "delta", "site", "whole", "ref_used", "top", "tier", "armed",
            "live_after", "live_site", "garbage_at_ref", "slack_site", "covered_site", "covered_after", "site_term"])
for r in rows:
    if r["term"] not in ("2", "4"):
        continue
    d = int(r["delta"])
    if d not in SITE:
        w.writerow([r["shape"], r["off"], r["term"], r["count"], r["tb"], d, "?"]); continue
    site, whole = SITE[d]
    cmd = [exe, probe, r["shape"], r["off"], r["off"], "16", capk, jit, arm, paint, hb, control, "-1", junk, batch,
           r["tb"], str(site)]
    res = subprocess.run(cmd, capture_output=True, text=True)
    lines = res.stdout.strip().splitlines()
    m = dict(zip(lines[0].split("\t"), lines[1].split("\t")))
    live_site = int(m["live_site"])
    top = int(r["top"])
    ref_used = int(r["ref_used"])
    slack = top - live_site - whole
    w.writerow([r["shape"], r["off"], r["term"], r["count"], r["tb"], d, site, whole, ref_used, top, r["tier"], r["armed"],
                r["live"], live_site, ref_used - live_site - {192: 64, 48: 80}.get(d, 0), slack, int(slack >= 0), r["covered_top"], m["term"]])
out.close()
print("done", dst)
