import re, statistics, sys
# ratios.py <luajit> <lua53> <lua54> <luajit-earlier> <standalone> <joff> <harness-luajit>
#           <harness-lua53> <puc53>: T11 results files.  Each Part 2 row of one
# game session's three arms (our LuaJIT CPU, OC's Lua 5.3 and Lua 5.4 CPUs):
# the ratios between the arms, the LuaJIT arm against an earlier game session,
# against run 3's standalone luajit.exe, its -joff and the harness's LuaJIT arm,
# and the Lua 5.3 arm against the harness's Lua 5.3 arm and standalone PUC
# 5.3.6.  Every comparison is given from the printed medians and from the
# medians of the reps; then each arm's crc32 / pack+unpack ratio.
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

lj, l53, l54, lj1, sa, joff, hlj, h53, puc = (parse(p) for p in sys.argv[1:10])

def pct(a, b, k):
    return "%+.1f%%" % ((a[k] / b[k] - 1) * 100)

def both(a, b):
    return "%s (reps %s)" % (pct(a, b, "med"), pct(a, b, "rmed"))

def x(a, b):
    return "%.2fx (reps %.2fx)" % (a["med"] / b["med"], a["rmed"] / b["rmed"])

def arm(t):
    spread = (max(t["reps"]) - min(t["reps"])) / min(t["reps"]) * 100
    return "%.2f/%.2f (reps %.3f, spread %.1f%%)" % (t["med"], t["min"], t["rmed"], spread)

for name in NAMES:
    a, b, c = lj[name], l53[name], l54[name]
    print(name)
    print("  game: LuaJIT %s | Lua 5.3 %s | Lua 5.4 %s" % (arm(a), arm(b), arm(c)))
    print("  Lua 5.3 / LuaJIT %s | Lua 5.4 / LuaJIT %s | Lua 5.4 vs Lua 5.3 %s" % (x(b, a), x(c, a), both(c, b)))
    print("  LuaJIT vs the earlier game session %s | vs harness %s | vs standalone %s | -joff / game %.1fx" % (
        both(a, lj1[name]), both(a, hlj[name]), both(a, sa[name]), joff[name]["med"] / a["med"]))
    print("  Lua 5.3 vs harness Lua 5.3 %s | vs PUC 5.3.6 standalone %s | harness Lua 5.3 / LuaJIT %s" % (
        both(b, h53[name]), both(b, puc[name]), x(h53[name], hlj[name])))

def rng(top, bot):
    v = [top[n]["med"] / bot[n]["med"] for n in NAMES]
    return "%.1f-%.1fx" % (min(v), max(v))

print("ranges (printed medians): game Lua 5.3 / LuaJIT %s, game Lua 5.4 / LuaJIT %s, harness Lua 5.3 / LuaJIT %s" % (
    rng(l53, lj), rng(l54, lj), rng(h53, hlj)))
for label, t in (("game LuaJIT", lj), ("earlier game LuaJIT", lj1), ("standalone", sa), ("harness LuaJIT", hlj),
                 ("game Lua 5.3", l53), ("game Lua 5.4", l54)):
    print("crc32/pack %-19s %.3f (reps %.3f)" % (label, t["crc32 table"]["med"] / t["pack+unpack"]["med"],
                                                  t["crc32 table"]["rmed"] / t["pack+unpack"]["rmed"]))
for label, t in (("LuaJIT", lj), ("Lua 5.3", l53), ("Lua 5.4", l54)):
    print("game %-7s warm-ups + reps %.2f s" % (label, sum(sum(v["reps"]) + v["wu"] for v in t.values())))
