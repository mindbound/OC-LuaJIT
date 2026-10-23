"""mkcse.py <dest> [--fc <final-check outdir>] [--release <release dir>]

Builds bench/runs/2026-10-23-csetwin/, the evidence archive of the CSE type twin round (roadmap row 271, the
int/i64 CSE twins; patch-bitop-fold.sh hunk 12), from the round's scratch, claude-tmp/oclj/csetwin/.  <dest> must
not exist (its parent must).  Without --fc or --release that section is left out and the README's placeholders for
it stay; with them, the README's placeholders are filled from the final check's outdir and the release's md5 lists
where they can be read unambiguously, and the script says which it could not fill.

What it copies: the round's design, every stage's returned report, and the stage files that back the docs' [M]
claims, chosen by name below (a curated list: every file in it was read when the list was written, 2026-10-23); and,
from --fc and --release, the text files their rules below keep (those two were not run when this was written:
read what the script lists before committing).  It never copies a binary, a LuaJIT source, a tar, a build tree,
negctl's work directories beyond their logs and object md5 lists, the generator's and the suites' run outputs, or
the upstream part's reproducer and sources (the user's decision D3): md5s.txt lists their md5s instead.

Copies are byte for byte except: CRLF and lone CR become LF, ANSI colour codes are removed, and the pattern of the
final check's scratch-path check, and the one source path this script refuses, read PRIVATE-SCRATCH-PATHS; md5s.txt
gives the md5 as in scratch and the copy's.  Every file is built in memory first; nothing is written unless all of
them hold no CR and no NUL, no copy of the refused path, and (with OCLJ_FORBID_FILE set to a file kept outside the
repo) none of that file's lines, case-insensitively.  A forbidden string is never printed: only the archived file
and line that hold one.  A destination inside the repo is refused unless that file names at least one string.
Writes bytes; LF.  Written 2026-10-23 for the CSE round's docs half; the docs fixer added the repo refusal, the
by-spelling refusal of each file and directory --fc and --release walk before it is opened or counted, and MiB.
"""
import hashlib, os, re, sys

HOME = "C:/Users/astro/"
SRC = HOME + "claude-tmp/oclj/csetwin"
R = SRC + "/round"
ARCH = SRC + "/archive"
REPO = HOME + "Downloads/OC-LuaJIT"
PRIV = "PRIVATE-SCRATCH-PATHS"
REDACT = [(b"PRIVATE-SCRATCH-PATHS", b"PRIVATE-SCRATCH-PATHS")]
# Per-file redactions (the main session, 2026-10-23): the code-level text of a reverse-order slot shape, where
# the reports quote the code verifier's rejected fail-first or its loop-copy route.  The texts live in
# FREDACT_FILE, kept in scratch and never archived (so this script, archived, does not carry them): a JSON map
# from an archive path to [old, new] pairs; each old text must occur once in its file, and in no archived file
# afterwards.
FREDACT_FILE = SRC + "/archive/fredact.json"
import json
FREDACT = {k: [(a.encode("utf-8"), b.encode("utf-8")) for a, b in v]
           for k, v in json.load(open(FREDACT_FILE, encoding="utf-8")).items()}
PRIVRE = re.compile(rb"(?i)(oclj|claude-tmp)[/\\]+private")
ESC = re.compile(rb"\x1b\[[0-9;?]*[A-Za-z]")
BINEXT = (".o", ".a", ".exe", ".dll", ".so", ".jar", ".tar", ".gz", ".zip", ".class", ".lib", ".pdb", ".obj",
          ".bin", ".png", ".jpg", ".zst", ".xz")
LJSRC = (".c", ".h", ".dasc")
BIGTEXT = 1024 * 1024
MAXTOTAL = 12 * 1024 * 1024
WIDTH = 120

# ------------------------------------------------------------------ arguments
def die(msg, code=2):
    print(msg)
    sys.exit(code)

args = sys.argv[1:]
if not args or args[0].startswith("--"):
    die(__doc__.split("\n\n")[0])
dest = args[0]
FC = REL = None
i = 1
while i < len(args):
    if args[i] == "--fc" and i + 1 < len(args):
        FC = args[i + 1].replace("\\", "/").rstrip("/"); i += 2
    elif args[i] == "--release" and i + 1 < len(args):
        REL = args[i + 1].replace("\\", "/").rstrip("/"); i += 2
    else:
        die("unknown argument " + args[i])

def under(p, root):
    """p is root or below it, by its spelling first (nothing is opened) and then resolved"""
    b = root.replace("\\", "/").lower().rstrip("/")
    for a in (os.path.abspath(p), None):
        if a is None:
            a = os.path.realpath(p)
        a = a.replace("\\", "/").lower().rstrip("/")
        if a == b or a.startswith(b + "/"):
            return True
    return False

def refuse_priv(p):
    if under(p, PRIV):
        die("REFUSING: a source or destination under a path this script never reads or writes (it is not named here)", 97)

dest = dest.replace("\\", "/").rstrip("/")
refuse_priv(dest)
if os.path.exists(dest):
    die("REFUSING: " + dest + " exists (never reuse a results directory)", 97)
if not os.path.isdir(os.path.dirname(os.path.abspath(dest))):
    die("REFUSING: the parent of " + dest + " does not exist", 97)
for root in (R, SRC + "/final", SRC + "/upstream"):
    if under(dest, root):
        die("REFUSING: " + dest + " is inside " + root + ", which this script only reads", 97)
