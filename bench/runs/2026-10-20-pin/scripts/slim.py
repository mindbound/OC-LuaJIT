#!/usr/bin/env python3
# slim.py <archive dir> -- after mkarchive.sh: each build/ md5 census (38985 lines, ~4 MB) is replaced by
# census/digest.txt (its file name, line count and md5, and whether before and after are equal), and the
# gradle logs' CRs (CRLF line ends from gradle on Windows) become LF, for the repo's LF rule.  The full
# census files stay in scratch (claude-tmp/oclj/pin5/final/run-main/census, pin5/ff-7c3c/census).
import hashlib, os, sys
A = sys.argv[1]
CR, LF = bytes([13]), bytes([10])
for run in ("final-main", "fail-first-7c3c2683"):
    c = os.path.join(A, "logs", run, "census")
    rows = []
    digests = {}
    for name in sorted(os.listdir(c)):
        p = os.path.join(c, name)
        if not name.endswith("-build.md5"):
            continue
        d = open(p, "rb").read()
        h = hashlib.md5(d).hexdigest()
        digests[name] = h
        rows.append("%s lines %d md5 %s" % (name, d.count(LF), h))
        os.remove(p)
    if "before-build.md5" in digests and "after-build.md5" in digests:
        rows.append("before == after: %s" % (digests["before-build.md5"] == digests["after-build.md5"]))
    rows.append("full files: claude-tmp/oclj/pin5/%s/census/" % ("final/run-main" if run == "final-main" else "ff-7c3c"))
    with open(os.path.join(c, "digest.txt"), "w", encoding="utf-8", newline="") as f:
        f.write(chr(10).join(rows) + chr(10))
    print(run, rows)
n = 0
for r, _, fs in os.walk(A):
    for name in fs:
        p = os.path.join(r, name)
        d = open(p, "rb").read()
        if CR in d:
            d2 = d.replace(CR + LF, LF).replace(CR, LF)
            open(p, "wb").write(d2)
            n += 1
            print("LF:", p, d.count(CR))
print("converted", n)
