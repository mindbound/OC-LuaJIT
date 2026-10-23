import difflib, gzip, hashlib, os, re, subprocess, sys, time, zipfile
# mkgame.py <dest> [<dir of the copies sent with the request>]:
# bench/runs/2026-10-23-t11-game from the 2026-10-23 game session, T11 on all
# three CPUs: the results files the save holds, the log lines the record
# cites, and md5s of everything the runs depended on.  It writes every file
# there but README.md, which is written by hand; ratios.py sits beside it.
# The optional second argument is the directory holding the copies of the
# three results files the user sent with the request for this record; without
# it, md5s.txt has no line comparing them with the save's.  If
# OCLJ_FORBID_FILE names a file (kept outside the repo), every file written is
# checked to hold none of its lines.
G = "C:/Games/Minecraft/instances/Main/minecraft"
HOME = G + "/saves/New World/opencomputers/d219fa0e-c1cd-4c2d-bc10-55ffec782eb6/home"
STATE = G + "/saves/New World/opencomputers/state"
REPO = "C:/Users/astro/Downloads/OC-LuaJIT"
HERE = os.path.dirname(os.path.abspath(__file__))
dest = sys.argv[1]
sent = sys.argv[2] if len(sys.argv) > 2 else None
if os.path.exists(dest):
    sys.exit("REFUSING: " + dest + " exists")
FORBID = ()
if os.environ.get("OCLJ_FORBID_FILE"):
    FORBID = tuple(ln.strip().lower().encode() for ln in open(os.environ["OCLJ_FORBID_FILE"]) if ln.strip())
    print("forbidden strings checked:", len(FORBID))
else:
    print("OCLJ_FORBID_FILE not set: no forbidden-string check")
RESULTS = ("ingame-bitops-luajit-2.txt", "ingame-bitops-lua53.txt", "ingame-bitops-lua54.txt")

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

def readlog(path):
    raw = gzip.open(path).read() if path.endswith(".gz") else open(path, "rb").read()
    return raw.decode("utf-8", "replace").split("\n")

def stamp(p):
    t = os.path.getmtime(p)
    return time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(t)) + ("%.2f" % (t % 1))[1:]

os.makedirs(dest)
# The results files, byte for byte (LF, no CR).
res = {}
for name in RESULTS:
    res[name] = open(HOME + "/" + name, "rb").read()
    write(name, res[name])

# Log lines, with their line numbers.
def excerpt(path, picks):
    lines = readlog(path)
    out = []
    for a, b in picks:
        for n in range(a, b + 1):
            out.append("%6d: %s" % (n, lines[n - 1].rstrip("\r")))
    return out + [""]

L = G + "/logs/"
ex = ["# Log names are as of 2026-10-23, after this session's start rotated them: the",
      "# 2026-10-22 T11 session's FML log, then fml-client-latest.log, is now",
      "# fml-client-3.log, and its latest.log is now 2026-10-22-2.log.gz.", "",
      "# 2026-10-23, 09:31-09:40, on ocluajit-19a7806.jar: T11 on all three CPUs", "",
      "# logs/latest.log (start, world join, OC's chat line for each CPU architecture",
      "# click, saves and exit)", ""]
ex += excerpt(L + "latest.log", [(1, 1), (59, 59), (63, 63), (74, 79), (105, 105), (107, 107), (133, 133)])
ex += ["# logs/fml-client-latest.log (start; FML's mod count; Hodgepodge, the one mod whose",
       "# version changed since 2026-10-22; the mod's version; the session's one",
       "# OpenComputers ERROR, a recipe at startup; OC's Lua 5.3 and 5.4 natives loaded",
       "# from its jar; our architecture registered; the world's one ModTracker line;",
       "# OC's glyph-width cache first used on a computer thread, 3 s after the join; and",
       "# Hodgepodge's first decode of OC's computer_running sound, 6 s after the join)", ""]