for name, d in (("--fc", FC), ("--release", REL)):
    if d is not None:
        refuse_priv(d)
        if not os.path.isdir(d):
            die("no " + name + " directory " + d)
if FC is not None and not os.path.isfile(FC + "/ALL.done"):
    die("REFUSING: " + FC + "/ALL.done is missing: the final check has not finished")

FORBID = ()
if os.environ.get("OCLJ_FORBID_FILE"):
    with open(os.environ["OCLJ_FORBID_FILE"], "rb") as fh:
        FORBID = tuple(ln.strip().lower() for ln in fh.read().split(b"\n") if ln.strip())
    print("forbidden strings checked:", len(FORBID))
else:
    print("OCLJ_FORBID_FILE not set: no forbidden-string check")
if not FORBID and under(dest, REPO):
    die("REFUSING: " + dest + " is inside " + REPO + " and no forbidden string is checked: set OCLJ_FORBID_FILE "
        "to the file of them (it must name at least one)", 97)

# ------------------------------------------------------------------ the plan
COPY = []      # (archive path, source path)
DIGEST = []    # (archive or label path, source path, why)
SKIPPED = []   # (label, files, bytes, why): whole directories left out of --fc and --release
BINS = []      # (label, source path): binaries the runs used, md5 only

def short(p):
    p = p.replace("\\", "/")
    return p[len(HOME):] if p.lower().startswith(HOME.lower()) else p

def C(rel, src):
    refuse_priv(src)
    COPY.append((rel, src))

def CS(dst, srcdir, names):
    for n in names:
        C(dst + "/" + n, srcdir + "/" + n)

def files_in(d):
    return sorted(f for f in os.listdir(d) if os.path.isfile(os.path.join(d, f)))

def CA(dst, srcdir, drop=()):
    """every file directly in srcdir, but those named in drop"""
    for n in files_in(srcdir):
        if n not in drop:
            C(dst + "/" + n, srcdir + "/" + n)

def CR(dst, srcdir):
    """every file under srcdir, recursively"""
    for dp, dns, fns in os.walk(srcdir):
        dns.sort()
        rel = os.path.relpath(dp, srcdir).replace("\\", "/")
        for f in sorted(fns):
            r = f if rel == "." else rel + "/" + f
            C(dst + "/" + r, srcdir + "/" + r)

def D(label, src, why):
    refuse_priv(src)
    DIGEST.append((label, src, why))

def B(label, src):
    refuse_priv(src)
    BINS.append((label, src))

def count_tree(d):
    n = b = 0
    for dp, dns, fns in os.walk(d):
        for f in fns:
            n += 1
            try:
                b += os.path.getsize(os.path.join(dp, f))
            except OSError:
                pass
    return n, b

def X(label, d, why):
    """a directory of the round left out whole: its file count and bytes in md5s.txt"""
    refuse_priv(d)
    if os.path.isdir(d):
        n, b = count_tree(d)
        SKIPPED.append((label, n, b, why))

def negctl_work(dst, workroot):
    """negctl-bitop.sh's work directories (<stamp>-<pid>): summary.txt, canon-obj.md5, and in each arm's
    directory (canon, restore and every arm) its logs, obj.md5 and gate.txt; tmp/'s patch logs"""
    if not os.path.isdir(workroot):
        return
    for stamp in sorted(os.listdir(workroot)):
        w = workroot + "/" + stamp
        if not os.path.isdir(w):
            continue
        for n in files_in(w):
            if n in ("summary.txt", "canon-obj.md5"):
                C("%s/%s/%s" % (dst, stamp, n), w + "/" + n)
        for sub in sorted(os.listdir(w)):
            sd = w + "/" + sub
            if not os.path.isdir(sd) or sub == "ser":
                continue
            for n in files_in(sd):
                if n.endswith(".log") or (sub != "tmp" and (n.endswith(".md5") or n == "gate.txt")):
                    C("%s/%s/%s/%s" % (dst, stamp, sub, n), sd + "/" + n)

# design/: the fix options only.  The design and the census stay in scratch, md5s only (the main session,
# 2026-10-23): written before the user's decisions, they sketch reverse-order slot shapes at the level of code,
# and the public archive keeps no reverse slot shape beyond the shape family that roadmap row 271 names.
D("(not archived) csetwin/design.md", SRC + "/design.md",
  "the design; kept in scratch: it sketches reverse-order slot shapes at the level of code")
D("(not archived) csetwin/census/census.md", SRC + "/census/census.md",
  "the producer census; kept in scratch: it sketches reverse-order slot shapes at the level of code")
D("(not archived) csetwin/archive/fredact.json", FREDACT_FILE,
  "the per-file redactions' texts; kept in scratch: they are the redacted code")
C("design/options.md", SRC + "/options/options.md")
# scripts/: the release script (the main session's; FIX-NUMCONV's with the eight files' md5 refusal)
C("scripts/release.sh", SRC + "/main/release.sh")

# code/: impl-code
S = R + "/impl-code"
C("code/REPORT.md", SRC + "/review/code.md")
CS("code", S, ["repo-vs-head.txt", "repo-source.txt", "head-changed-files.md5", "repo-changed-files.md5",
               "inputs-ff.md5"])
