"""oneline.py <file> <old line file> <new line file> -- replace exactly one
whole line of <file> (LF, bytes) whose text equals the first line of <old
line file> with the first line of <new line file>; '@T@' in either stands
for a tab.  Refuses unless the old line occurs exactly once.  verify-code's
one-file method (JIT guide 7.4) for scratch prototypes; never shipped."""
import sys

def first_line(p):
    with open(p, "rb") as f:
        return f.read().split(b"\n")[0].replace(b"@T@", bytes([9]))

path, oldp, newp = sys.argv[1], sys.argv[2], sys.argv[3]
old, new = first_line(oldp), first_line(newp).replace(b"@N@", b"\n")
with open(path, "rb") as f:
    data = f.read()
lines = data.split(b"\n")
hits = [i for i, l in enumerate(lines) if l == old]
if len(hits) != 1:
    print("REFUSED: the old line occurs %d times" % len(hits))
    sys.exit(1)
lines[hits[0]] = new
with open(path, "wb") as f:
    f.write(b"\n".join(lines))
print("replaced line %d" % (hits[0] + 1))