ex += excerpt(L + "fml-client-latest.log", [(1, 1), (7976, 7976), (8810, 8810), (8978, 8978), (16306, 16307),
                                            (20877, 20877), (21684, 21684), (35819, 35819), (46090, 46090),
                                            (46093, 46093), (46125, 46125)])
ex += ["# 2026-10-22, 13:35-13:42, the LuaJIT arm's session (../2026-10-22-t11-game/): its last",
       "# save, under this jar, is the world this session loaded", "",
       "# logs/2026-10-22-2.log.gz (that session's latest.log)", ""]
ex += excerpt(L + "2026-10-22-2.log.gz", [(63, 63), (74, 74), (102, 102), (128, 128)])
ex += ["# logs/fml-client-3.log (that session's FML log: FML's mod count and Hodgepodge's",
       "# version then, the same recipe ERROR, the state refused at load, the glyph-width",
       "# cache first used by the client's font loader, 8 s after the join, and the",
       "# computer_running sound first decoded 31 s after the join)", ""]
ex += excerpt(L + "fml-client-3.log", [(1, 1), (7984, 7984), (8817, 8817), (20877, 20877), (35819, 35819),
                                       (46039, 46040), (46214, 46214), (46252, 46252)])
ex += ["# 2026-10-22, 13:17-13:32, the session before, on a4994e6's jar, which logged no",
       "# eris-lj text: the glyph-width cache first used on a computer thread, 6 s after",
       "# the join, and the computer_running sound first decoded 7 s after it",
       "# (logs/2026-10-22-1.log.gz:63, ../2026-10-22-t11-game/)", "",
       "# logs/fml-client-2.log", ""]
ex += excerpt(L + "fml-client-2.log", [(1, 1), (46578, 46578), (46623, 46623)])
write("log-excerpts.txt", "\n".join(ex))

# Identity checks.
jar = G + "/mods/ocluajit-19a7806.jar"
z = zipfile.ZipFile(jar)
dll = z.read("assets/opencomputers/lib/libjnluajit52-windows-x86_64.dll")
so = z.read("assets/opencomputers/lib/libjnluajit52-linux-x86_64.so")
kern = z.read("assets/ocluajit/lua/machine.lua")
ocjar = G + "/mods/OpenComputers-1.12.64-GTNH.jar"
oz = zipfile.ZipFile(ocjar)
mods = sorted(f for f in os.listdir(G + "/mods") if f.lower().startswith(("ocluajit", "opencomputers", "hodgepodge")))

def modlist(path):
    # FML's mod list, API list and state table: a tab, a name and "(".
    keep = []
    for ln in readlog(path):
        ln = ln.rstrip("\r")
        if re.match(r"\[[^\]]*\] \[Client thread/DEBUG\] \[FML/\]: \t[^ ]+\(", ln):
            keep.append(ln.split("] ", 1)[1])
    return sorted(keep)

ma, mb = modlist(L + "fml-client-3.log"), modlist(L + "fml-client-latest.log")
gone = [m for m in ma if m not in mb]
new = [m for m in mb if m not in ma]

def apijar(m):
    return m.rsplit("): ", 1)[1].rsplit(" (", 1)[0] if "(API: " in m else None

fml = open(L + "fml-client-latest.log", "rb").read()
fml3 = open(L + "fml-client-3.log", "rb").read()

def count(b, s):
    return sum(1 for ln in b.split(b"\n") if s in ln)

def luaversion(b):
    m = re.search(rb"\$LuaVersion: ([^$]*?)  Copyright", b)
    return m.group(1).decode() if m else "?"

