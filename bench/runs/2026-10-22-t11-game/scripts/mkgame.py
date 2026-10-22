import gzip, hashlib, os, subprocess, sys, zipfile
# mkgame.py <dest>: bench/runs/2026-10-22-t11-game from the 2026-10-22 game
# sessions: the results file the save holds, the log lines the record cites,
# and md5s of everything the run depended on.  ratios.py sits beside it.
G = "C:/Games/Minecraft/instances/Main/minecraft"
HOME = G + "/saves/New World/opencomputers/d219fa0e-c1cd-4c2d-bc10-55ffec782eb6/home"
REPO = "C:/Users/astro/Downloads/OC-LuaJIT"
HERE = os.path.dirname(os.path.abspath(__file__))
dest = sys.argv[1]
if os.path.exists(dest):
    sys.exit("REFUSING: " + dest + " exists")
# Built from parts so this script passes its own scan.
FORBID = (b"gm" + b"ail", b"oclj/" + b"priv" + b"ate", b"astro" + b"nfo@")

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
        assert f not in low, (rel, f)
    out = os.path.join(dest, rel)
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with open(out, "wb") as fh:
        fh.write(data)

def readlog(path):
    raw = gzip.open(path).read() if path.endswith(".gz") else open(path, "rb").read()
    return raw.decode("utf-8", "replace").split("\n")

os.makedirs(dest)
# The results file, byte for byte (it is LF and has no CR).
res = open(HOME + "/ingame-bitops-luajit.txt", "rb").read()
write("ingame-bitops-luajit.txt", res)

# Log lines, with their line numbers.
def excerpt(path, picks):
    lines = readlog(path)
    out = []
    for a, b in picks:
        for n in range(a, b + 1):
            out.append("%6d: %s" % (n, lines[n - 1].rstrip("\r")))
    return out + [""]

ex = ["# The session before, 13:17-13:32, on the previous jar: it loaded the world, saved",
      "# it and exited, writing the computer state the next session refused.", "",
      "# logs/fml-client-3.log (that session's FML log)", ""]
ex += excerpt(G + "/logs/fml-client-3.log", [(1, 1), (8988, 8988), (21686, 21686)])
ex += ["# logs/2026-10-22-1.log.gz (that session's latest.log)", ""]
ex += excerpt(G + "/logs/2026-10-22-1.log.gz", [(1, 1), (63, 63), (74, 74), (100, 100), (152, 152), (178, 178), (180, 180), (206, 206)])
ex += ["# T11's session, 13:35-13:42, on ocluajit-19a7806.jar", "",
       "# logs/latest.log (start, world join, save and exit)", ""]
ex += excerpt(G + "/logs/latest.log", [(1, 1), (59, 59), (63, 63), (74, 74), (100, 100), (102, 102), (128, 128)])
ex += ["# logs/fml-client-latest.log (start, the mod's registration and version, and the",
       "# session's one error from a computer: its saved state refused at the header)", ""]
ex += excerpt(G + "/logs/fml-client-latest.log", [(1, 1), (21684, 21684), (35819, 35819), (46039, 46044), (46085, 46090)])
write("log-excerpts.txt", "\n".join(ex))

# Identity checks.
jar = G + "/mods/ocluajit-19a7806.jar"
z = zipfile.ZipFile(jar)
dll = z.read("assets/opencomputers/lib/libjnluajit52-windows-x86_64.dll")
so = z.read("assets/opencomputers/lib/libjnluajit52-linux-x86_64.so")
kern = z.read("assets/ocluajit/lua/machine.lua")
mods = sorted(f for f in os.listdir(G + "/mods") if f.lower().startswith(("ocluajit", "opencomputers")))
fml = open(G + "/logs/fml-client-latest.log", "rb").read()
fml3 = open(G + "/logs/fml-client-3.log", "rb").read()
d = []
d.append("# md5s, 2026-10-22, read after the game exited (13:42:50)")
d.append("")
d.append("mods/ entries named ocluajit* or opencomputers*: " + ", ".join(mods))
d.append("%s  mods/ocluajit-19a7806.jar  (%d bytes)" % (md5(jar), os.path.getsize(jar)))
d.append("%s  build/libs/ocluajit-19a7806.jar  (the jar T11's setup names)" % md5(REPO + "/build/libs/ocluajit-19a7806.jar"))
d.append("%s  its assets/opencomputers/lib/libjnluajit52-windows-x86_64.dll" % md5b(dll))
d.append("%s  its assets/opencomputers/lib/libjnluajit52-linux-x86_64.so" % md5b(so))
d.append("%s  its assets/ocluajit/lua/machine.lua (the kernel)" % md5b(kern))
d.append("%s  saves/<world>/opencomputers/<address>/home/ingame-bitops.lua (the copy the run read)" % md5(HOME + "/ingame-bitops.lua"))
d.append("%s  bench/oc/ingame-bitops.lua (the repo's, at 928a119)" % md5(REPO + "/bench/oc/ingame-bitops.lua"))
d.append("%s  saves/<world>/opencomputers/<address>/home/ingame-bitops-luajit.txt = ingame-bitops-luajit.txt here" % md5b(res))
d.append("results files in that home/: " + ", ".join(sorted(f for f in os.listdir(HOME) if f.startswith("ingame-bitops-"))))
d.append("fml-client-latest.log (T11's session): %d lines containing 'eris-lj' (the error's two exception lines), %d 'Unexpected error loading a state'" % (
    fml.count(b"eris-lj"), fml.count(b"Unexpected error loading a state")))
d.append("fml-client-3.log (the session before): %d lines containing 'eris-lj', %d 'Unexpected error loading a state'" % (
    fml3.count(b"eris-lj"), fml3.count(b"Unexpected error loading a state")))
write("md5s.txt", "\n".join(d) + "\n")

# The ratio script and its output.
ratios = os.path.join(HERE, "ratios.py")
write("scripts/ratios.py", open(ratios, "rb").read())
R3 = REPO + "/bench/runs/2026-10-22-t11/run-3"
r = subprocess.run([sys.executable, "-I", ratios, HOME + "/ingame-bitops-luajit.txt",
                    R3 + "/standalone/luajit/ingame-bitops-luajit-standalone.txt",
                    R3 + "/standalone/luajit-joff/ingame-bitops-luajit-standalone.txt",
                    R3 + "/ig-luajit/home/ingame-bitops-luajit.txt"],
                   capture_output=True, check=True)
write("ratios.txt", r.stdout.replace(b"\r\n", b"\n"))
write("scripts/mkgame.py", open(os.path.abspath(__file__), "rb").read())
n = sum(len(fs) for _, _, fs in os.walk(dest))
print("files", n)
