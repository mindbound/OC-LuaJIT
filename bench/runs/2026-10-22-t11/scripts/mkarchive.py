import hashlib, os, re, shutil, sys
# mkarchive.py <dest>: bench/runs/2026-10-22-t11 from the T11 scratch runs.
# Text is copied; binaries, OpenOS tree copies and harness class dirs are
# recorded as md5s in DIGESTS.txt.
T = "C:/Users/astro/claude-tmp/oclj/t10"
SP = "C:/Users/astro/claude-tmp/claude/C--Users-astro-Downloads-OC-LuaJIT/b3c2bf14-9324-494a-a9cb-2700e7c43afc/scratchpad"
dest = sys.argv[1]
if os.path.exists(dest):
    sys.exit("REFUSING: " + dest + " exists")
digests = []
# Built from parts so this script passes its own scan.
FORBID = (b"gm" + b"ail", b"oclj/" + b"priv" + b"ate")
BIN_EXT = (".dll", ".so", ".exe", ".jar", ".class")

def md5(p):
    return hashlib.md5(open(p, "rb").read()).hexdigest()

def is_binary(p):
    if p.lower().endswith(BIN_EXT):
        return True
    return b"\0" in open(p, "rb").read(65536)

def put(src, rel, scrub=False):
    out = os.path.join(dest, rel)
    if is_binary(src):
        digests.append("%s  %s  (not copied; from %s)" % (md5(src), rel, src.replace(os.sep, "/")))
        return
    data = open(src, "rb").read().replace(b"\r\n", b"\n")
    if scrub:
        # The verifiers' report names the strings they scanned for.
        before = hashlib.md5(data).hexdigest()
        data = re.sub(b"(?i)" + FORBID[0], b"MAIL-DOMAIN", data)
        data = re.sub(b"(?i)" + FORBID[1], b"PRIVATE-SCRATCH-PATHS", data)
        digests.append("%s  %s  (before scrubbing; after: %s)" % (before, rel, hashlib.md5(data).hexdigest()))
    low = data.lower()
    assert FORBID[0] not in low and FORBID[1] not in low, src
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with open(out, "wb") as fh:
        fh.write(data)

def tree(src, rel, skip=()):
    for root, dirs, files in os.walk(src):
        r = os.path.relpath(root, src).replace(os.sep, "/")
        dirs.sort()
        for f in sorted(files):
            sub = f if r == "." else r + "/" + f
            if any(sub == s or sub.startswith(s + "/") for s in skip):
                p = os.path.join(root, f)
                digests.append("%s  %s/%s  (not copied)" % (md5(p), rel, sub))
                continue
            put(os.path.join(root, f), rel + "/" + sub)

def harness(src, rel):
    for f in ("inputs.md5", "run.log", "start.txt", "end.txt", "exit.txt"):
        put(src + "/" + f, rel + "/" + f)
    home = src + "/os/home"
    for f in sorted(os.listdir(home)):
        if f.endswith(".txt") or f == ".shrc":
            put(home + "/" + f, rel + "/home/" + f)
    digests.append("%s  %s/home/ingame-bitops.lua  (the copy the run read; not copied)" % (md5(home + "/ingame-bitops.lua"), rel))
    for f in ("ocljit.conf", "javac.log"):
        p = src + "/work/" + f
        if not os.path.exists(p):
            continue
        if f == "ocljit.conf" and not rel.startswith("run-3/"):
            # 78 KB each; run-3's are copied, the earlier runs' kept as md5s.
            digests.append("%s  %s/work/%s  (not copied; run-3 has its copy)" % (md5(p), rel, f))
        else:
            put(p, rel + "/work/" + f)
    for d in ("cwd", "work/libdir-additive"):
        p = src + "/" + d
        if os.path.isdir(p):
            for f in sorted(os.listdir(p)):
                digests.append("%s  %s/%s/%s  (not copied)" % (md5(p + "/" + f), rel, d, f))

os.makedirs(dest)
# Run 1: the draft script on the select release's natives.
harness(T + "/ig-luajit-1", "run-1/ig-luajit")
harness(T + "/ig-lua53-1", "run-1/ig-lua53")
tree(T + "/run3", "run-1/standalone")
# Run 2: the draft script on FIX-NUMCONV's natives, then the jar build.
for f in ("chain.log", "inputs.md5", "head.txt", "status.txt", "status-after.txt", "jar.md5",
          "jar-list.txt", "libs.txt", "gradle-verify.log", "gradle-build.log"):
    put(T + "/rerun-2/" + f, "run-2/" + f)
tree(T + "/rerun-2/standalone", "run-2/standalone")
harness(T + "/rerun-2/ig-luajit", "run-2/ig-luajit")
harness(T + "/rerun-2/ig-lua53", "run-2/ig-lua53")
# Run 3: the reviewed script, the readings in docs/in-game-tests.md.
for f in ("chain.log", "inputs.md5", "jar-kernel.md5", "head.txt", "status.txt", "status-after.txt"):
    put(T + "/rerun-3/" + f, "run-3/" + f)
tree(T + "/rerun-3/standalone", "run-3/standalone")
harness(T + "/rerun-3/ig-luajit", "run-3/ig-luajit")
harness(T + "/rerun-3/ig-lua53", "run-3/ig-lua53")
# The fail-first of the reviewed script's new paths.
tree(T + "/v2/ff-1", "fail-first")
# Scripts.
for src, rel in ((T + "/harness/run-ingame.sh", "scripts/run-ingame.sh"),
                 (T + "/harness/run-ingame-2.sh", "scripts/run-ingame-2.sh"),
                 (T + "/chain2.sh", "scripts/chain2.sh"),
                 (T + "/chain3.sh", "scripts/chain3.sh"),
                 (T + "/v2/ff.lua", "scripts/ff.lua"),
                 (T + "/v2/ff.sh", "scripts/ff.sh"),
                 (T + "/v2/table.py", "scripts/table.py"),
                 (T + "/v2/land.py", "scripts/land.py"),
                 (T + "/v2/mkarchive.py", "scripts/mkarchive.py"),
                 (T + "/ingame-bitops.lua", "scripts/ingame-bitops-draft.lua")):
    put(src, rel)
# Design: the draft section and the review.
put(T + "/t10-section.md", "design/t10-section-draft.md")
put(SP + "/t10-review.txt", "design/review.txt")
tree(T + "/review-1", "design/review-snippets")
# The landing's verification, and the comment-only change it led to.
put(SP + "/t11-verify.txt", "design/verify.txt", scrub=True)
for f in ("gi.lua", "rec57.lua"):
    put(T + "/verify-1/claims/" + f, "design/verify-snippets/" + f)
put(T + "/v2/comment-diff.txt", "design/script-comment-diff.txt")
# The yield-gap check: the draft's two stub runs and the reviewed script's.
put(T + "/stub/stubrun.lua", "scripts/stubrun.lua")
put(T + "/v2/stub.sh", "scripts/stub.sh")
tree(T + "/run2", "stub/draft-a")
tree(T + "/run4-stub", "stub/draft-b")
tree(T + "/v2/stub-1", "stub/reviewed")
with open(os.path.join(dest, "DIGESTS.txt"), "w", encoding="utf-8", newline="") as fh:
    fh.write("\n".join(digests) + "\n")
n = sum(len(fs) for _, _, fs in os.walk(dest))
print("files", n, "digests", len(digests))