d = []
d.append("# md5s, 2026-10-23, read after the game exited (09:40:31)")
d.append("")
d.append("mods/ entries named ocluajit*, opencomputers* or hodgepodge*: " + ", ".join(mods))
d.append("%s  mods/ocluajit-19a7806.jar  (%d bytes)" % (md5(jar), os.path.getsize(jar)))
d.append("%s  build/libs/ocluajit-19a7806.jar  (the jar T11's setup names)" % md5(REPO + "/build/libs/ocluajit-19a7806.jar"))
d.append("%s  its assets/opencomputers/lib/libjnluajit52-windows-x86_64.dll" % md5b(dll))
d.append("%s  its assets/opencomputers/lib/libjnluajit52-linux-x86_64.so" % md5b(so))
d.append("%s  its assets/ocluajit/lua/machine.lua (the kernel)" % md5b(kern))
digests = open(REPO + "/bench/runs/2026-10-22-t11/DIGESTS.txt").read().split("\n")
for v in ("53", "54"):
    b = oz.read("assets/opencomputers/lib/libjnlua%s-windows-x86_64.dll" % v)
    d.append("%s  mods/OpenComputers-1.12.64-GTNH.jar's libjnlua%s-windows-x86_64.dll (%s)" % (md5b(b), v, luaversion(b)))
    want = "run-3/ig-lua53/cwd/Ocelot-0.24.2-%s-libjnlua%s-windows-x86_64.dll" % (v, v)
    hit = [i + 1 for i, ln in enumerate(digests) if want in ln and ln.startswith(md5b(b))]
    d.append("  the same md5 as %s in ../2026-10-22-t11/DIGESTS.txt: %s" % (want, ("yes, line %d" % hit[0]) if hit else "NO"))
d.append("  (run 3's harness Lua 5.3 arm ran the -53- native; the harness had no Lua 5.4 arm)")
ock = oz.read("assets/opencomputers/lua/machine.lua")
d.append("%s  mods/OpenComputers-1.12.64-GTNH.jar's assets/opencomputers/lua/machine.lua (OC's stock kernel)" % md5b(ock))
OBK = "C:/Users/astro/Downloads/ocelot-brain/src/main/resources/assets/opencomputers/lua/machine.lua"
obk = open(OBK, "rb").read()
d.append("%s  ocelot-brain's src/main/resources/assets/opencomputers/lua/machine.lua (the harness's stock kernel)" % md5b(obk))
a = ock.replace(b"\r\n", b"\n").decode().split("\n")
b = obk.replace(b"\r\n", b"\n").decode().split("\n")
dl =[ln for ln in difflib.unified_diff(b, a, "ocelot-brain", "OC-1.12.64", n=0, lineterm="")
      if not ln.startswith(("---", "+++"))]
d.append("  their lines once CRLF is read as LF (ocelot-brain's against OC 1.12.64's):")
d += ["    " + ln for ln in dl]
d.append("%s  saves/<world>/opencomputers/<address>/home/ingame-bitops.lua (the copy the runs read)" % md5(HOME + "/ingame-bitops.lua"))
d.append("%s  bench/oc/ingame-bitops.lua (the repo's)" % md5(REPO + "/bench/oc/ingame-bitops.lua"))
for name in RESULTS:
    d.append("%s  saves/<world>/opencomputers/<address>/home/%s = %s here" % (md5b(res[name]), name, name))
if sent:
    same = all(any(f.endswith(name) and md5(os.path.join(sent, f)) == md5b(res[name]) for f in os.listdir(sent))
               for name in RESULTS)
    d.append("the copies of the three results files the user sent with the request for this record have the same md5s: " + ("yes" if same else "NO"))
d.append("%s  saves/<world>/opencomputers/<address>/home/ingame-bitops-luajit.txt (2026-10-22's, ../2026-10-22-t11-game/)" % md5(HOME + "/ingame-bitops-luajit.txt"))
d.append("results files in that home/, with their mtimes (local time):")
for f in sorted(f for f in os.listdir(HOME) if f.startswith("ingame-bitops-")):
    d.append("  %s  %s" % (stamp(HOME + "/" + f), f))
d.append("saves/<world>/opencomputers/state/ (OC's per-machine save files): sizes and mtimes, not md5s; OC re-stamps")
d.append("every file there when the world loads (SaveHandler.onWorldLoad):")
for root, _, fs in sorted(os.walk(STATE)):
    for f in sorted(fs):
        p = os.path.join(root, f)
        d.append("  %s  %8d  %s" % (stamp(p), os.path.getsize(p), os.path.relpath(p, STATE).replace(os.sep, "/")))