CA("code/scripts", S + "/scripts")
CA("code/cmp", S + "/cmp")
CA("code/objdiff", S + "/objdiff")
CA("code/logs", S + "/logs")
CS("code/ff-patch-3", S + "/ff-patch-3", ["results.txt", "inputs.md5"])
CS("code/ff-instr-1", S + "/ff-instr-1", ["results.txt", "inputs.md5"])
CA("code/smoke-fwd-1", S + "/smoke-fwd-1")
CA("code/smoke-fwd-jv-1", S + "/smoke-fwd-jv-1")
CA("code/run-fix-1", S + "/run-fix-1", drop=("repo-before.md5", "repo-after.md5"))
CA("code/run-fix-1/rc", S + "/run-fix-1/rc")
D("code/head-1a13bed.tar", S + "/head-1a13bed.tar", "HEAD 1a13bed's tree, git archive")
D("code/head-patch-bitop-fold.sh", S + "/head-patch-bitop-fold.sh", "HEAD's script, in git")
D("code/pristine/lj_opt_fold.c", S + "/pristine/lj_opt_fold.c", "LuaJIT source, the pin's")
D("code/tip/lj_opt_fold.c", S + "/tip/lj_opt_fold.c", "LuaJIT source, a4c0645's")
D("code/try-1/lj_opt_fold.c", S + "/try-1/lj_opt_fold.c", "LuaJIT source, patched")
D("code/run-fix-1/repo-before.md5", S + "/run-fix-1/repo-before.md5", "the scratch repo's md5 list, 5221 files")
D("code/run-fix-1/repo-after.md5", S + "/run-fix-1/repo-after.md5", "the same after the runs")
B("impl-code build-fix luajit.exe", S + "/build-fix/luajit-windows-x86_64/src/luajit.exe")
B("impl-code build-fix lj_opt_fold.o", S + "/build-fix/luajit-windows-x86_64/src/lj_opt_fold.o")
B("impl-code build-fix DLL (scratch)", S + "/build-fix/dist/libjnluajit52-windows-x86_64.dll")
B("impl-code build-commentonly lj_opt_fold.o", S + "/build-commentonly/luajit-windows-x86_64/src/lj_opt_fold.o")

# tests/: impl-tests
S = R + "/impl-tests"
C("tests/REPORT.md", SRC + "/review/tests.md")
CS("tests", S, ["deliverables.md5", "base-copy.md5", "run-bitjit.diff"])
CA("tests/scripts", S + "/scripts")
for p in ("proto-fix", "proto-fwd"):
    CA("tests/" + p, S + "/" + p)
    B("impl-tests %s lj_opt_fold.o (prototype)" % p, S + "/" + p + "/luajit-windows-x86_64/src/lj_opt_fold.o")
CA("tests/runs", S + "/runs")
CA("tests/runs/alma-base-1", S + "/runs/alma-base-1")
for p in ("smoke-base-1", "smoke-base-2", "smoke-proto-1"):
    CA("tests/runs/" + p, S + "/runs/" + p)

# integrate/
S = R + "/integrate"
C("integrate/REPORT.md", SRC + "/review/integ.md")
CS("integrate", S, ["apply-manifest.md5", "scripts.md5", "t4-census-1.recount.txt"])
CA("integrate/scripts", S + "/scripts")
CA("integrate/logs", S + "/logs", drop=("round-repo-end.md5",))
D("integrate/logs/round-repo-end.md5", S + "/logs/round-repo-end.md5", "the scratch repo's md5 list at the end")
CS("integrate/start", S + "/start", ["build-native.md5", "real-repo-status.txt"])
D("integrate/start/round-repo-before.md5", S + "/start/round-repo-before.md5", "the scratch repo's md5 list")
CA("integrate/cmp", S + "/cmp")
CA("integrate/runs", S + "/runs")
# T4's instrument fail-first: its refusal lines are in the cse part's nonempty .err files
T4 = S + "/runs/t4-cse-1"
C("integrate/runs/t4-cse-1/inputs.md5", T4 + "/inputs.md5")
t4n = t4b = 0
for n in files_in(T4 + "/cse"):
    if n.endswith(".err") and os.path.getsize(T4 + "/cse/" + n) > 0:
        C("integrate/runs/t4-cse-1/cse/" + n, T4 + "/cse/" + n)
    else:
        t4n, t4b = t4n + 1, t4b + os.path.getsize(T4 + "/cse/" + n)
SKIPPED.append(("integrate/runs/t4-cse-1/cse (its other files)", t4n, t4b,
                "the instrumented cse part's results and its empty .err files"))
CR("integrate/ff-check", S + "/ff-check")
CS("integrate/ff-anchors", S + "/ff-anchors", ["results.txt", "m1-altered.log", "m2-common.log", "m3-nomarker.log",
                                                "m4-twoline.log"])
CS("integrate/anchors-1", S + "/anchors-1", ["armlist.sh", "inputs.md5", "patched.txt", "sabotage.sh"])
CA("integrate/anchors-1/tmp", S + "/anchors-1/tmp")
CS("integrate/t4", S + "/t4", ["base-obj.md5", "build.log", "fold-c-before.md5", "fold-c.diff", "make.rc",
                                "new-obj.md5", "obj.diff"])
