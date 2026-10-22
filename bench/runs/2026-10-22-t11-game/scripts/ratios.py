import re, statistics, sys
# ratios.py <game> <standalone> <joff> <harness>: T11 results files.  Each
# Part 2 row of the game's file against run 3's standalone luajit.exe, its
# -joff and the harness's LuaJIT arm, from the printed medians and from the
# medians of the reps; each row's rep spread; the crc32 / pack+unpack ratio.
NAMES = ("crc32 table", "xorshift32", "pack+unpack", "x | 0", "select(i,...)")

def parse(path):
    lines = open(path, "rb").read().decode().split("\n")
    rows = {}
    for i, ln in enumerate(lines):
        for name in NAMES:
            if ln.startswith(name + " ") and ln.rstrip().endswith(" ok"):
                f = ln[len(name):].split()
                m = re.search(r"n=(\d+) x (\d+) (\w+); warm-up ([0-9.]+) s; reps \(s\): ([0-9. ]+); check", lines[i + 1])
                reps = [float(x) for x in m.group(5).split()]
                ops = int(m.group(1)) * int(m.group(2))
                rows[name] = {"med": float(f[1]), "min": float(f[2]), "reps": reps, "wu": float(m.group(4)),
                              "rmed": statistics.median(reps) / ops * 1e9}
    assert len(rows) == len(NAMES), (path, sorted(rows))
    return rows

game, sa, joff, hl = (parse(p) for p in sys.argv[1:5])

def pct(a, b):
    return "%+.1f%%" % ((a / b - 1) * 100)

for name in NAMES:
    g = game[name]
    spread = (max(g["reps"]) - min(g["reps"])) / min(g["reps"]) * 100
    print("%-14s game %.2f/%.2f (reps %.3f) spread %.1f%% | vs standalone %s (reps %s) | vs harness %s (reps %s) | -joff/game %.1fx" % (
        name, g["med"], g["min"], g["rmed"], spread,
        pct(g["med"], sa[name]["med"]), pct(g["rmed"], sa[name]["rmed"]),
        pct(g["med"], hl[name]["med"]), pct(g["rmed"], hl[name]["rmed"]),
        joff[name]["med"] / g["med"]))
for label, t in (("game", game), ("standalone", sa), ("harness", hl)):
    print("crc32/pack %-10s %.3f (reps %.3f)" % (label, t["crc32 table"]["med"] / t["pack+unpack"]["med"],
                                                 t["crc32 table"]["rmed"] / t["pack+unpack"]["rmed"]))
print("game: warm-ups + reps %.2f s" % sum(sum(v["reps"]) + v["wu"] for v in game.values()))