d.append("FML: '%s' (this session), '%s' (2026-10-22's T11 session)" % (
    re.search(rb"Forge Mod Loader has identified \d+ mods to load", fml).group(0).decode(),
    re.search(rb"Forge Mod Loader has identified \d+ mods to load", fml3).group(0).decode()))
d.append("FML's mod list, API list and state table (%d lines 2026-10-22, %d 2026-10-23); lines only in 2026-10-22's:" % (len(ma), len(mb)))
d += ["  " + m for m in gone]
d.append("lines only in 2026-10-23's:")
d += ["  " + m for m in new]
jars = sorted(set(j for j in map(apijar, gone + new) if j))
d.append("the jars those API lines name, each present in both days' lists: " + ", ".join(
    "%s %s" % (j, "yes" if any(j in m and "(API: " not in m for m in ma) and any(j in m and "(API: " not in m for m in mb) else "NO")
    for j in jars))
d.append("fml-client-latest.log (this session): %d lines containing 'eris-lj', %d 'Unexpected error loading a state', %d '/ERROR] [OpenComputers'" % (
    count(fml, b"eris-lj"), count(fml, b"Unexpected error loading a state"), count(fml, b"/ERROR] [OpenComputers")))
d.append("fml-client-3.log (2026-10-22's T11 session): %d lines containing 'eris-lj', %d 'Unexpected error loading a state', %d '/ERROR] [OpenComputers'" % (
    count(fml3, b"eris-lj"), count(fml3, b"Unexpected error loading a state"), count(fml3, b"/ERROR] [OpenComputers")))
write("md5s.txt", "\n".join(d) + "\n")

# Lua 5.4's '0x10' | 0 against 5.3.6's, standalone (the check the file skips on a 5.4 CPU).
V = REPO + "/bench/vendor/"
PROBE = "print(_VERSION, pcall(function() return ('0x10') | 0 end))"
p = ["# The check T11 skips on a Lua 5.4 CPU, run standalone on the vendored interpreters:",
     "#   <lua.exe> -e \"" + PROBE + "\"", ""]
for rel, lib in (("lua-5.4.8/src/lua.exe", "lua-5.4.8/src/lua54.dll"), ("lua-5.3.6/src/lua.exe", "lua-5.3.6/src/lua53.dll")):
    o = subprocess.run([V + rel, "-e", PROBE], capture_output=True, check=True).stdout
    p.append("%s  bench/vendor/%s (the front end)" % (md5(V + rel), rel))
    p.append("%s  bench/vendor/%s (the VM it loads)" % (md5(V + lib), lib))
    p.append("  " + o.decode().replace("\r\n", "\n").strip().replace("\t", " | "))
write("probe-lua54.txt", "\n".join(p) + "\n")

# The ratio script and its output.
ratios = os.path.join(HERE, "ratios.py")
write("scripts/ratios.py", open(ratios, "rb").read())
R3 = REPO + "/bench/runs/2026-10-22-t11/run-3"
r = subprocess.run([sys.executable, "-I", ratios] + [HOME + "/" + n for n in RESULTS] +
                   [HOME + "/ingame-bitops-luajit.txt",
                    R3 + "/standalone/luajit/ingame-bitops-luajit-standalone.txt",
                    R3 + "/standalone/luajit-joff/ingame-bitops-luajit-standalone.txt",
                    R3 + "/ig-luajit/home/ingame-bitops-luajit.txt",
                    R3 + "/ig-lua53/home/ingame-bitops-lua53.txt",
                    R3 + "/standalone/puc53/ingame-bitops-lua53-standalone.txt"],
                   capture_output=True, check=True)
write("ratios.txt", r.stdout.replace(b"\r\n", b"\n"))
write("scripts/mkgame.py", open(os.path.abspath(__file__), "rb").read())
n = sum(len(fs) for _, _, fs in os.walk(dest))
print("files", n)