D("integrate/t4/lj_opt_fold.c.orig", S + "/t4/lj_opt_fold.c.orig", "LuaJIT source, the build copy")
B("integrate t4 instrument lj_opt_fold.o (never shipped)", S + "/t4/luajit-windows-x86_64/src/lj_opt_fold.o")
CA("integrate/t4-census-1", S + "/t4-census-1")
CA("integrate/t4-census-1/rc", S + "/t4-census-1/rc")
CA("integrate/alma1", S + "/alma1")
CA("integrate/alma1/rc", S + "/alma1/rc")
CA("integrate/timing", S + "/timing")
CA("integrate/timing/bench", S + "/timing/bench")
CA("integrate/timing/ffsumm-1", S + "/timing/ffsumm-1")
for p in ("run-1", "smoke-1"):
    CA("integrate/timing/" + p, S + "/timing/" + p, drop=("procs-before.txt", "procs-after.txt"))
CA("integrate/timing/t4-benches", S + "/timing/t4-benches")
CS("integrate/timing/ff-java", S + "/timing/ff-java", ["rc.txt", "tasklist-during.txt", "timing.log"])
C("integrate/timing/ff-java/out/jvms-start.txt", S + "/timing/ff-java/out/jvms-start.txt")
D("integrate/timing/ff-java/bin/javaw.exe", S + "/timing/ff-java/bin/javaw.exe", "the stand-in javaw.exe, a binary")
CA("integrate/run-b1-1", S + "/run-b1-1", drop=("repo-before.md5", "repo-after.md5"))
CA("integrate/run-b1-1/rc", S + "/run-b1-1/rc")
negctl_work("integrate/negctl-work", S + "/b1/negctl-bitop")
D("integrate/head-negctl-bitop.0e453ecb.sh", S + "/head-negctl-bitop.0e453ecb.sh", "HEAD's negctl-bitop.sh, in git")
D("integrate/negctl-as-run-626f1b2d.sh", S + "/negctl-as-run-626f1b2d.sh",
  "negctl-bitop.sh as its first run read it; logs/negctl-asrun-vs-final.diff is the difference")
B("integrate b1 luajit.exe", S + "/b1/luajit-windows-x86_64/src/luajit.exe")
B("integrate b1 lj_opt_fold.o", S + "/b1/luajit-windows-x86_64/src/lj_opt_fold.o")
B("integrate alma1 luajit", S + "/alma1/b/luajit-linux-x86_64/src/luajit")
B("integrate alma1 lj_opt_fold.o", S + "/alma1/b/luajit-linux-x86_64/src/lj_opt_fold.o")
B("integrate alma1 .so (scratch)", S + "/alma1/b/libdir-additive/libjnluajit52-linux-x86_64.so")

# verify/: verify-code
S = R + "/verify-code"
C("verify/REPORT.md", SRC + "/review/verify.md")
C("verify/scripts-probes.md5", S + "/scripts-probes.md5")
CA("verify/scripts", S + "/scripts")
CA("verify/probes", S + "/probes")
CA("verify/cmp", S + "/cmp")
CA("verify/logs", S + "/logs")
CA("verify/pfwd", S + "/pfwd", drop=("lj_opt_fold.c.orig",))
D("verify/pfwd/lj_opt_fold.c.orig", S + "/pfwd/lj_opt_fold.c.orig", "LuaJIT source, the build copy")
for p in ("bodyfwd-1", "bodyfwd-pfwd-1", "sidefwd-1", "dump-bodyfwd-fix-1", "dump-bodyfwd-fix-2",
          "dump-bodyfwd-fix-3", "dump-sidefwd-fix-1", "dump-sidefwd-fix-2", "cse-base-1", "cse-fix-1",
          "cse-pfwd-1", "bitjit-all-fix-1", "t4c-ff", "t4c-bitjit", "t4c-bitop", "t4c-fuzz"):
    CA("verify/runs/" + p, S + "/runs/" + p)
C("verify/runs/ffpatch-1/results.txt", S + "/runs/ffpatch-1/results.txt")
B("verify-code bfix luajit.exe", S + "/bfix/luajit-windows-x86_64/src/luajit.exe")
B("verify-code bfix lj_opt_fold.o", S + "/bfix/luajit-windows-x86_64/src/lj_opt_fold.o")
B("verify-code pfwd lj_opt_fold.o (CSEFWD prototype)", S + "/pfwd/luajit-windows-x86_64/src/lj_opt_fold.o")
B("verify-code t4v lj_opt_fold.o (instrument, never shipped)", S + "/t4v/luajit-windows-x86_64/src/lj_opt_fold.o")

# fix/
S = R + "/fix"
C("fix/REPORT.md", SRC + "/review/fix.md")
CS("fix", S, ["commit-facts.md", "code.patch", "code.patch.md5", "code-files.txt", "repo-eight-end.md5",
              "scripts-and-helpers.md5", "final-check.sh", "fc-anchors.sh", "fc-basecse.py", "fc-cites.py",
              "fc-ffpatch.py", "fc-fftests.py", "fc-timing-summ.py"])
CA("fix/fc-bench", S + "/fc-bench")
D("fix/fc-a4c0645-lj_opt_fold.c", S + "/fc-a4c0645-lj_opt_fold.c", "LuaJIT source, upstream a4c0645's (blob 9d48aaa2)")
D("fix/inputs/pin-lj_opt_fold.c", S + "/inputs/pin-lj_opt_fold.c", "LuaJIT source, the pin's")
CA("fix/scripts", S + "/scripts")
CA("fix/probes", S + "/probes")
CA("fix/start", S + "/start")
for dp, dns, fns in os.walk(S + "/start/files"):
    for f in sorted(fns):
        p = os.path.join(dp, f).replace("\\", "/")
        D("fix/start/files/" + os.path.relpath(p, S + "/start/files").replace("\\", "/"), p,
          "the eight at the fixer's start (integrate's)")
