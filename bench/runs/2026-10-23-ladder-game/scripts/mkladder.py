import hashlib, os, re, statistics, sys, time, zipfile
# mkladder.py <dest>: bench/runs/2026-10-23-ladder-game from the 2026-10-23
# 11:07-11:14 game session, T7's ladder runner on our LuaJIT CPU and on OC's
# Lua 5.3 and Lua 5.4 CPUs: the three output files the save holds, the log
# lines the record cites, md5s, and the comparison (ladder-ratios.txt).  It
# writes every file there but README.md, which is written by hand.  If
# OCLJ_FORBID_FILE names a file (kept outside the repo), every file written
# is checked to hold none of its lines.
G = "C:/Games/Minecraft/instances/Main/minecraft"
DISK = G + "/saves/New World/opencomputers/d219fa0e-c1cd-4c2d-bc10-55ffec782eb6"
HOME = DISK + "/home"
REPO = "C:/Users/astro/Downloads/OC-LuaJIT"
dest = sys.argv[1]
if os.path.exists(dest):
    sys.exit("REFUSING: " + dest + " exists")
FORBID = ()
if os.environ.get("OCLJ_FORBID_FILE"):
    FORBID = tuple(ln.strip().lower().encode() for ln in open(os.environ["OCLJ_FORBID_FILE"]) if ln.strip())
    print("forbidden strings checked:", len(FORBID))
else:
    print("OCLJ_FORBID_FILE not set: no forbidden-string check")
ARMS = (("LuaJIT", "ladder-luajit.txt"), ("Lua 5.3", "ladder-lua53.txt"), ("Lua 5.4", "ladder-lua54.txt"))
BENCH = ("mandelbrot", "matmul", "binarytrees")
CHECKS = {"mandelbrot": "37904620", "matmul": "481.0000", "binarytrees": "7038400"}

def md5b(b):
    return hashlib.md5(b).hexdigest()

def md5(p):
    return md5b(open(p, "rb").read())

def write(rel, data):
    if isinstance(data, str):
        data = data.encode()
    assert b"\r" not in data and b"\0" not in data, rel
    low = data.lower()
    for f in FORBID:
        assert f not in low, (rel, "a forbidden string")
    out = os.path.join(dest, rel)
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with open(out, "wb") as fh:
        fh.write(data)

def stamp(p):
    t = os.path.getmtime(p)
    return time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(t)) + ("%.2f" % (t % 1))[1:]

os.makedirs(dest)
# The runner's output files, byte for byte.
rows = {}
for arch, name in ARMS:
    raw = open(HOME + "/" + name, "rb").read()
    write(name, raw)
    rows[arch] = {}
    for ln in raw.decode().split("\n"):
        m = re.match(r"(\w+)\s+CHECK=(\S+)\s+min=([0-9.]+) s\s+reps: ([0-9. ]+)$", ln)
        if m:
            reps = [float(x) for x in m.group(4).split()]
            rows[arch][m.group(1)] = {"check": m.group(2), "min": float(m.group(3)), "reps": reps}
    assert sorted(rows[arch]) == sorted(BENCH), (arch, sorted(rows[arch]))

# Log lines, with their line numbers.
def excerpt(path, picks):
    lines = open(path, "rb").read().decode("utf-8", "replace").split("\n")
    out = []
    for a, b in picks:
        for n in range(a, b + 1):
            out.append("%6d: %s" % (n, lines[n - 1].rstrip("\r")))
    return out + [""]

L = G + "/logs/"
ex = ["# 2026-10-23, 11:07-11:14, on ocluajit-19a7806.jar: T7's ladder runner on all three CPUs", "",
      "# logs/latest.log (start, world join, OC's chat line for each CPU architecture click, saves and exit)", ""]
ex += excerpt(L + "latest.log", [(1, 1), (59, 59), (63, 63), (74, 74), (100, 105), (131, 131), (133, 133), (159, 159)])
ex += ["# logs/fml-client-latest.log (start; FML's mod count; the mod's version; the session's one",
       "# OpenComputers ERROR, the same startup recipe as in the morning's session; our architecture",
       "# registered; the world's ModTracker lines: mods updated since the morning's session; OC's",
       "# glyph-width cache first used by the client's font loader, 8 s after the join, and OC's",
       "# computer_running sound first decoded 18 s after it)", ""]
ex += excerpt(L + "fml-client-latest.log", [(1, 1), (7984, 7984), (8985, 8985), (20877, 20877), (21684, 21684),
                                            (35819, 35830), (46180, 46180), (46212, 46212)])
write("log-excerpts.txt", "\n".join(ex))

# Identity checks.
fml = open(L + "fml-client-latest.log", "rb").read()

def count(b, s):
    return sum(1 for ln in b.split(b"\n") if s in ln)

