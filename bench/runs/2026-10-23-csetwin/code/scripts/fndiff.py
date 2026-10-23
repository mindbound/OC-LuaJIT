import sys, re, subprocess, hashlib
# fndiff.py <a.o> <b.o>: objdump -d both (no raw bytes), split by function
# label, drop each line's address column and absolute targets, and list the
# functions whose instruction text differs, those only in one, and the
# instruction counts.  Read-only.  No backslashes in this file.
def funcs(path):
    out = subprocess.run(["objdump", "-d", "--no-show-raw-insn", path],
                         capture_output=True, text=True, check=True).stdout
    fs = {}
    cur = None
    hdr = re.compile("^[0-9a-f]+ <([^>]+)>:$")
    for line in out.splitlines():
        m = hdr.match(line)
        if m:
            cur = m.group(1)
            fs[cur] = []
            continue
        if cur is None or ":" not in line:
            continue
        ins = line.split(":", 1)[1].strip()
        # drop absolute addresses inside the function (jump targets) but keep
        # the symbol in angle brackets
        ins = re.sub("[0-9a-f]+ <", "<", ins)
        ins = re.sub("<([^>+]+)[+]0x[0-9a-f]+>", "<LABEL>", ins)
        fs[cur].append(ins)
    return fs
a = funcs(sys.argv[1])
b = funcs(sys.argv[2])
names = sorted(set(a) | set(b))
nd = 0
for n in names:
    if n not in a:
        print("only in B: %s (%d insns)" % (n, len(b[n])))
        nd += 1
    elif n not in b:
        print("only in A: %s (%d insns)" % (n, len(a[n])))
        nd += 1
    elif a[n] != b[n]:
        print("differs: %s (%d -> %d insns)" % (n, len(a[n]), len(b[n])))
        nd += 1
print("functions: A %d, B %d, differing or unmatched %d" % (len(a), len(b), nd))