for dp, dns, fns in os.walk(S + "/head"):
    for f in sorted(fns):
        p = os.path.join(dp, f).replace("\\", "/")
        D("fix/head/" + os.path.relpath(p, S + "/head").replace("\\", "/"), p, "HEAD's copy, in git")
CA("fix/logs", S + "/logs")
CA("fix/cmp", S + "/cmp")
CA("fix/alma1", S + "/alma1")
CA("fix/alma1/rc", S + "/alma1/rc")
CR("fix/alma1/cse", S + "/alma1/cse")
CR("fix/alma1/base-cse", S + "/alma1/base-cse")
CA("fix/runs", S + "/runs")
# The cse part's outputs: whole for the runs the docs cite by file (cse-base-5's hl1ms0, cse-base-6's per-call
# counts, cse-fix-3's split counts); the others' logs (fix/runs/*.log) keep every per-set count.
for p in ["cse-base-%d" % k for k in range(1, 7)] + ["cse-fix-%d" % k for k in range(1, 4)]:
    if p in ("cse-base-5", "cse-base-6", "cse-fix-3"):
        CR("fix/runs/" + p, S + "/runs/" + p)
    else:
        X("fix/runs/" + p, S + "/runs/" + p, "the cse part's outputs; fix/runs/%s.log keeps its per-set counts" % p)
X("fix/runs/bitjit-all-fix-1", S + "/runs/bitjit-all-fix-1", "run-bitjit's outputs, all seven parts; the log is here")
for w in ("integrate/b1/negctl-bitop", "fix/b1/negctl-bitop"):
    if os.path.isdir(R + "/" + w):
        for stamp in sorted(os.listdir(R + "/" + w)):
            X("(not archived) round/%s/%s" % (w, stamp), "%s/%s/%s" % (R, w, stamp),
              "a negctl work directory whole; its logs and md5 lists are in negctl-work/")
for p in ("ffpatch-1", "ffpatch-2", "fc-ffpatch-1"):
    C("fix/runs/%s/results.txt" % p, "%s/runs/%s/results.txt" % (S, p))
for p in ("fftests-1", "fftests-2", "fc-fftests-1"):
    d = "%s/runs/%s" % (S, p)
    C("fix/runs/%s/results.txt" % p, d + "/results.txt")
    for case in sorted(os.listdir(d)):
        if os.path.isfile("%s/%s/out.txt" % (d, case)):
            C("fix/runs/%s/%s/out.txt" % (p, case), "%s/%s/out.txt" % (d, case))
CA("fix/runs/pfwd-hx1-1", S + "/runs/pfwd-hx1-1")
negctl_work("fix/negctl-work", S + "/b1/negctl-bitop")
SM = S + "/smoke"
CS("fix/smoke", SM, ["g%d.log" % k for k in range(1, 8)] + ["g2b.log"] + ["s%d.log" % k for k in range(1, 9)] +
   ["fake-cnt.txt", "fake-tasklist.sh", "fake-tasklist2.sh", "raw-doctored.txt", "summ-integrate-run1.txt"])
C("fix/smoke/g6/jvms-start.txt", SM + "/g6/jvms-start.txt")
for p in ("g7", "s1", "s2-baseisnew", "s3", "s4", "s5", "s6", "s7", "s8"):
    CA("fix/smoke/" + p, SM + "/" + p, drop=("jvms-start.txt.all",))
CS("fix/smoke/g7/cmp", SM + "/g7/cmp", ["changed.txt", "changed-want.txt"])
for p in ("s5", "s6", "s7"):
    for n in ("summary.txt", "progress.txt", "STOPPED"):
        if os.path.isfile("%s/%s/timing/%s" % (SM, p, n)):
            C("fix/smoke/%s/timing/%s" % (p, n), "%s/%s/timing/%s" % (SM, p, n))
EIGHT = [ln.split("*", 1)[1].strip() for ln in open(S + "/repo-eight-end.md5") if "*" in ln]
for p in ("patchtest-1", "patchtest-2"):
    for f in EIGHT:
        D("fix/%s/tree/%s" % (p, f), "%s/%s/tree/%s" % (S, p, f),
          "code.patch applied to git archive HEAD (patchtest-1 outside a repo, CRLF; patchtest-2 with autocrlf off)")
B("fix b1 luajit.exe", S + "/b1/luajit-windows-x86_64/src/luajit.exe")
B("fix b1 lj_opt_fold.o", S + "/b1/luajit-windows-x86_64/src/lj_opt_fold.o")
B("fix b1 DLL (scratch)", S + "/b1/dist/libjnluajit52-windows-x86_64.dll")
B("fix alma1 luajit", S + "/alma1/b/luajit-linux-x86_64/src/luajit")
B("fix alma1 lj_opt_fold.o", S + "/alma1/b/luajit-linux-x86_64/src/lj_opt_fold.o")
B("fix alma1 .so (scratch)", S + "/alma1/b/libdir-additive/libjnluajit52-linux-x86_64.so")

# the upstream part: md5s only (the user's decision D3)
U = SRC + "/upstream"
for n in ("upstream.md", "up-cse-fwd.lua", "run-upcse.sh"):
    D("(not archived) csetwin/upstream/" + n, U + "/" + n, "the upstream part (D3: not verified or reported now)")
for sub in ("src-pin", "src-tip"):
    for n in files_in(U + "/" + sub):
        D("(not archived) csetwin/upstream/%s/%s" % (sub, n), "%s/%s/%s" % (U, sub, n), "upstream's source export")

