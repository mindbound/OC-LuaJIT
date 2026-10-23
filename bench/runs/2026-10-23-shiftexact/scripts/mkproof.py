import hashlib, os, re, sys
# mkproof.py <dest>: bench/runs/2026-10-23-shiftexact from the proof round's
# scratch (claude-tmp/oclj/shiftexact): the argument, its review, the checks
# and their one run, and the CSE-twin probes.  It writes every file there but
# README.md, which is written by hand.  Copies are byte for byte except the
# CSE probes' outputs (cse/run-*), whose CRLF line ends and -jdump colour
# codes are stripped (their md5s as run are listed in md5s.txt).  If OCLJ_FORBID_FILE names a file (kept outside the
# repo), every file written is checked to hold none of its lines.
SRC = "C:/Users/astro/claude-tmp/oclj/shiftexact"
dest = sys.argv[1]
if os.path.exists(dest):
    sys.exit("REFUSING: " + dest + " exists")
FORBID = ()
if os.environ.get("OCLJ_FORBID_FILE"):
    FORBID = tuple(ln.strip().lower().encode() for ln in open(os.environ["OCLJ_FORBID_FILE"]) if ln.strip())
    print("forbidden strings checked:", len(FORBID))
else:
    print("OCLJ_FORBID_FILE not set: no forbidden-string check")

def md5b(b):
    return hashlib.md5(b).hexdigest()

def write(rel, data):
    assert b"\r" not in data and b"\0" not in data, rel
    low = data.lower()
    for f in FORBID:
        assert f not in low, (rel, "a forbidden string")
    out = os.path.join(dest, rel)
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with open(out, "wb") as fh:
        fh.write(data)

ESC = re.compile(rb"\x1b\[[0-9;]*m")
COPY = ["argue/argument.md", "refute/notes.md", "checks/model.py", "checks/jitcheck.lua", "checks/run.sh",
        "cse/cse-fwd.lua", "cse/cse-fwd2.lua", "cse/cse-ir.lua",
        "cse/run-1/joff.txt", "cse/run-1/jit.txt", "cse/run-2/jdump2.txt",
        "cse/run-3/joff.txt", "cse/run-3/jit.txt", "cse/run-3/jdump.txt"]
R1 = "checks/runs/run-1"
for f in sorted(os.listdir(SRC + "/" + R1)):
    if not f.endswith(".raw") and os.path.isfile(SRC + "/" + R1 + "/" + f):
        COPY.append(R1 + "/" + f)
os.makedirs(dest)
lines = ["# md5s of every file copied, as it is in scratch (the CSE probes' output copies here have",
         "# their CRLF line ends and ANSI colour codes stripped), and of the binaries the runs used", ""]
for rel in COPY:
    raw = open(SRC + "/" + rel, "rb").read()
    data = raw
    if rel.startswith("cse/run-"):
        # luajit.exe wrote these through a text-mode stdout (CRLF) and -jdump colours.
        data = ESC.sub(b"", data.replace(b"\r\n", b"\n"))
    write(rel, data)
    lines.append("%s  %s%s" % (md5b(raw), rel, "  (stripped copy %s)" % md5b(data) if data != raw else ""))
lines += ["", "# the checks' run read these (" + R1 + "/inputs.md5, as the run wrote it):", ""]
lines += ["  " + ln for ln in open(SRC + "/" + R1 + "/inputs.md5").read().strip().split("\n")]
LJ = "C:/Users/astro/Downloads/OC-LuaJIT/build/native/luajit-windows-x86_64/src/luajit.exe"
lines += ["", "# the CSE probes ran (cse/run-1 to run-3; 2026-10-23, before the checks):", "",
          "%s  build/native/luajit-windows-x86_64/src/luajit.exe" % md5b(open(LJ, "rb").read())]
write("md5s.txt", ("\n".join(lines) + "\n").encode())
write("scripts/mkproof.py", open(os.path.abspath(__file__), "rb").read())
print("files", sum(len(fs) for _, _, fs in os.walk(dest)))
