import sys, os, shlex
# negarms.py <negctl-bitop.sh> <patched work dir A> <label A> <patched work dir B> <label B>:
# every `arm NAME FILE CATCHERS OLD NEW` call in negctl-bitop.sh's armlist
# whose FILE is a LuaJIT file (present in the work dirs), with OLD split on
# newlines and @T@ read as a tab, as negctl's sabotage() reads it; counts
# OLD as a run of consecutive whole lines in each work dir's FILE (CR
# stripped).  sabotage() needs exactly 1.  Prints one line per arm and
# "BROKEN" when a count is not 1.  Read-only; no backslashes in this file.
BS = chr(92)
TAB = chr(9)
NL = chr(10)
CR = chr(13)
src, da, la, db, lb = sys.argv[1:6]

def lines(p):
    t = open(p, "rb").read().decode("latin-1")
    out = t.split(NL)
    if out and out[-1] == "":
        out.pop()
    return [l[:-1] if l.endswith(CR) else l for l in out]

raw = lines(src)
# join continuation lines inside armlist() { ... }
i0 = raw.index("armlist() {")
calls, cur = [], ""
for l in raw[i0 + 1:]:
    if l == "}":
        break
    if l.endswith(BS):
        cur += l[:-1] + " "
        continue
    cur += l
    if cur.startswith("arm "):
        try:
            shlex.split(cur, posix=True)
        except ValueError:  # a quoted text spans lines: keep the newline
            cur += NL
            continue
        calls.append(cur)
    cur = ""

def times(hay, needle):
    n = len(needle)
    return sum(1 for i in range(len(hay) - n + 1) if hay[i:i + n] == needle)

cache = {}
for c in calls:
    w = shlex.split(c, posix=True)
    name, f = w[1], w[2]
    if name == "canon":
        continue
    pa, pb = os.path.join(da, f), os.path.join(db, f)
    if not (os.path.exists(pa) and os.path.exists(pb)):
        continue
    old = [x.replace("@T@", TAB) for x in w[4].split(NL)]
    res = []
    for lab, p in ((la, pa), (lb, pb)):
        if p not in cache:
            cache[p] = lines(p)
        res.append((lab, times(cache[p], old)))
    flag = "ok" if all(n == 1 for _, n in res) else "BROKEN"
    dollar = " (OLD holds a $: check by hand)" if "$" in w[4] else ""
    print("%-14s %-14s %s %s%s" % (name, f, "  ".join("%s=%d" % r for r in res), flag, dollar))