# ------------------------------------------------------------------ --fc and --release: rules, not a list
def isbinary(path, name):
    if name.lower().endswith(BINEXT):
        return True
    with open(path, "rb") as fh:
        return b"\0" in fh.read(65536)

def walk_rules(root, dst, dir_action, file_action, label):
    agg = {}   # files skipped by rule, one row per directory and reason
    for dp, dns, fns in os.walk(root):
        rel = os.path.relpath(dp, root).replace("\\", "/")
        rel = "" if rel == "." else rel
        keep = []
        for d in sorted(dns):
            r = rel + "/" + d if rel else d
            refuse_priv(os.path.join(dp, d))   # before it is walked or counted
            why = dir_action(r)
            if why is None:
                keep.append(d)
            else:
                n, b = count_tree(os.path.join(dp, d))
                SKIPPED.append(("%s/%s" % (label, r), n, b, why))
        dns[:] = keep
        for f in sorted(fns):
            r = rel + "/" + f if rel else f
            p = os.path.join(dp, f).replace("\\", "/")
            refuse_priv(p)   # before isbinary() opens it
            act, why = file_action(r, f, p)
            if act == "copy":
                C("%s/%s" % (dst, r), p)
            elif act == "digest":
                D("%s/%s" % (dst, r), p, why)
            else:
                key = ("%s/%s" % (label, rel) if rel else label, why)
                n, b = agg.get(key, (0, 0))
                agg[key] = (n + 1, b + os.path.getsize(p))
    for (lab, why), (n, b) in sorted(agg.items()):
        SKIPPED.append((lab + " (files in it)", n, b, why))

def common_file_action(r, f, p):
    if f.endswith(".all") or f in ("procs-before.txt", "procs-after.txt"):
        return "skip", "a process list"
    if f.lower().endswith(LJSRC):
        return "digest", "LuaJIT source"
    if isbinary(p, f):
        return "digest", "binary"
    if os.path.getsize(p) > BIGTEXT:
        return "digest", "over 1 MB"
    return "copy", None

def fc_dir(r):
    if r == "headtree":
        return "HEAD's tree, exported by the tree check"
    if r == "b":
        return "the Windows build (its negctl work directory's logs are in negctl-work/; key binaries in md5s.txt)"
    if r == "alma/b":
        return "the AlmaLinux 8 build (key binaries in md5s.txt)"
    if re.match(r"^(runs|alma)/gen-[^/]+$", r):
        return "the generator's outputs (the log keeps each seed's verdict)"
    if r in ("runs/bitop", "runs/bitfuzz"):
        return "the suite's outputs (the log keeps the verdict)"
    if re.match(r"^(runs|alma)/bitjit-all/[^/]+$", r) and not r.endswith("/cse"):
        return "run-bitjit's outputs other than the cse part's"
    if re.match(r"^runs/fftests/[^/]+/bitop$", r):
        return "a mutated copy of the test files"
    if r.startswith("ps/ffpatch/"):
        return "the patch-script mutations' scratch"
    if r in ("anchors/patched", "anchors/sab"):
        return "patched or sabotaged LuaJIT sources"
    return None

def fc_file(r, f, p):
    if r in ("cmp/head-files.txt", "cmp/rp-files.txt"):
        return "digest", "a file list of HEAD's tree or the scratch repo"
    if r.startswith("census/") and not f.endswith(("-pristine-head.txt", "-real-git.txt", "-real-changed.md5")):
        return "digest", "a census list"
    if r.startswith("ps/ffpatch/") and f != "results.txt":
        return "skip", "a patch-script mutation or its output"
    if re.match(r"^runs/fftests/[^/]+/", r) and f != "out.txt":
        return "skip", "a fail-first's scratch"
    return common_file_action(r, f, p)

REL_SKIPDIRS = ("work", "b", "dist", "libdir", "libdir-additive", "luajit-windows-x86_64", "luajit-linux-x86_64",
                "luajit-export-windows-x86_64", "luajit-export-linux-x86_64", "obj-windows-x86_64",
                "obj-linux-x86_64", ".gradle", "build")

def rel_dir(r):
    last = r.split("/")[-1]
    if last in REL_SKIPDIRS or last.startswith("new-"):
        return "a build, frozen natives or a harness work directory"
    return None

if FC is not None:
    walk_rules(FC, "final", fc_dir, fc_file, "final")
    negctl_work("final/negctl-work", FC + "/b/win/negctl-bitop")
    for lab, p in (("final b/win luajit.exe", "b/win/luajit-windows-x86_64/src/luajit.exe"),
                   ("final b/win lj_opt_fold.o", "b/win/luajit-windows-x86_64/src/lj_opt_fold.o"),
                   ("final b/win lj_opt_fold.c (the build copy)", "b/win/luajit-windows-x86_64/src/lj_opt_fold.c"),
                   ("final b/win DLL", "b/win/libdir-additive/libjnluajit52-windows-x86_64.dll"),
                   ("final alma/b luajit", "alma/b/luajit-linux-x86_64/src/luajit"),
                   ("final alma/b lj_opt_fold.o", "alma/b/luajit-linux-x86_64/src/lj_opt_fold.o"),
                   ("final alma/b lj_opt_fold.c (the build copy)", "alma/b/luajit-linux-x86_64/src/lj_opt_fold.c"),
                   ("final alma/b .so", "alma/b/libdir-additive/libjnluajit52-linux-x86_64.so")):
        B(lab, FC + "/" + p)
