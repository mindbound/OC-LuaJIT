import sys, os
# hunkcount.py <repo native/luajit dir> <tree src dir>: for each of round 3's
# seven patch-bitop-*.sh scripts, read every hunk's upstream text ($D/o<h>)
# and ours ($D/n<h>) from the script's own heredocs, with @T@ as a tab, as
# the hunk engine does, and count how often each occurs in the tree's file
# (a run of consecutive whole lines, compared exactly, each line's trailing
# CR removed).  Unlike the script it does not stop at the first refused
# hunk.  Prints one line per hunk: script, hunk, file, upstream-count,
# ours-count, and "ok" when upstream's text occurs exactly once and ours
# never (the script's own precondition), else "REFUSED".  Exit 0 always;
# the verdicts are in the output.  No backslashes.
TAB = chr(9)
CR = chr(13)
NL = chr(10)
D, S = sys.argv[1], sys.argv[2]
FILES = [("lj_parse.c", "parse"), ("vm_x64.dasc", "vm"), ("lj_meta.c", "meta"),
         ("lj_record.c", "record"), ("lj_opt_fold.c", "fold"),
         ("lj_bcdump.h", "bcdump"), ("lib_jit.c", "jitlib")]

def lines(path):
    t = open(path, "rb").read().decode("latin-1")
    out = t.split(NL)
    if out and out[-1] == "":
        out.pop()
    return [l[:-1] if l.endswith(CR) else l for l in out]

def heredocs(script):
    L = lines(script)
    docs = {}
    i = 0
    while i < len(L):
        l = L[i]
        if l.startswith('cat > "$D/') and l.endswith("<<'EOF'"):
            name = l[len('cat > "$D/'):].split('"')[0]
            body = []
            i += 1
            while L[i] != "EOF":
                body.append(L[i].replace("@T@", TAB))
                i += 1
            docs[name] = body
        i += 1
    return docs

def times(hay, needle):
    n = len(needle)
    c = 0
    for i in range(0, len(hay) - n + 1):
        if hay[i:i + n] == needle:
            c += 1
    return c

total_bad = 0
for f, s in FILES:
    script = os.path.join(D, "patch-bitop-" + s + ".sh")
    docs = heredocs(script)
    hay = lines(os.path.join(S, f))
    h = 1
    while ("o%d" % h) in docs:
        o = docs["o%d" % h]
        n = docs["n%d" % h]
        co, cn = times(hay, o), times(hay, n)
        ok = (co == 1 and cn == 0)
        if not ok:
            total_bad += 1
        print("%-24s hunk %2d %-14s upstream %d ours %d lines %3d %s  first: %s" % (
            "patch-bitop-" + s + ".sh", h, f, co, cn, len(o), "ok" if ok else "REFUSED",
            o[0].strip()[:70]))
        h += 1
print("refused hunks:", total_bad)
