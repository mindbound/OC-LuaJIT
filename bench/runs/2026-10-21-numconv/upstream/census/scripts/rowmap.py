import sys, re
# rowmap.py <old roadmap> <new roadmap> <repo>: (1) the new roadmap's lines
# 1-269 hold the old ones' rows: equal, or (for an edited row) the same
# first 60 characters; line 270 is new; new 271.. equal old 270.. byte for
# byte.  (2) every "row N" / "rows N" cite in the guide, README, CLAUDE.md,
# test/ and native/ (tracked text files given on stdin? no: the list below)
# names a line whose first 60 characters are unchanged from the old file.
# Prints the edited lines and every cite with its verdict.  Exit 1 on any
# problem.  No backslashes.
NL = chr(10)
sys.stdout.reconfigure(encoding="utf-8")
old = open(sys.argv[1], "rb").read().decode("utf-8").split(NL)
new = open(sys.argv[2], "rb").read().decode("utf-8").split(NL)
R = sys.argv[3]
bad = 0
print("old lines %d, new lines %d" % (len(old), len(new)))
for i in range(269):
    if old[i] != new[i]:
        same = old[i][:60] == new[i][:60]
        print("edited line %d: same row start %s" % (i + 1, same))
        if not same:
            bad += 1
print("new line 270 starts: " + new[269][:90])
if new[270:] != old[269:]:
    print("BAD: new 271.. differ from old 270..")
    bad += 1
else:
    print("new 271..%d equal old 270..%d" % (len(new), len(old)))
files = sys.argv[4:]
pat = re.compile(r"rows? ([0-9]{2,3})((?:(?:, | and | to |-)[0-9]{2,3})*)")
for f in files:
    t = open(R + "/" + f, "rb").read().decode("utf-8", "replace").split(NL)
    for ln, line in enumerate(t, 1):
        for m in pat.finditer(line):
            ctx = line[max(0, m.start() - 40):m.start()].lower()
            nums = [int(m.group(1))] + [int(x) for x in re.findall(r"[0-9]{2,3}", m.group(2))]
            for n in nums:
                if n < 100 or n > 320:
                    continue
                if "roadmap" not in ctx and "row" not in line[m.start():m.start() + 3]:
                    continue
                o = old[n - 1][:60] if n <= len(old) else ""
                w = new[n - 1][:60] if n <= len(new) else ""
                if n == 270:
                    ok = new[269].startswith("- [ ] **The pin move")
                else:
                    ok = (o == w)
                if not ok:
                    bad += 1
                print("%s %s:%d row %d -> %s" % ("OK " if ok else "BAD", f, ln, n, w[:50]))
print("problems:", bad)
sys.exit(1 if bad else 0)