if REL is not None:
    walk_rules(REL, "release", rel_dir, lambda r, f, p: common_file_action(r, f, p), "release")

# ------------------------------------------------------------------ the README's placeholders
def rdtext(p):
    try:
        with open(p, "rb") as fh:
            return fh.read().decode("utf-8", "replace").replace("\r", "")
    except OSError:
        return None

FILL = {}
if FC is not None:
    ad = rdtext(FC + "/ALL.done") or ""
    m = re.search(r"PASS (\d+) FAIL (\d+) SKIP (\d+) VERDICT: (\S+) secs (\d+)", ad)
    if m:
        FILL["@@FC-RESULT@@"] = "**%s PASS, %s FAIL, %s SKIP, VERDICT %s**" % m.group(1, 2, 3, 4)
        st = (rdtext(FC + "/start-time.txt") or "").strip()
        secs = int(m.group(5))
        FILL["@@FC-TIME@@"] = "%d s (%d min)%s" % (secs, round(secs / 60.0), (", from " + st) if st else "")
    tt = rdtext(FC + "/logs/timing.txt") or ""
    m = re.search(r"^negctl-bitop secs=(\d+)", tt, re.M)
    if m:
        n, b = count_tree(FC + "/b/win/negctl-bitop")
        nl = rdtext(FC + "/logs/negctl-bitop.log") or ""
        v = re.search(r"^NEGCTL-BITOP: (PASS|FAIL)", nl, re.M)
        FILL["@@FC-NEGCTL@@"] = "%s in %s s, its work directory %.0f MiB (%d files; `final/negctl-work/` keeps its logs)" % (
            v.group(1) if v else "no verdict line", m.group(1), b / 1048576.0, n)
    ts = rdtext(FC + "/timing/summary.txt")
    if ts:
        keep = [ln.strip() for ln in ts.split("\n") if ln.startswith(("RESULTS:", "GROSS:", "ALL:"))]
        rounds = len([ln for ln in (rdtext(FC + "/timing/progress.txt") or "").split("\n") if ln.startswith("round ")])
        cb = (rdtext(FC + "/timing/cpuload-before.txt") or "").strip()
        ca = (rdtext(FC + "/timing/cpuload-after.txt") or "").strip()
        if keep:
            FILL["@@FC-TIMING@@"] = "%s; %d rounds%s" % ("; ".join(keep).replace(" (information only)", ""), rounds,
                ", CPU load %s%% before and %s%% after" % (cb, ca) if cb and ca else "")
if REL is not None:
    lists = {}
    for dp, dns, fns in os.walk(REL):
        for f in fns:
            if f in ("natives-after.md5", "jars.md5"):
                lists.setdefault(f, []).append(os.path.join(dp, f))
    def one(fname, pred):
        got = set()
        for p in lists.get(fname, []):
            for ln in (rdtext(p) or "").split("\n"):
                parts = ln.split()
                if len(parts) >= 2 and pred(parts[-1].lstrip("*")):
                    got.add(parts[0][:8])
        return got.pop() if len(got) == 1 else None
    dll = one("natives-after.md5", lambda n: n.endswith("dist/libjnluajit52-windows-x86_64.dll"))
    so = one("natives-after.md5", lambda n: n.endswith("dist/libjnluajit52-linux-x86_64.so"))
    if dll:
        FILL["@@REL-DLL@@"] = "`%s`" % dll
    if so:
        FILL["@@REL-SO@@"] = "`%s`" % so
    head = ((rdtext(FC + "/repo-head.txt") if FC else None) or "").strip()[:7]
    if head:
        jar = one("jars.md5", lambda n: ("/ocluajit-%s-" % head) in n and n.endswith(".jar")
                  and not n.endswith(("-dev.jar", "-sources.jar")))
        if jar:
            FILL["@@REL-JAR@@"] = "`%s`" % jar

def wrap(line):
    if len(line) <= WIDTH:
        return [line]
    lead = len(line) - len(line.lstrip(" "))
    ind = " " * (lead + (2 if line.lstrip(" ").startswith("- ") else 0))
    out, cur = [], ""
    for w in line.split(" "):
        if cur and len(cur) + 1 + len(w) > WIDTH:
            out.append(cur)
            cur = ind + w
        else:
            cur = (cur + " " + w) if cur else w
    out.append(cur)
    return out

readme_lines = []
for ln in (rdtext(ARCH + "/README.md") or "").split("\n"):
    new = ln
    for k, v in FILL.items():
        new = new.replace(k, v)
    readme_lines += wrap(new) if new != ln else [ln]
README = "\n".join(readme_lines).encode("utf-8")
LEFT = sorted(set(re.findall(rb"@@[A-Z-]+@@", README)))

# ------------------------------------------------------------------ build every file in memory, then check
def md5b(b):
    return hashlib.md5(b).hexdigest()

def norm(raw):
    d = raw.replace(b"\r\n", b"\n").replace(b"\r", b"\n")
    d = ESC.sub(b"", d)
    for a, b in REDACT:
        d = d.replace(a, b)
    return d

