import re, sys
# table.py <run dir>: the Part 2 rows of each arm as a markdown table.
R = sys.argv[1]
arms = [("luajit.exe", R + "/standalone/luajit/stdout.txt"),
        ("luajit.exe -joff", R + "/standalone/luajit-joff/stdout.txt"),
        ("PUC 5.3.6", R + "/standalone/puc53/stdout.txt"),
        ("harness, LuaJIT", R + "/ig-luajit/run.log"),
        ("harness, Lua 5.3", R + "/ig-lua53/run.log")]
names = ["crc32 table", "xorshift32", "pack+unpack", "x | 0", "select(i,...)"]
vals = {}
for arm, p in arms:
    txt = open(p, encoding="utf-8", errors="replace").read()
    for n in names:
        m = re.search(re.escape(n) + r"\s+\S+\s+([0-9.]+)\s+([0-9.]+)\s+(\S+)", txt)
        vals[(arm, n)] = (m.group(1), m.group(2), m.group(3)) if m else ("?", "?", "?")
    for line in txt.splitlines():
        if line.startswith("Part 1:") and "PASS" in line or line.startswith("verdict") or line.startswith("Part 2: 5"):
            print(arm, "|", line.strip())
print()
print("| bench (per) | " + " | ".join(a for a, _ in arms) + " |")
for n in names:
    cells = []
    for arm, _ in arms:
        med, mn, chk = vals[(arm, n)]
        cells.append(med if "joff" in arm else med + " / " + mn)
        if chk != "ok":
            cells[-1] += " " + chk
    print("| " + n + " | " + " | ".join(cells) + " |")
print()
for n in names:
    lj = float(vals[("harness, LuaJIT", n)][0]); l53 = float(vals[("harness, Lua 5.3", n)][0])
    puc = float(vals[("PUC 5.3.6", n)][0])
    print("%-14s harness 5.3/LJ %.1f   harness 5.3 / standalone PUC %.2f" % (n, l53 / lj, l53 / puc))