jar = G + "/mods/ocluajit-19a7806.jar"
z = zipfile.ZipFile(jar)
d = ["# md5s, 2026-10-23, read after the game exited (11:14:36)", ""]
mods = sorted(f for f in os.listdir(G + "/mods") if f.lower().startswith(("ocluajit", "opencomputers")))
d.append("mods/ entries named ocluajit* or opencomputers*: " + ", ".join(mods))
d.append("%s  mods/ocluajit-19a7806.jar  (%d bytes)" % (md5(jar), os.path.getsize(jar)))
d.append("%s  its assets/opencomputers/lib/libjnluajit52-windows-x86_64.dll" % md5b(z.read("assets/opencomputers/lib/libjnluajit52-windows-x86_64.dll")))
d.append("%s  its assets/ocluajit/lua/machine.lua (the kernel)" % md5b(z.read("assets/ocluajit/lua/machine.lua")))
for f in ("ingame-ladder.lua", "mandelbrot.lua", "matmul.lua", "binarytrees.lua"):
    a, b = md5(HOME + "/" + f), md5(REPO + "/bench/oc/" + f)
    d.append("%s  home/%s on the computer's disk; the repo's bench/oc/%s: %s" % (a, f, f, "same" if a == b else "DIFFERENT " + b))
for arch, name in ARMS:
    d.append("%s  home/%s = %s here, mtime %s" % (md5(HOME + "/" + name), name, name, stamp(HOME + "/" + name)))
STATE = G + "/saves/New World/opencomputers/state"
d.append("saves/<world>/opencomputers/state/ (OC's per-machine save files): sizes and mtimes; OC re-stamps")
d.append("every file there when the world loads (SaveHandler.onWorldLoad):")
for root, _, fs in sorted(os.walk(STATE)):
    for f in sorted(fs):
        p = os.path.join(root, f)
        d.append("  %s  %8d  %s" % (stamp(p), os.path.getsize(p), os.path.relpath(p, STATE).replace(os.sep, "/")))
d.append("fml-client-latest.log: %d lines containing 'eris-lj', %d 'Unexpected error loading a state', %d '/ERROR] [OpenComputers'" % (
    count(fml, b"eris-lj"), count(fml, b"Unexpected error loading a state"), count(fml, b"/ERROR] [OpenComputers")))
write("md5s.txt", "\n".join(d) + "\n")

# The comparison.
def harness(path):
    out = {}
    for ln in open(path, "rb").read().decode("utf-8", "replace").split("\n"):
        m = re.search(r"PHASE1 ROW: .*  (\w+)/ok/(\S+?)/([0-9.]+)/([0-9.]+)/", ln)
        if m:
            out[m.group(1)] = float(m.group(3))
    return out

HR = REPO + "/bench/runs/2026-10-05-reserve/logs/runsF/full/"
hours, hstock = harness(HR + "fullF-additive-on.log"), harness(HR + "fullF-stock.log")
T9 = {"mandelbrot": 0.0657, "matmul": 0.0862, "binarytrees": 0.2521}
r = ["# Each bench's min of 5 reps (the runner's figure) and its median, per CPU, in seconds;",
     "# the ratios between the CPUs; our CPU against T9's in-game reading (docs/in-game-tests.md, T9,",
     "# 2026-10-03, the 0c656ac jar) and against the pinned harness's last run of these benches",
     "# (bench/runs/2026-10-05-reserve/logs/runsF/full/: fullF-additive-on.log, ours; fullF-stock.log,",
     "# stock PUC 5.2 under OC's kernel; min of 5).", ""]
for bname in BENCH:
    r.append(bname)
    for arch, _ in ARMS:
        x = rows[arch][bname]
        ok = "ok" if x["check"] == CHECKS[bname] else "CHECK MISMATCH"
        spread = (max(x["reps"]) - min(x["reps"])) / min(x["reps"]) * 100
        r.append("  %-7s CHECK=%s (%s)  min %.4f  median %.3f  reps %s  spread %.1f%%" % (
            arch, x["check"], ok, x["min"], statistics.median(x["reps"]), " ".join("%.3f" % v for v in x["reps"]), spread))
    lj, l53, l54 = (rows[a][bname] for a, _ in ARMS)
    r.append("  Lua 5.3 / LuaJIT %.2fx (medians %.2fx) | Lua 5.4 / LuaJIT %.2fx (medians %.2fx) | Lua 5.4 / Lua 5.3 %.3f" % (
        l53["min"] / lj["min"], statistics.median(l53["reps"]) / statistics.median(lj["reps"]),
        l54["min"] / lj["min"], statistics.median(l54["reps"]) / statistics.median(lj["reps"]), l54["min"] / l53["min"]))
    r.append("  LuaJIT vs T9 in game %+.1f%% | vs harness (ours, 2026-10-05) %.4f, %+.1f%% | harness stock PUC 5.2 %.4f, Lua 5.3 in game / it %.3f" % (
        (lj["min"] / T9[bname] - 1) * 100, hours[bname], (lj["min"] / hours[bname] - 1) * 100, hstock[bname], l53["min"] / hstock[bname]))
write("ladder-ratios.txt", "\n".join(r) + "\n")
write("scripts/mkladder.py", open(os.path.abspath(__file__), "rb").read())
print("files", sum(len(fs) for _, _, fs in os.walk(dest)))