OUT = {}      # archive path -> bytes
NOTE = {}     # archive path -> (md5 as in scratch, note)
problems = []
for rel, src in COPY:
    if rel in OUT:
        problems.append("two sources for " + rel)
        continue
    name = os.path.basename(src)
    if not os.path.isfile(src):
        problems.append("missing source " + short(src))
        continue
    if isbinary(src, name):
        problems.append("a binary in the copy list: " + short(src))
        continue
    with open(src, "rb") as fh:
        raw = fh.read()
    data = norm(raw)
    for a, b in FREDACT.get(rel, ()):
        if data.count(a) != 1:
            problems.append("redaction text found %d times in %s (wanted once)" % (data.count(a), rel))
        data = data.replace(a, b)
    OUT[rel] = data
    NOTE[rel] = (md5b(raw), "" if data == raw else "  (copy %s)" % md5b(data))

def digest_line(label, src, why):
    if not os.path.isfile(src):
        return "%-32s %10s  %s  (from %s; %s)" % ("absent", "-", label, short(src), why)
    h = hashlib.md5()
    with open(src, "rb") as fh:
        for blk in iter(lambda: fh.read(1 << 20), b""):
            h.update(blk)
    return "%s %10d  %s  (from %s; %s)" % (h.hexdigest(), os.path.getsize(src), label, short(src), why)

me_raw = open(os.path.abspath(__file__), "rb").read()
me = me_raw.replace(('"%s"' % PRIV).encode(), b'"PRIVATE-SCRATCH-PATHS"')
for a, b in REDACT:
    me = me.replace(a, b)
OUT["scripts/mkcse.py"] = me
NOTE["scripts/mkcse.py"] = (md5b(me_raw), "  (copy %s)" % md5b(me))

L = ["# md5s.txt -- bench/runs/2026-10-23-csetwin, written by scripts/mkcse.py",
     "#",
     "# 1. Every file copied here: its md5 as it is in scratch (claude-tmp/oclj/csetwin/), its path here, and,",
     "#    where the copy differs (CRLF or lone CR made LF, ANSI colour codes removed, or the redaction the README",
     "#    names), the copy's md5.  README.md is not listed: it is the draft's, with the placeholders filled.", ""]
for rel in sorted(NOTE):
    L.append("%s  %s%s" % (NOTE[rel][0], rel, NOTE[rel][1]))
L += ["", "# 2. Files not copied (binaries, LuaJIT sources, tars, long md5 lists, files in git, the upstream part):",
      "#    md5, bytes, the path it would have here (or its scratch path), its source and why.", ""]
L += [digest_line(*d) for d in DIGEST]
L += ["", "# 3. Binaries the round's runs used (md5, bytes, which, source); build/native's own, the unfixed base, are",
      "#    in fix/start/base-natives.md5 (luajit.exe f4038cd6, lj_opt_fold.o f6d916e2; Linux luajit cb68e454,",
      "#    lj_opt_fold.o 57970a51), read at the round's start: the release rebuilds build/native.", ""]
L += [digest_line(lab, src, "binary") for lab, src in BINS]
if SKIPPED:
    L += ["", "# 4. Directories and files left out whole: the round's by choice, --fc's and --release's by rule",
          "#    (files, bytes, path, why).", ""]
    L += ["%6d %12d  %s  (%s)" % (n, b, lab, why) for lab, n, b, why in SKIPPED]
MD5S = ("\n".join(L) + "\n").encode("utf-8")
OUT["md5s.txt"] = MD5S
OUT["README.md"] = README + (b"" if README.endswith(b"\n") else b"\n")

forbidden_hits = []
total = 0
for rel in sorted(OUT):
    data = OUT[rel]
    total += len(data)
    if b"\r" in data or b"\0" in data:
        problems.append("a CR or NUL left in " + rel)
    for pairs in FREDACT.values():
        for a, b in pairs:
            if a in data:
                problems.append("a redacted text is left in " + rel)
    for k, ln in enumerate(data.split(b"\n"), 1):
        if PRIVRE.search(ln):
            problems.append("the refused path is named in %s:%d" % (rel, k))
        if FORBID:
            lo = ln.lower()
            if any(f in lo for f in FORBID):
                forbidden_hits.append("%s:%d" % (rel, k))
if total > MAXTOTAL:
    problems.append("the archive would hold %d bytes, more than %d" % (total, MAXTOTAL))
for h in forbidden_hits:
    problems.append("a forbidden string in " + h)
if problems:
    for p in problems:
        print("PROBLEM: " + p)
    print("NOTHING WRITTEN (%d problems)" % len(problems))
    sys.exit(1)

os.makedirs(dest)
for rel in sorted(OUT):
    out = os.path.join(dest, rel)
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with open(out, "wb") as fh:
        fh.write(OUT[rel])
long_lines = [k for k, ln in enumerate(README.split(b"\n"), 1) if len(ln.decode("utf-8")) > WIDTH]
print("written: %s" % dest)
print("files %d, bytes %d; not copied %d, binaries %d, left out by rule %d" % (
    len(OUT), total, len(DIGEST), len(BINS), len(SKIPPED)))
print("forbidden-string check: %s" % ("run, 0 hits" if FORBID else "not run"))
print("README placeholders filled: %s" % (" ".join(sorted(FILL)) or "none"))
print("README placeholders left: %s" % (" ".join(x.decode() for x in LEFT) or "none"))
print("README lines over %d chars: %s" % (WIDTH, " ".join(map(str, long_lines)) or "none"))
for sec in ("final", "release"):
    got = [r for r in sorted(OUT) if r.startswith(sec + "/")]
    if got:
        print("%s/: %d files copied by rule (read them before committing)" % (sec, len(got)))
